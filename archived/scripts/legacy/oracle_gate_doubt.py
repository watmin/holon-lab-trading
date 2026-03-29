"""Oracle gate with doubt — opportunity + trap recognition.

Architecture:
  1. Opportunity layer: BUY/SELL/QUIET subspaces (trained on oracle labels)
  2. Doubt layer: TRAP_BUY/TRAP_SELL subspaces (trained on the gate's own
     mistakes on training data)

Decision flow:
  Window → Opportunity → "BUY" or "SELL"?
                              ↓
                         Doubt → TRAP residual < action residual? → REJECT
                              ↓
                         [after trade resolves]
                         Won → update Opportunity subspace
                         Lost → update TRAP subspace

Both layers bootstrap on 2019-2020, then adapt forward through 2021-2024.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/oracle_gate_doubt.py
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


class DoubtGate:
    """Opportunity + Doubt compound gate.

    Subspaces:
      Opportunity: BUY, SELL, QUIET
      Doubt: TRAP_BUY, TRAP_SELL

    Classification:
      1. Score window against opportunity subspaces → best class
      2. If BUY: compare BUY residual vs TRAP_BUY residual
         If SELL: compare SELL residual vs TRAP_SELL residual
      3. If trap residual < action residual → reject (doubt wins)

    Continuous learning:
      - Opportunity: winning subspace updated every candle (adaptive)
      - Doubt: updated only on actual losing trades
    """

    DIM = HolonGate.DIM
    K = HolonGate.K
    N_STRIPES = HolonGate.N_STRIPES
    WINDOW = HolonGate.WINDOW

    def __init__(self, client: HolonClient):
        self.client = client
        self.opportunity: dict[str, StripedSubspace] = {}
        self.doubt: dict[str, StripedSubspace] = {}
        self._ready = False

    @property
    def ready(self):
        return self._ready

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

    def _train_subspaces(self, df_ind, labels, target_labels, n_train, features, rng):
        """Train subspaces for given label set."""
        result = {}
        for label_name in target_labels:
            indices = [i for i in range(self.WINDOW, len(df_ind)) if labels[i] == label_name]
            if len(indices) < 20:
                log(f"      {label_name}: only {len(indices)} samples, skipping")
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
                result[label_name] = ss
                log(f"      {label_name}: trained on {count} windows")
        return result

    def train(self, df_ind, oracle_labels, n_train_opp=1000, n_train_doubt=500, features=None):
        """Phase 1: Train opportunity subspaces on oracle labels.
        Phase 2: Run opportunity gate over training data, find mistakes, train doubt.
        """
        rng = np.random.default_rng(42)
        if features is None:
            features = self._precompute(df_ind)

        # Phase 1: Opportunity
        log("    Phase 1: Training opportunity subspaces...")
        self.opportunity = self._train_subspaces(
            df_ind, oracle_labels, ["BUY", "SELL", "QUIET"], n_train_opp, features, rng,
        )
        self._ready = len(self.opportunity) >= 2

        if not self._ready:
            log("    ERROR: Opportunity layer not ready")
            return

        # Phase 2: Find mistakes on training data
        log("    Phase 2: Finding mistakes on training data...")
        n = len(df_ind)
        scan_limit = min(n, 50_000)  # cap for speed

        trap_buy_indices = []
        trap_sell_indices = []

        for idx in range(self.WINDOW, scan_limit):
            v = self._encode_fast(features, idx)
            if v is None:
                continue

            # What does opportunity layer think?
            residuals = {label: ss.residual(v) for label, ss in self.opportunity.items()}
            predicted = min(residuals, key=residuals.get)
            actual = oracle_labels[idx]

            # Gate says BUY but oracle disagrees
            if predicted == "BUY" and actual != "BUY":
                trap_buy_indices.append(idx)
            # Gate says SELL but oracle disagrees
            elif predicted == "SELL" and actual != "SELL":
                trap_sell_indices.append(idx)

        log(f"      Found {len(trap_buy_indices)} TRAP_BUY, {len(trap_sell_indices)} TRAP_SELL in training scan")

        # Train doubt subspaces on mistakes
        trap_labels = np.full(n, "NONE", dtype=object)
        for idx in trap_buy_indices:
            trap_labels[idx] = "TRAP_BUY"
        for idx in trap_sell_indices:
            trap_labels[idx] = "TRAP_SELL"

        log("    Phase 3: Training doubt subspaces on mistakes...")
        self.doubt = self._train_subspaces(
            df_ind, trap_labels, ["TRAP_BUY", "TRAP_SELL"], n_train_doubt, features, rng,
        )
        log(f"    Doubt layer ready: {list(self.doubt.keys())}")

    def classify(self, features, idx, adaptive_opp=True):
        """Compound classification: opportunity + doubt.

        Returns (label, confidence_info dict)
        """
        if not self.ready:
            return "QUIET", {"reason": "not_ready"}

        v = self._encode_fast(features, idx)
        if v is None:
            return "QUIET", {"reason": "encode_failed"}

        # Pass 1: Opportunity
        opp_residuals = {label: ss.residual(v) for label, ss in self.opportunity.items()}
        predicted = min(opp_residuals, key=opp_residuals.get)

        # Pass 2: Doubt check
        doubt_rejected = False
        doubt_info = {}
        if predicted in ("BUY", "SELL"):
            trap_key = f"TRAP_{predicted}"
            if trap_key in self.doubt:
                trap_residual = self.doubt[trap_key].residual(v)
                action_residual = opp_residuals[predicted]
                doubt_info = {
                    "trap_residual": trap_residual,
                    "action_residual": action_residual,
                    "trap_ratio": trap_residual / max(action_residual, 1e-10),
                }
                # If trap fits BETTER than the action class, doubt wins
                if trap_residual < action_residual:
                    doubt_rejected = True

        final_label = "QUIET" if doubt_rejected else predicted

        # Adaptive: update winning opportunity subspace
        if adaptive_opp and final_label in self.opportunity:
            self.opportunity[final_label].update(v)

        return final_label, {
            "opp_residuals": opp_residuals,
            "predicted_raw": predicted,
            "doubt_rejected": doubt_rejected,
            **doubt_info,
        }

    def learn_from_loss(self, features, idx):
        """Feed a losing trade's window into the appropriate TRAP subspace."""
        v = self._encode_fast(features, idx)
        if v is None:
            return

        # Figure out what the opportunity layer thought
        opp_residuals = {label: ss.residual(v) for label, ss in self.opportunity.items()}
        predicted = min(opp_residuals, key=opp_residuals.get)

        trap_key = f"TRAP_{predicted}"
        if trap_key not in self.doubt:
            self.doubt[trap_key] = StripedSubspace(
                dim=self.DIM, k=self.K, n_stripes=self.N_STRIPES,
            )
        self.doubt[trap_key].update(v)


