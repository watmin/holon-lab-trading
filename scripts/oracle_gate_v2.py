"""Oracle gate v2 — more training data + compound recognition.

Changes from v1:
  1. Training: 2000 samples per class (was 300)
  2. Compound recognition: two-pass classification
     - Pass 1: BUY vs SELL vs QUIET (same as v1)
     - Pass 2: if BUY, check BUY-vs-QUIET margin explicitly
               if SELL, check SELL-vs-QUIET margin explicitly
     Only fire if the action class has meaningfully lower residual than QUIET.
  3. Sweep n_train values to see the effect of more data

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/oracle_gate_v2.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent.parent))

from trading.features import TechnicalFeatureFactory
from trading.gate import HolonGate

from holon import HolonClient
from holon.kernel.walkable import LinearScale, WalkableSpread
from holon.memory import StripedSubspace

FEE_PER_SIDE = 0.025
MAX_CANDLES = 10_000
MIN_MOVE = 0.5
HORIZON = 36
POSITION_FRAC = 0.25


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def find_opportunities(close, min_move_pct, horizon):
    n = len(close)
    labels = np.full(n, "QUIET", dtype=object)
    exit_indices = np.zeros(n, dtype=int)

    for i in range(n - 1):
        end = min(i + 1 + horizon, n)
        if end <= i + 1:
            continue
        entry = close[i]
        target_up = entry * (1 + min_move_pct / 100)
        target_down = entry * (1 - min_move_pct / 100)

        buy_hit = -1
        sell_hit = -1
        for j in range(i + 1, end):
            if buy_hit < 0 and close[j] >= target_up:
                buy_hit = j
            if sell_hit < 0 and close[j] <= target_down:
                sell_hit = j
            if buy_hit >= 0 and sell_hit >= 0:
                break

        if buy_hit >= 0 and (sell_hit < 0 or buy_hit <= sell_hit):
            labels[i] = "BUY"
            exit_indices[i] = buy_hit
        elif sell_hit >= 0:
            labels[i] = "SELL"
            exit_indices[i] = sell_hit

    return labels, exit_indices


class OracleGateV2:
    """Oracle gate with compound recognition.

    Two-pass classification:
      1. Score against BUY, SELL, QUIET subspaces
      2. For BUY/SELL winners, check the action-vs-QUIET residual ratio
         Must beat QUIET by a configurable threshold to fire.
    """

    DIM = HolonGate.DIM
    K = HolonGate.K
    N_STRIPES = HolonGate.N_STRIPES
    WINDOW = HolonGate.WINDOW

    def __init__(self, client: HolonClient, quiet_ratio_threshold: float = 0.95):
        self.client = client
        self.subspaces: dict[str, StripedSubspace] = {}
        self._ready = False
        self.quiet_ratio_threshold = quiet_ratio_threshold

    @property
    def ready(self):
        return self._ready and "QUIET" in self.subspaces

    def train(self, df_ind, labels, n_train: int = 2000, features=None, rng=None):
        if rng is None:
            rng = np.random.default_rng(42)
        if features is None:
            features = self._precompute(df_ind)

        for label_name in ["BUY", "SELL", "QUIET"]:
            indices = [i for i in range(self.WINDOW, len(df_ind)) if labels[i] == label_name]
            if len(indices) < 20:
                log(f"    {label_name}: only {len(indices)} samples, skipping")
                continue

            sample = rng.choice(indices, size=min(n_train + 100, len(indices)), replace=False)
            ss = StripedSubspace(dim=self.DIM, k=self.K, n_stripes=self.N_STRIPES)
            count = 0
            for idx in sample:
                v = self._encode_fast(features, idx)
                if v is not None:
                    ss.update(v)
                    count += 1
                if count >= n_train:
                    break

            if count >= 20:
                self.subspaces[label_name] = ss
                log(f"    {label_name}: trained on {count} windows")

        self._ready = len(self.subspaces) >= 2

    def _precompute(self, df_ind):
        n = len(df_ind)
        o = df_ind["open"].values
        h = df_ind["high"].values
        l = df_ind["low"].values
        c = df_ind["close"].values
        rng = np.maximum(h - l, 1e-10)

        return {
            "open_r": df_ind["open_r"].values if "open_r" in df_ind.columns else np.zeros(n),
            "high_r": df_ind["high_r"].values if "high_r" in df_ind.columns else np.zeros(n),
            "low_r": df_ind["low_r"].values if "low_r" in df_ind.columns else np.zeros(n),
            "vol_r": df_ind["vol_r"].values if "vol_r" in df_ind.columns else np.zeros(n),
            "rsi": df_ind["rsi"].values if "rsi" in df_ind.columns else np.full(n, 50.0),
            "ret": df_ind["ret"].values if "ret" in df_ind.columns else np.zeros(n),
            "sma20_r": df_ind["sma20_r"].values if "sma20_r" in df_ind.columns else np.zeros(n),
            "sma50_r": df_ind["sma50_r"].values if "sma50_r" in df_ind.columns else np.zeros(n),
            "macd_hist": df_ind["macd_hist_r"].values if "macd_hist_r" in df_ind.columns else np.zeros(n),
            "bb_width": df_ind["bb_width"].values if "bb_width" in df_ind.columns else np.zeros(n),
            "adx": df_ind["adx"].values if "adx" in df_ind.columns else np.zeros(n),
            "body": (c - o) / rng,
            "upper_wick": (h - np.maximum(o, c)) / rng,
            "lower_wick": (np.minimum(o, c) - l) / rng,
            "close_pos": (c - l) / rng,
        }

    def _encode_fast(self, features, idx):
        start = int(idx) - self.WINDOW + 1
        if start < 0:
            return None
        walkable = {}
        for name in [
            "open_r", "high_r", "low_r", "vol_r", "rsi", "ret",
            "sma20_r", "sma50_r", "macd_hist", "bb_width", "adx",
            "body", "upper_wick", "lower_wick", "close_pos",
        ]:
            arr = features[name]
            walkable[name] = WalkableSpread(
                [LinearScale(float(arr[start + i])) for i in range(self.WINDOW)]
            )
        return self.client.encoder.encode_walkable_striped(walkable, n_stripes=self.N_STRIPES)

    def classify(self, features, idx, adaptive=False):
        """Two-pass compound classification.

        Pass 1: find best class (BUY/SELL/QUIET)
        Pass 2: if BUY or SELL, check action_residual / quiet_residual ratio.
                If ratio >= threshold, downgrade to QUIET (not confident enough).

        Returns (label, margin, quiet_ratio, residuals)
        """
        if not self.ready:
            return "QUIET", 0.0, 1.0, {}

        v = self._encode_fast(features, idx)
        if v is None:
            return "QUIET", 0.0, 1.0, {}

        residuals = {}
        for label, ss in self.subspaces.items():
            residuals[label] = ss.residual(v)

        best = min(residuals, key=residuals.get)

        # Pass 2: compound check — is the action class meaningfully better than QUIET?
        quiet_r = residuals.get("QUIET", float("inf"))
        action_r = residuals[best]
        quiet_ratio = action_r / quiet_r if quiet_r > 0 else 1.0

        if best in ("BUY", "SELL") and quiet_ratio >= self.quiet_ratio_threshold:
            best = "QUIET"

        if adaptive and best in self.subspaces:
            self.subspaces[best].update(v)

        sorted_r = sorted(residuals.values())
        margin = sorted_r[1] - sorted_r[0] if len(sorted_r) > 1 else 0.0

        return best, margin, quiet_ratio, residuals


def backtest(close, gate_labels, oracle_labels, exit_indices,
             fee_pct=FEE_PER_SIDE, pos_frac=POSITION_FRAC):
    equity = 10_000.0
    trades = []
    in_trade_until = 0

    for i in range(len(close)):
        if i < in_trade_until:
            continue

        gl = gate_labels[i]
        if gl == "QUIET":
            continue

        ol = oracle_labels[i]
        exit_idx = exit_indices[i]

        if gl == "BUY":
            entry_price = close[i]
            if ol == "BUY" and exit_idx > i:
                exit_price = close[exit_idx]
            else:
                exit_idx = min(i + HORIZON, len(close) - 1)
                exit_price = close[exit_idx]

            trade_eq = equity * pos_frac
            cost_in = trade_eq * (fee_pct / 100)
            shares = (trade_eq - cost_in) / entry_price
            proceeds = shares * exit_price
            cost_out = proceeds * (fee_pct / 100)
            pnl = proceeds - cost_out - trade_eq
            equity += pnl
            pnl_pct = (exit_price / entry_price - 1) * 100
            trades.append({"pnl_pct": pnl_pct, "dir": "LONG", "agreed": ol == "BUY", "hold": exit_idx - i})
            in_trade_until = exit_idx + 1

        elif gl == "SELL":
            entry_price = close[i]
            if ol == "SELL" and exit_idx > i:
                exit_price = close[exit_idx]
            else:
                exit_idx = min(i + HORIZON, len(close) - 1)
                exit_price = close[exit_idx]

            trade_eq = equity * pos_frac
            cost_in = trade_eq * (fee_pct / 100)
            pnl_pct = (entry_price / exit_price - 1) * 100
            gross = trade_eq * (1 + pnl_pct / 100)
            cost_out = gross * (fee_pct / 100)
            pnl = gross - cost_out - trade_eq
            equity += pnl
            trades.append({"pnl_pct": pnl_pct, "dir": "SHORT", "agreed": ol == "SELL", "hold": exit_idx - i})
            in_trade_until = exit_idx + 1

    tdf = pd.DataFrame(trades) if trades else pd.DataFrame()
    ret = (equity / 10_000 - 1) * 100
    agreed = tdf[tdf["agreed"]] if not tdf.empty else pd.DataFrame()
    disagreed = tdf[~tdf["agreed"]] if not tdf.empty else pd.DataFrame()

    return {
        "return_pct": ret,
        "n_trades": len(trades),
        "win_rate": (tdf["pnl_pct"] > 0).mean() * 100 if not tdf.empty else 0,
        "avg_trade": tdf["pnl_pct"].mean() if not tdf.empty else 0,
        "n_agreed": len(agreed),
        "agreed_wr": (agreed["pnl_pct"] > 0).mean() * 100 if not agreed.empty else 0,
        "n_disagreed": len(disagreed),
        "disagreed_wr": (disagreed["pnl_pct"] > 0).mean() * 100 if not disagreed.empty else 0,
        "disagreed_avg": disagreed["pnl_pct"].mean() if not disagreed.empty else 0,
    }


def main():
    log("Loading data...")
    df = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df["ts"])
    factory = TechnicalFeatureFactory()

    log("Preparing 2019-2020 training data...")
    mask_seed = ts <= "2020-12-31"
    df_seed = df[mask_seed].reset_index(drop=True)
    df_seed_ind = factory.compute_indicators(df_seed)
    close_seed = df_seed_ind["close"].values

    log(f"  Labeling (min_move={MIN_MOVE}%, horizon={HORIZON})...")
    seed_labels, _ = find_opportunities(close_seed, MIN_MOVE, HORIZON)
    n_buy = (seed_labels == "BUY").sum()
    n_sell = (seed_labels == "SELL").sum()
    n_quiet = (seed_labels == "QUIET").sum()
    log(f"  Labels: {n_buy} BUY / {n_sell} SELL / {n_quiet} QUIET")

    periods = [
        ("2021 (bull)", "2021-01-01", "2021-12-31"),
        ("2022 (bear)", "2022-01-01", "2022-12-31"),
        ("2023 (recovery)", "2023-01-01", "2023-12-31"),
        ("2024", "2024-01-01", "2024-12-31"),
    ]

    # Sweep: n_train x quiet_ratio_threshold
    train_sizes = [300, 1000, 2000]
    quiet_thresholds = [1.0, 0.98, 0.95, 0.90]

    for n_train in train_sizes:
        for qt in quiet_thresholds:
            log(f"\n{'=' * 80}")
            log(f"CONFIG: n_train={n_train}, quiet_threshold={qt}")
            log(f"{'=' * 80}")

            client = HolonClient(dimensions=OracleGateV2.DIM)
            gate = OracleGateV2(client, quiet_ratio_threshold=qt)
            seed_features = gate._precompute(df_seed_ind)
            gate.train(df_seed_ind, seed_labels, n_train=n_train, features=seed_features)

            if not gate.ready:
                log("  Gate not ready, skipping")
                continue

            compound_return = 1.0

            for period_name, start, end in periods:
                mask = (ts >= start) & (ts <= end)
                df_period = df[mask].reset_index(drop=True)
                if len(df_period) < 500:
                    continue

                df_ind = factory.compute_indicators(df_period)
                close = df_ind["close"].values
                n = len(df_ind)
                scan_end = min(n, OracleGateV2.WINDOW + MAX_CANDLES)
                close_scan = close[:scan_end]

                bah_start = float(close[OracleGateV2.WINDOW])
                bah_end = float(close[scan_end - 1])
                bah_pct = (bah_end / bah_start - 1) * 100

                oracle_labels, oracle_exits = find_opportunities(close_scan, MIN_MOVE, HORIZON)
                features = gate._precompute(df_ind)

                gate_labels = []
                t0 = time.time()
                for step in range(scan_end):
                    if step < OracleGateV2.WINDOW:
                        gate_labels.append("QUIET")
                        continue
                    label, margin, qr, _ = gate.classify(features, step, adaptive=True)
                    gate_labels.append(label)
                elapsed = time.time() - t0

                gate_labels = np.array(gate_labels)
                n_gb = (gate_labels[OracleGateV2.WINDOW:] == "BUY").sum()
                n_gs = (gate_labels[OracleGateV2.WINDOW:] == "SELL").sum()
                n_gq = (gate_labels[OracleGateV2.WINDOW:] == "QUIET").sum()

                bt = backtest(close_scan, gate_labels, oracle_labels, oracle_exits)
                compound_return *= (1 + bt["return_pct"] / 100)

                log(f"  {period_name:20s} | B&H {bah_pct:+6.1f}% | Ret {bt['return_pct']:+6.1f}% | {bt['n_trades']:3d} trades (agr:{bt['n_agreed']}/dis:{bt['n_disagreed']}) | WR {bt['win_rate']:4.0f}% | dis_wr {bt['disagreed_wr']:4.0f}% dis_avg {bt['disagreed_avg']:+.2f}% | cls {n_gb}B/{n_gs}S/{n_gq}Q | {elapsed:.0f}s")

            log(f"  COMPOUND: {(compound_return - 1) * 100:+.1f}%")

    log(f"\n{'=' * 80}")
    log("DONE")
    log(f"{'=' * 80}")


if __name__ == "__main__":
    main()
