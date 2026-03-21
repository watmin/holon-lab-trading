"""Parallelizable doubt gate experiment — run one config per process.

Usage:
    # Run all 4 in parallel:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/doubt_parallel.py small &
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/doubt_parallel.py medium &
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/doubt_parallel.py large &
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/doubt_parallel.py nodoubt &
    wait
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
PHASE2_SCAN = 10_000  # subsample for mistake finding (was 50k)


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
        buy_hit = sell_hit = -1
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
        o, h, l, c = df_ind["open"].values, df_ind["high"].values, df_ind["low"].values, df_ind["close"].values
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
            "body": (c - o) / rng, "upper_wick": (h - np.maximum(o, c)) / rng,
            "lower_wick": (np.minimum(o, c) - l) / rng, "close_pos": (c - l) / rng,
        }

    def _encode_fast(self, features, idx):
        start = int(idx) - self.WINDOW + 1
        if start < 0:
            return None
        walkable = {}
        for name in ["open_r", "high_r", "low_r", "vol_r", "rsi", "ret",
                      "sma20_r", "sma50_r", "macd_hist", "bb_width", "adx",
                      "body", "upper_wick", "lower_wick", "close_pos"]:
            arr = features[name]
            walkable[name] = WalkableSpread(
                [LinearScale(float(arr[start + i])) for i in range(self.WINDOW)]
            )
        return self.client.encoder.encode_walkable_striped(walkable, n_stripes=self.N_STRIPES)

    def _train_subspaces(self, df_ind, labels, target_labels, n_train, features, rng):
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

    def train(self, df_ind, oracle_labels, n_train_opp=1000, n_train_doubt=500,
              features=None, phase2_scan=PHASE2_SCAN):
        rng = np.random.default_rng(42)
        if features is None:
            features = self._precompute(df_ind)

        log("    Phase 1: Training opportunity subspaces...")
        self.opportunity = self._train_subspaces(
            df_ind, oracle_labels, ["BUY", "SELL", "QUIET"], n_train_opp, features, rng)
        self._ready = len(self.opportunity) >= 2
        if not self._ready:
            return

        if n_train_doubt <= 0:
            log("    Skipping doubt (n_train_doubt=0)")
            return

        log(f"    Phase 2: Finding mistakes (scanning {phase2_scan} random windows)...")
        n = len(df_ind)
        scan_indices = rng.choice(
            range(self.WINDOW, min(n, 50_000)), size=min(phase2_scan, n - self.WINDOW), replace=False
        )
        scan_indices.sort()

        trap_buy_idx, trap_sell_idx = [], []
        for idx in scan_indices:
            v = self._encode_fast(features, int(idx))
            if v is None:
                continue
            residuals = {label: ss.residual(v) for label, ss in self.opportunity.items()}
            predicted = min(residuals, key=residuals.get)
            actual = oracle_labels[idx]
            if predicted == "BUY" and actual != "BUY":
                trap_buy_idx.append(int(idx))
            elif predicted == "SELL" and actual != "SELL":
                trap_sell_idx.append(int(idx))

        log(f"      Found {len(trap_buy_idx)} TRAP_BUY, {len(trap_sell_idx)} TRAP_SELL")

        trap_labels = np.full(n, "NONE", dtype=object)
        for idx in trap_buy_idx:
            trap_labels[idx] = "TRAP_BUY"
        for idx in trap_sell_idx:
            trap_labels[idx] = "TRAP_SELL"

        log("    Phase 3: Training doubt subspaces...")
        self.doubt = self._train_subspaces(
            df_ind, trap_labels, ["TRAP_BUY", "TRAP_SELL"], n_train_doubt, features, rng)
        log(f"    Doubt ready: {list(self.doubt.keys())}")

    def classify(self, features, idx, adaptive_opp=True):
        if not self.ready:
            return "QUIET", {}
        v = self._encode_fast(features, idx)
        if v is None:
            return "QUIET", {}

        opp_r = {label: ss.residual(v) for label, ss in self.opportunity.items()}
        predicted = min(opp_r, key=opp_r.get)

        doubt_rejected = False
        if predicted in ("BUY", "SELL"):
            trap_key = f"TRAP_{predicted}"
            if trap_key in self.doubt:
                trap_r = self.doubt[trap_key].residual(v)
                action_r = opp_r[predicted]
                if trap_r < action_r:
                    doubt_rejected = True

        final = "QUIET" if doubt_rejected else predicted

        if adaptive_opp and final in self.opportunity:
            self.opportunity[final].update(v)

        return final, {"predicted_raw": predicted, "doubt_rejected": doubt_rejected}

    def learn_from_loss(self, features, idx):
        v = self._encode_fast(features, idx)
        if v is None:
            return
        opp_r = {label: ss.residual(v) for label, ss in self.opportunity.items()}
        predicted = min(opp_r, key=opp_r.get)
        trap_key = f"TRAP_{predicted}"
        if trap_key not in self.doubt:
            self.doubt[trap_key] = StripedSubspace(dim=self.DIM, k=self.K, n_stripes=self.N_STRIPES)
        self.doubt[trap_key].update(v)


def backtest(close, gate, features, oracle_labels, exit_indices, start_idx, end_idx):
    equity = 10_000.0
    trades = []
    in_trade_until = 0
    pending = None
    doubt_rejects = doubt_saves = doubt_missed = 0

    for i in range(start_idx, end_idx):
        if pending is not None:
            ei, d, ep, xi = pending
            if i >= xi:
                xp = close[xi]
                pnl_pct = (xp / ep - 1) * 100 if d == "BUY" else (ep / xp - 1) * 100
                trade_eq = equity * POSITION_FRAC / (1 + POSITION_FRAC)
                net = trade_eq * pnl_pct / 100 - abs(trade_eq) * FEE_PER_SIDE / 100 * 2
                equity += net
                won = net > 0
                trades.append({"pnl_pct": pnl_pct, "dir": d, "agreed": oracle_labels[ei] == d, "won": won})
                if not won:
                    gate.learn_from_loss(features, ei)
                pending = None
                in_trade_until = xi + 1

        if i < in_trade_until:
            continue

        label, info = gate.classify(features, i, adaptive_opp=True)

        if info.get("doubt_rejected", False):
            doubt_rejects += 1
            raw = info["predicted_raw"]
            ol = oracle_labels[i]
            if raw == ol:
                doubt_missed += 1
            else:
                doubt_saves += 1

        if label in ("BUY", "SELL"):
            ol = oracle_labels[i]
            xi = exit_indices[i]
            if label == ol and xi > i:
                actual_exit = xi
            else:
                actual_exit = min(i + HORIZON, end_idx - 1)
            pending = (i, label, close[i], actual_exit)
            in_trade_until = actual_exit + 1

    if pending:
        ei, d, ep, xi = pending
        xi = min(xi, end_idx - 1)
        xp = close[xi]
        pnl_pct = (xp / ep - 1) * 100 if d == "BUY" else (ep / xp - 1) * 100
        trade_eq = equity * POSITION_FRAC / (1 + POSITION_FRAC)
        net = trade_eq * pnl_pct / 100 - abs(trade_eq) * FEE_PER_SIDE / 100 * 2
        equity += net
        won = net > 0
        trades.append({"pnl_pct": pnl_pct, "dir": d, "agreed": oracle_labels[ei] == d, "won": won})
        if not won:
            gate.learn_from_loss(features, ei)

    tdf = pd.DataFrame(trades) if trades else pd.DataFrame()
    agreed = tdf[tdf["agreed"]] if not tdf.empty else pd.DataFrame()
    disagreed = tdf[~tdf["agreed"]] if not tdf.empty else pd.DataFrame()

    return {
        "return_pct": (equity / 10_000 - 1) * 100,
        "n_trades": len(trades),
        "win_rate": tdf["won"].mean() * 100 if not tdf.empty else 0,
        "avg_trade": tdf["pnl_pct"].mean() if not tdf.empty else 0,
        "n_agreed": len(agreed), "n_disagreed": len(disagreed),
        "agreed_wr": agreed["won"].mean() * 100 if not agreed.empty else 0,
        "disagreed_wr": disagreed["won"].mean() * 100 if not disagreed.empty else 0,
        "disagreed_avg": disagreed["pnl_pct"].mean() if not disagreed.empty else 0,
        "doubt_rejects": doubt_rejects, "doubt_saves": doubt_saves, "doubt_missed": doubt_missed,
    }


CONFIGS = {
    "small":   (300,  200),
    "medium":  (1000, 500),
    "large":   (2000, 1000),
    "nodoubt": (1000, 0),
}


def main():
    config_name = sys.argv[1] if len(sys.argv) > 1 else "medium"
    if config_name not in CONFIGS:
        print(f"Usage: {sys.argv[0]} [{'/'.join(CONFIGS.keys())}]")
        sys.exit(1)

    n_opp, n_doubt = CONFIGS[config_name]
    log(f"CONFIG: {config_name} (opp={n_opp}, doubt={n_doubt}, K={DoubtGate.K})")

    log("Loading data...")
    df = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df["ts"])
    factory = TechnicalFeatureFactory()

    log("Preparing 2019-2020...")
    df_seed = df[ts <= "2020-12-31"].reset_index(drop=True)
    df_seed_ind = factory.compute_indicators(df_seed)
    seed_labels, _ = find_opportunities(df_seed_ind["close"].values, MIN_MOVE, HORIZON)
    log(f"  Labels: {(seed_labels=='BUY').sum()}B / {(seed_labels=='SELL').sum()}S / {(seed_labels=='QUIET').sum()}Q")

    client = HolonClient(dimensions=DoubtGate.DIM)
    gate = DoubtGate(client)
    seed_features = gate._precompute(df_seed_ind)
    gate.train(df_seed_ind, seed_labels, n_train_opp=n_opp, n_train_doubt=n_doubt, features=seed_features)

    if not gate.ready:
        log("Gate not ready!")
        return

    periods = [
        ("2021 (bull)", "2021-01-01", "2021-12-31"),
        ("2022 (bear)", "2022-01-01", "2022-12-31"),
        ("2023 (recovery)", "2023-01-01", "2023-12-31"),
        ("2024", "2024-01-01", "2024-12-31"),
    ]

    compound = 1.0
    for period_name, start, end in periods:
        mask = (ts >= start) & (ts <= end)
        df_period = df[mask].reset_index(drop=True)
        if len(df_period) < 500:
            continue

        df_ind = factory.compute_indicators(df_period)
        close = df_ind["close"].values
        scan_end = min(len(df_ind), DoubtGate.WINDOW + MAX_CANDLES)
        close_scan = close[:scan_end]
        bah_pct = (close[scan_end - 1] / close[DoubtGate.WINDOW] - 1) * 100

        oracle_labels, oracle_exits = find_opportunities(close_scan, MIN_MOVE, HORIZON)
        features = gate._precompute(df_ind)

        t0 = time.time()
        bt = backtest(close_scan, gate, features, oracle_labels, oracle_exits, DoubtGate.WINDOW, scan_end)
        elapsed = time.time() - t0
        compound *= (1 + bt["return_pct"] / 100)

        doubt_str = ""
        if bt["doubt_rejects"] > 0:
            acc = bt["doubt_saves"] / bt["doubt_rejects"] * 100
            doubt_str = f" | doubt: {bt['doubt_rejects']}rej ({bt['doubt_saves']}save/{bt['doubt_missed']}miss {acc:.0f}%)"

        log(f"  {period_name:20s} | B&H {bah_pct:+6.1f}% | Ret {bt['return_pct']:+6.1f}% | {bt['n_trades']:3d} trades (agr:{bt['n_agreed']}/dis:{bt['n_disagreed']}) | WR {bt['win_rate']:4.0f}% | dis_wr {bt['disagreed_wr']:4.0f}% avg {bt['disagreed_avg']:+.2f}%{doubt_str} | {elapsed:.0f}s")

    log(f"\n  COMPOUND ({config_name}): {(compound - 1) * 100:+.1f}%")
    log("DONE")


if __name__ == "__main__":
    main()