def backtest_with_doubt(close, gate, features, oracle_labels, exit_indices,
                        start_idx, end_idx, fee_pct=FEE_PER_SIDE, pos_frac=POSITION_FRAC):
    """Backtest with doubt + continuous learning from losses."""
    equity = 10_000.0
    trades = []
    in_trade_until = 0
    pending_trade = None  # (entry_idx, direction, entry_price, exit_idx)

    doubt_rejects = 0
    doubt_saves = 0  # would have lost, doubt blocked it
    doubt_missed = 0  # would have won, doubt blocked it

    for i in range(start_idx, end_idx):
        # Resolve pending trade if exit reached
        if pending_trade is not None:
            entry_idx, direction, entry_price, exit_idx = pending_trade
            if i >= exit_idx:
                exit_price = close[exit_idx]
                if direction == "BUY":
                    pnl_pct = (exit_price / entry_price - 1) * 100
                else:
                    pnl_pct = (entry_price / exit_price - 1) * 100

                trade_eq = equity * pos_frac / (1 + pos_frac)  # reserved at entry
                gross_pnl = trade_eq * pnl_pct / 100
                fee_cost = abs(trade_eq) * fee_pct / 100 * 2
                net_pnl = gross_pnl - fee_cost
                equity += net_pnl

                won = net_pnl > 0
                trades.append({
                    "pnl_pct": pnl_pct, "dir": direction,
                    "agreed": oracle_labels[entry_idx] == direction,
                    "won": won, "hold": exit_idx - entry_idx,
                })

                # Continuous learning from losses
                if not won:
                    gate.learn_from_loss(features, entry_idx)

                pending_trade = None
                in_trade_until = exit_idx + 1

        if i < in_trade_until:
            continue

        label, info = gate.classify(features, i, adaptive_opp=True)

        if info.get("doubt_rejected", False):
            doubt_rejects += 1
            raw = info["predicted_raw"]
            ol = oracle_labels[i]
            if raw == "BUY" and ol != "BUY":
                doubt_saves += 1
            elif raw == "SELL" and ol != "SELL":
                doubt_saves += 1
            else:
                doubt_missed += 1

        if label in ("BUY", "SELL"):
            ol = oracle_labels[i]
            exit_idx = exit_indices[i]

            if label == "BUY":
                if ol == "BUY" and exit_idx > i:
                    actual_exit = exit_idx
                else:
                    actual_exit = min(i + HORIZON, end_idx - 1)
            else:
                if ol == "SELL" and exit_idx > i:
                    actual_exit = exit_idx
                else:
                    actual_exit = min(i + HORIZON, end_idx - 1)

            pending_trade = (i, label, close[i], actual_exit)
            in_trade_until = actual_exit + 1

    # Resolve final pending trade
    if pending_trade is not None:
        entry_idx, direction, entry_price, exit_idx = pending_trade
        exit_idx = min(exit_idx, end_idx - 1)
        exit_price = close[exit_idx]
        if direction == "BUY":
            pnl_pct = (exit_price / entry_price - 1) * 100
        else:
            pnl_pct = (entry_price / exit_price - 1) * 100

        trade_eq = equity * pos_frac / (1 + pos_frac)
        gross_pnl = trade_eq * pnl_pct / 100
        fee_cost = abs(trade_eq) * fee_pct / 100 * 2
        net_pnl = gross_pnl - fee_cost
        equity += net_pnl
        won = net_pnl > 0
        trades.append({"pnl_pct": pnl_pct, "dir": direction,
                        "agreed": oracle_labels[entry_idx] == direction, "won": won,
                        "hold": exit_idx - entry_idx})
        if not won:
            gate.learn_from_loss(features, entry_idx)

    tdf = pd.DataFrame(trades) if trades else pd.DataFrame()
    ret = (equity / 10_000 - 1) * 100
    agreed = tdf[tdf["agreed"]] if not tdf.empty else pd.DataFrame()
    disagreed = tdf[~tdf["agreed"]] if not tdf.empty else pd.DataFrame()

    return {
        "return_pct": ret,
        "equity": equity,
        "n_trades": len(trades),
        "win_rate": (tdf["won"]).mean() * 100 if not tdf.empty else 0,
        "avg_trade": tdf["pnl_pct"].mean() if not tdf.empty else 0,
        "n_agreed": len(agreed),
        "agreed_wr": (agreed["won"]).mean() * 100 if not agreed.empty else 0,
        "n_disagreed": len(disagreed),
        "disagreed_wr": (disagreed["won"]).mean() * 100 if not disagreed.empty else 0,
        "disagreed_avg": disagreed["pnl_pct"].mean() if not disagreed.empty else 0,
        "doubt_rejects": doubt_rejects,
        "doubt_saves": doubt_saves,
        "doubt_missed": doubt_missed,
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

    log(f"  Labeling (min_move={MIN_MOVE}%, horizon={HORIZON})...")
    seed_labels, _ = find_opportunities(close_seed, MIN_MOVE, HORIZON)
    n_buy = (seed_labels == "BUY").sum()
    n_sell = (seed_labels == "SELL").sum()
    n_quiet = (seed_labels == "QUIET").sum()
    log(f"  Labels: {n_buy} BUY / {n_sell} SELL / {n_quiet} QUIET")

    client = HolonClient(dimensions=DoubtGate.DIM)

    # Sweep training sizes
    configs = [
        (300, 200, "small"),
        (1000, 500, "medium"),
        (2000, 1000, "large"),
    ]

    periods = [
        ("2021 (bull)", "2021-01-01", "2021-12-31"),
        ("2022 (bear)", "2022-01-01", "2022-12-31"),
        ("2023 (recovery)", "2023-01-01", "2023-12-31"),
        ("2024", "2024-01-01", "2024-12-31"),
    ]

    for n_opp, n_doubt, config_name in configs:
        log(f"\n{'=' * 90}")
        log(f"CONFIG: {config_name} (opp={n_opp}, doubt={n_doubt})")
        log(f"{'=' * 90}")

        gate = DoubtGate(client)
        seed_features = gate._precompute(df_seed_ind)
        gate.train(df_seed_ind, seed_labels, n_train_opp=n_opp,
                   n_train_doubt=n_doubt, features=seed_features)

        if not gate.ready:
            log("  Gate not ready, skipping")
            continue

        compound = 1.0

        for period_name, start, end in periods:
            mask = (ts >= start) & (ts <= end)
            df_period = df[mask].reset_index(drop=True)
            if len(df_period) < 500:
                continue

            df_ind = factory.compute_indicators(df_period)
            close = df_ind["close"].values
            n = len(df_ind)
            scan_end = min(n, DoubtGate.WINDOW + MAX_CANDLES)
            close_scan = close[:scan_end]

            bah_start = float(close[DoubtGate.WINDOW])
            bah_end = float(close[scan_end - 1])
            bah_pct = (bah_end / bah_start - 1) * 100

            oracle_labels, oracle_exits = find_opportunities(close_scan, MIN_MOVE, HORIZON)
            features = gate._precompute(df_ind)

            bt = backtest_with_doubt(close_scan, gate, features, oracle_labels,
                                     oracle_exits, DoubtGate.WINDOW, scan_end)
            compound *= (1 + bt["return_pct"] / 100)

            doubt_eff = ""
            if bt["doubt_rejects"] > 0:
                save_rate = bt["doubt_saves"] / bt["doubt_rejects"] * 100
                doubt_eff = f"doubt: {bt['doubt_rejects']} rejected ({bt['doubt_saves']} saves / {bt['doubt_missed']} missed, {save_rate:.0f}% accuracy)"

            log(f"  {period_name:20s} | B&H {bah_pct:+6.1f}% | Ret {bt['return_pct']:+6.1f}% | {bt['n_trades']:3d} trades (agr:{bt['n_agreed']}/dis:{bt['n_disagreed']}) | WR {bt['win_rate']:4.0f}% | dis_wr {bt['disagreed_wr']:4.0f}% avg {bt['disagreed_avg']:+.2f}%")
            log(f"  {'':20s}   {doubt_eff}")

        log(f"  COMPOUND: {(compound - 1) * 100:+.1f}%")

    # --- Also run WITHOUT doubt for comparison ---
    log(f"\n{'=' * 90}")
    log("BASELINE: No doubt (opportunity only, n_train=1000)")
    log(f"{'=' * 90}")

    gate_nodoubt = DoubtGate(client)
    gate_nodoubt.train(df_seed_ind, seed_labels, n_train_opp=1000,
                       n_train_doubt=0, features=gate_nodoubt._precompute(df_seed_ind))
    gate_nodoubt.doubt = {}  # explicitly empty

    compound_nd = 1.0
    for period_name, start, end in periods:
        mask = (ts >= start) & (ts <= end)
        df_period = df[mask].reset_index(drop=True)
        if len(df_period) < 500:
            continue

        df_ind = factory.compute_indicators(df_period)
        close = df_ind["close"].values
        scan_end = min(len(df_ind), DoubtGate.WINDOW + MAX_CANDLES)
        close_scan = close[:scan_end]

        bah_start = float(close[DoubtGate.WINDOW])
        bah_end = float(close[scan_end - 1])
        bah_pct = (bah_end / bah_start - 1) * 100

        oracle_labels, oracle_exits = find_opportunities(close_scan, MIN_MOVE, HORIZON)
        features = gate_nodoubt._precompute(df_ind)

        bt = backtest_with_doubt(close_scan, gate_nodoubt, features, oracle_labels,
                                 oracle_exits, DoubtGate.WINDOW, scan_end)
        compound_nd *= (1 + bt["return_pct"] / 100)

        log(f"  {period_name:20s} | B&H {bah_pct:+6.1f}% | Ret {bt['return_pct']:+6.1f}% | {bt['n_trades']:3d} trades | WR {bt['win_rate']:4.0f}% | agr:{bt['n_agreed']} dis:{bt['n_disagreed']} dis_wr:{bt['disagreed_wr']:.0f}%")

    log(f"  COMPOUND (no doubt): {(compound_nd - 1) * 100:+.1f}%")

    log(f"\n{'=' * 90}")
    log("DONE")
    log(f"{'=' * 90}")


if __name__ == "__main__":
    main()
