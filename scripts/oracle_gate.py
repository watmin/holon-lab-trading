"""Oracle-trained gate — train directly on profitable opportunity labels.

Instead of regime classification (TREND_UP/DOWN/etc), trains 3 subspaces:
  BUY  — windows where a profitable long entry exists within horizon
  SELL — windows where a profitable short entry exists within horizon
  QUIET — windows where neither exists

The gate fires when the current window matches BUY or SELL better than QUIET.
No transition detection needed — direct classification.

Trains on 2019-2020, grades on 2021-2024 with adaptive learning.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/oracle_gate.py
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
MIN_MOVE = 0.5  # %
HORIZON = 36  # candles (3h)
POSITION_FRAC = 0.25


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def find_opportunities(close, min_move_pct, horizon):
    """Label each candle as BUY, SELL, or QUIET based on future price action."""
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

        # Whichever hits first wins
        if buy_hit >= 0 and (sell_hit < 0 or buy_hit <= sell_hit):
            labels[i] = "BUY"
            exit_indices[i] = buy_hit
        elif sell_hit >= 0:
            labels[i] = "SELL"
            exit_indices[i] = sell_hit

    return labels, exit_indices


class OracleGate:
    """Gate trained directly on oracle (profitable opportunity) labels.

    3 subspaces: BUY, SELL, QUIET. Fires when BUY or SELL wins.
    Uses same encoding as HolonGate for consistency.
    """

    DIM = HolonGate.DIM
    K = HolonGate.K
    N_STRIPES = HolonGate.N_STRIPES
    WINDOW = HolonGate.WINDOW

    def __init__(self, client: HolonClient):
        self.client = client
        self.subspaces: dict[str, StripedSubspace] = {}
        self._ready = False

    @property
    def ready(self):
        return self._ready and len(self.subspaces) >= 2

    def train(self, df_ind, labels, n_train: int = 300, features=None, rng=None):
        """Train BUY/SELL/QUIET subspaces from oracle labels."""
        if rng is None:
            rng = np.random.default_rng(42)

        if features is None:
            features = self._precompute(df_ind)

        for label_name in ["BUY", "SELL", "QUIET"]:
            indices = [i for i in range(self.WINDOW, len(df_ind)) if labels[i] == label_name]
            if len(indices) < 20:
                log(f"    {label_name}: only {len(indices)} samples, skipping")
                continue

            sample = rng.choice(indices, size=min(n_train + 50, len(indices)), replace=False)
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
        """Same precompute as HolonGate."""
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
        """Classify current window. Returns (label, margin, residuals).

        label: "BUY", "SELL", or "QUIET"
        margin: residual gap between best and second-best
        """
        if not self.ready:
            return "QUIET", 0.0, {}

        v = self._encode_fast(features, idx)
        if v is None:
            return "QUIET", 0.0, {}

        residuals = {}
        for label, ss in self.subspaces.items():
            residuals[label] = ss.residual(v)

        best = min(residuals, key=residuals.get)

        if adaptive:
            self.subspaces[best].update(v)

        sorted_r = sorted(residuals.values())
        margin = sorted_r[1] - sorted_r[0] if len(sorted_r) > 1 else 0.0

        return best, margin, residuals


def backtest_oracle_gate(close, gate_labels, gate_margins, oracle_labels, exit_indices,
                         min_margin=0.0, fee_pct=FEE_PER_SIDE, pos_frac=POSITION_FRAC):
    """Backtest: trade when gate says BUY/SELL, exit at oracle's known exit point
    (simulating a target-based exit at min_move%)."""
    equity = 10_000.0
    trades = []
    in_trade_until = 0

    for i in range(len(close)):
        if i < in_trade_until:
            continue

        gl = gate_labels[i]
        margin = gate_margins[i]

        if gl == "QUIET" or margin < min_margin:
            continue

        # Gate says BUY or SELL — do we have a known exit?
        ol = oracle_labels[i]
        exit_idx = exit_indices[i]

        if gl == "BUY":
            entry_price = close[i]
            if ol == "BUY" and exit_idx > i:
                # Perfect exit at target
                exit_price = close[exit_idx]
            else:
                # Gate says BUY but oracle says no — exit after horizon
                exit_idx_fallback = min(i + HORIZON, len(close) - 1)
                exit_price = close[exit_idx_fallback]
                exit_idx = exit_idx_fallback

            trade_equity = equity * pos_frac
            cost_in = trade_equity * (fee_pct / 100)
            shares = (trade_equity - cost_in) / entry_price
            proceeds = shares * exit_price
            cost_out = proceeds * (fee_pct / 100)
            pnl = proceeds - cost_out - trade_equity
            equity += pnl
            pnl_pct = (exit_price / entry_price - 1) * 100
            trades.append({"pnl_pct": pnl_pct, "dir": "LONG", "oracle_agreed": ol == "BUY", "hold": exit_idx - i})
            in_trade_until = exit_idx + 1

        elif gl == "SELL":
            entry_price = close[i]
            if ol == "SELL" and exit_idx > i:
                exit_price = close[exit_idx]
            else:
                exit_idx_fallback = min(i + HORIZON, len(close) - 1)
                exit_price = close[exit_idx_fallback]
                exit_idx = exit_idx_fallback

            trade_equity = equity * pos_frac
            cost_in = trade_equity * (fee_pct / 100)
            pnl_pct = (entry_price / exit_price - 1) * 100
            gross = trade_equity * (1 + pnl_pct / 100)
            cost_out = gross * (fee_pct / 100)
            pnl = gross - cost_out - trade_equity
            equity += pnl
            trades.append({"pnl_pct": pnl_pct, "dir": "SHORT", "oracle_agreed": ol == "SELL", "hold": exit_idx - i})
            in_trade_until = exit_idx + 1

    tdf = pd.DataFrame(trades) if trades else pd.DataFrame()
    ret = (equity / 10_000 - 1) * 100

    agreed = tdf[tdf["oracle_agreed"]] if not tdf.empty else pd.DataFrame()
    disagreed = tdf[~tdf["oracle_agreed"]] if not tdf.empty else pd.DataFrame()

    return {
        "return_pct": ret,
        "equity": equity,
        "n_trades": len(trades),
        "win_rate": (tdf["pnl_pct"] > 0).mean() * 100 if not tdf.empty else 0,
        "avg_trade": tdf["pnl_pct"].mean() if not tdf.empty else 0,
        "n_agreed": len(agreed),
        "agreed_wr": (agreed["pnl_pct"] > 0).mean() * 100 if not agreed.empty else 0,
        "agreed_avg": agreed["pnl_pct"].mean() if not agreed.empty else 0,
        "n_disagreed": len(disagreed),
        "disagreed_wr": (disagreed["pnl_pct"] > 0).mean() * 100 if not disagreed.empty else 0,
        "disagreed_avg": disagreed["pnl_pct"].mean() if not disagreed.empty else 0,
    }


def main():
    log("Loading data...")
    df = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df["ts"])
    factory = TechnicalFeatureFactory()

    # --- Train on 2019-2020 ---
    log("Preparing 2019-2020 training data...")
    mask_seed = ts <= "2020-12-31"
    df_seed = df[mask_seed].reset_index(drop=True)
    df_seed_ind = factory.compute_indicators(df_seed)
    close_seed = df_seed_ind["close"].values

    log(f"  Labeling opportunities (min_move={MIN_MOVE}%, horizon={HORIZON})...")
    seed_labels, seed_exits = find_opportunities(close_seed, MIN_MOVE, HORIZON)
    n_buy = (seed_labels == "BUY").sum()
    n_sell = (seed_labels == "SELL").sum()
    n_quiet = (seed_labels == "QUIET").sum()
    log(f"  Labels: {n_buy} BUY / {n_sell} SELL / {n_quiet} QUIET")

    log("  Training oracle gate...")
    client = HolonClient(dimensions=OracleGate.DIM)
    gate = OracleGate(client)
    seed_features = gate._precompute(df_seed_ind)
    gate.train(df_seed_ind, seed_labels, n_train=300, features=seed_features)

    if not gate.ready:
        log("  ERROR: Gate not ready, not enough training data")
        return

    # --- Grade on 2021-2024 ---
    periods = [
        ("2021 (bull)", "2021-01-01", "2021-12-31"),
        ("2022 (bear)", "2022-01-01", "2022-12-31"),
        ("2023 (recovery)", "2023-01-01", "2023-12-31"),
        ("2024", "2024-01-01", "2024-12-31"),
    ]

    for period_name, start, end in periods:
        mask = (ts >= start) & (ts <= end)
        df_period = df[mask].reset_index(drop=True)
        if len(df_period) < 500:
            continue

        df_ind = factory.compute_indicators(df_period)
        close = df_ind["close"].values
        n = len(df_ind)
        scan_end = min(n, OracleGate.WINDOW + MAX_CANDLES)

        bah_start = float(close[OracleGate.WINDOW])
        bah_end = float(close[scan_end - 1])
        bah_pct = (bah_end / bah_start - 1) * 100

        log(f"\n{'=' * 80}")
        log(f"PERIOD: {period_name}  (scan: {scan_end - OracleGate.WINDOW} candles, B&H: {bah_pct:+.1f}%)")
        log(f"{'=' * 80}")

        # Oracle labels for this period (future knowledge — for grading only)
        close_scan = close[:scan_end]
        oracle_labels, oracle_exits = find_opportunities(close_scan, MIN_MOVE, HORIZON)

        n_opp_buy = sum(1 for i in range(OracleGate.WINDOW, scan_end) if oracle_labels[i] == "BUY")
        n_opp_sell = sum(1 for i in range(OracleGate.WINDOW, scan_end) if oracle_labels[i] == "SELL")
        log(f"  Oracle opportunities: {n_opp_buy + n_opp_sell} ({n_opp_buy}B / {n_opp_sell}S)")

        # Run gate
        log("  Running gate (adaptive)...")
        features = gate._precompute(df_ind)
        gate_labels = []
        gate_margins = []

        t0 = time.time()
        for step in range(scan_end):
            if step < OracleGate.WINDOW:
                gate_labels.append("QUIET")
                gate_margins.append(0.0)
                continue
            label, margin, _ = gate.classify(features, step, adaptive=True)
            gate_labels.append(label)
            gate_margins.append(margin)
        elapsed = time.time() - t0

        gate_labels = np.array(gate_labels)
        gate_margins = np.array(gate_margins)

        n_gate_buy = (gate_labels[OracleGate.WINDOW:scan_end] == "BUY").sum()
        n_gate_sell = (gate_labels[OracleGate.WINDOW:scan_end] == "SELL").sum()
        n_gate_quiet = (gate_labels[OracleGate.WINDOW:scan_end] == "QUIET").sum()
        log(f"  Gate classifications: {n_gate_buy}B / {n_gate_sell}S / {n_gate_quiet}Q ({elapsed:.0f}s)")

        # --- Precision / Recall ---
        PROX = 6
        # Precision: when gate says BUY, is there a real BUY opportunity nearby?
        buy_opps = set(i for i in range(OracleGate.WINDOW, scan_end) if oracle_labels[i] == "BUY")
        sell_opps = set(i for i in range(OracleGate.WINDOW, scan_end) if oracle_labels[i] == "SELL")
        gate_buy_idx = set(i for i in range(OracleGate.WINDOW, scan_end) if gate_labels[i] == "BUY")
        gate_sell_idx = set(i for i in range(OracleGate.WINDOW, scan_end) if gate_labels[i] == "SELL")

        buy_precision_hits = sum(1 for g in gate_buy_idx if any(abs(g - o) <= PROX for o in buy_opps))
        sell_precision_hits = sum(1 for g in gate_sell_idx if any(abs(g - o) <= PROX for o in sell_opps))
        total_precision = (buy_precision_hits + sell_precision_hits) / max(1, len(gate_buy_idx) + len(gate_sell_idx)) * 100

        # Exact match (same candle, same direction)
        exact_buy = sum(1 for g in gate_buy_idx if oracle_labels[g] == "BUY")
        exact_sell = sum(1 for g in gate_sell_idx if oracle_labels[g] == "SELL")
        exact_pct = (exact_buy + exact_sell) / max(1, len(gate_buy_idx) + len(gate_sell_idx)) * 100

        # Recall
        buy_recall = sum(1 for o in buy_opps if any(abs(o - g) <= PROX for g in gate_buy_idx))
        sell_recall = sum(1 for o in sell_opps if any(abs(o - g) <= PROX for g in gate_sell_idx))
        total_recall = (buy_recall + sell_recall) / max(1, len(buy_opps) + len(sell_opps)) * 100

        log(f"\n  PRECISION (±{PROX}): {total_precision:.1f}% | Exact match: {exact_pct:.1f}%")
        log(f"  RECALL (±{PROX}): {total_recall:.1f}%")

        # --- Backtest ---
        log("\n  BACKTEST (gate-directed, target exits):")
        bt = backtest_oracle_gate(close_scan, gate_labels, gate_margins,
                                  oracle_labels, oracle_exits)
        log(f"    Return: {bt['return_pct']:+.1f}% | Trades: {bt['n_trades']} | WR: {bt['win_rate']:.0f}% | Avg: {bt['avg_trade']:+.2f}%")
        log(f"    Oracle-agreed trades: {bt['n_agreed']} (WR: {bt['agreed_wr']:.0f}%, avg: {bt['agreed_avg']:+.2f}%)")
        log(f"    Disagreed trades:     {bt['n_disagreed']} (WR: {bt['disagreed_wr']:.0f}%, avg: {bt['disagreed_avg']:+.2f}%)")

        # Also test with margin threshold
        for min_m in [0.01, 0.02, 0.05]:
            bt_m = backtest_oracle_gate(close_scan, gate_labels, gate_margins,
                                        oracle_labels, oracle_exits, min_margin=min_m)
            if bt_m['n_trades'] > 0:
                log(f"    Margin>{min_m:.2f}: {bt_m['return_pct']:+.1f}% | {bt_m['n_trades']} trades | WR: {bt_m['win_rate']:.0f}% | agreed: {bt_m['n_agreed']}")

    log(f"\n{'=' * 80}")
    log("DONE")
    log(f"{'=' * 80}")


if __name__ == "__main__":
    main()
