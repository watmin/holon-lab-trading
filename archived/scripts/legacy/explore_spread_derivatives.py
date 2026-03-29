"""Test SPREAD w=6 with derivative fields + forward return analysis.

Combines findings:
  - SPREAD encoding (field-series fan-out) — best BUY separation
  - Window=6 (30 min) — best discrimination across approaches
  - Derivative fields (delta, acceleration) — captures "about to change"
  - TimeScale for time features
  - Forward return analysis — does discrimination translate to profitability?

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/explore_spread_derivatives.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.signal import find_peaks

sys.path.insert(0, str(Path(__file__).parent.parent))

from trading.features import TechnicalFeatureFactory
from holon import HolonClient
from holon.kernel.walkable import LinearScale, TimeScale, WalkableSpread
from holon.memory import StripedSubspace

DIM = 1024
K = 4
N_STRIPES = 32
WINDOW = 6


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def load_data():
    log("Loading data...")
    df = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df["ts"])
    df_seed = df[ts <= "2020-12-31"].reset_index(drop=True)
    close = df_seed["close"].values
    prominence = float(np.median(close)) * 0.02
    peaks, _ = find_peaks(close, prominence=prominence, distance=12)
    troughs, _ = find_peaks(-close, prominence=prominence, distance=12)
    factory = TechnicalFeatureFactory()
    df_ind = factory.compute_indicators(df_seed)
    n_dropped = len(df_seed) - len(df_ind)
    peaks_ind = peaks - n_dropped
    troughs_ind = troughs - n_dropped
    peaks_ind = peaks_ind[(peaks_ind >= WINDOW + 1) & (peaks_ind < len(df_ind))]
    troughs_ind = troughs_ind[(troughs_ind >= WINDOW + 1) & (troughs_ind < len(df_ind))]
    log(f"  {len(troughs_ind)} BUY, {len(peaks_ind)} SELL reversals")
    return df_ind, troughs_ind, peaks_ind, df, ts


FIELDS = [
    ("ohlcv", "open_r",  lambda c: c["ohlcv"]["open_r"]),
    ("ohlcv", "high_r",  lambda c: c["ohlcv"]["high_r"]),
    ("ohlcv", "low_r",   lambda c: c["ohlcv"]["low_r"]),
    ("vol",   "vol_r",   lambda c: c["vol_r"]),
    ("vol",   "atr_r",   lambda c: c["atr_r"]),
    ("osc",   "rsi",     lambda c: c["rsi"]),
    ("osc",   "ret",     lambda c: c["ret"]),
    ("trend", "sma20_r", lambda c: c["sma"]["s20_r"]),
    ("trend", "sma50_r", lambda c: c["sma"]["s50_r"]),
    ("trend", "sma200_r",lambda c: c["sma"]["s200_r"]),
    ("macd",  "line_r",  lambda c: c["macd"]["line_r"]),
    ("macd",  "signal_r",lambda c: c["macd"]["signal_r"]),
    ("macd",  "hist_r",  lambda c: c["macd"]["hist_r"]),
    ("bb",    "width",   lambda c: c["bb"]["width"]),
    ("dmi",   "plus",    lambda c: c["dmi"]["plus"]),
    ("dmi",   "minus",   lambda c: c["dmi"]["minus"]),
    ("dmi",   "adx",     lambda c: c["dmi"]["adx"]),
]


def build_spread_walkable(factory, df_ind, idx, include_derivatives=False):
    """Build SPREAD field-series walkable."""
    start = int(idx) - WINDOW + 1
    if start < 0 or int(idx) >= len(df_ind):
        return None

    candles = []
    for i in range(WINDOW):
        raw = factory.compute_candle_row(df_ind, start + i)
        candles.append(raw)

    walkable = {}
    for group, name, extractor in FIELDS:
        values = [extractor(c) for c in candles]
        walkable[f"{group}_{name}"] = WalkableSpread(
            [LinearScale(v) for v in values]
        )

        if include_derivatives and len(values) >= 2:
            # First derivative (delta between consecutive values)
            deltas = [values[i+1] - values[i] for i in range(len(values)-1)]
            walkable[f"d_{group}_{name}"] = WalkableSpread(
                [LinearScale(d) for d in deltas]
            )

            if len(deltas) >= 2:
                # Second derivative (acceleration)
                accels = [deltas[i+1] - deltas[i] for i in range(len(deltas)-1)]
                walkable[f"dd_{group}_{name}"] = WalkableSpread(
                    [LinearScale(a) for a in accels]
                )

    ts_col = "ts" if "ts" in df_ind.columns else "timestamp"
    if ts_col in df_ind.columns:
        last_ts = pd.to_datetime(df_ind[ts_col].iloc[int(idx)])
        walkable["time"] = TimeScale(last_ts.timestamp())

    return walkable


def encode_windows(client, factory, df_ind, indices, include_deriv, max_n=200):
    vecs = []
    for idx in indices[:max_n + 50]:
        try:
            w = build_spread_walkable(factory, df_ind, idx, include_deriv)
            if w is None:
                continue
            v = client.encoder.encode_walkable_striped(w, n_stripes=N_STRIPES)
            vecs.append(v)
        except Exception as e:
            if len(vecs) < 2:
                log(f"    error: {e}")
            continue
        if len(vecs) >= max_n:
            break
    return vecs


def measure(name, buy_vecs, sell_vecs, hold_vecs, n_train=120, n_test=50):
    if len(buy_vecs) < n_train + n_test or len(sell_vecs) < n_train + n_test:
        log(f"  {name}: insufficient data")
        return None

    ss_b = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    ss_s = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    ss_h = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    for v in buy_vecs[:n_train]: ss_b.update(v)
    for v in sell_vecs[:n_train]: ss_s.update(v)
    for v in hold_vecs[:min(n_train, len(hold_vecs))]: ss_h.update(v)

    correct, total, margins, buy_seps, sell_seps = 0, 0, [], [], []
    test_b = buy_vecs[n_train:n_train + n_test]
    test_s = sell_vecs[n_train:n_train + n_test]
    nh = min(n_train, len(hold_vecs))
    test_h = hold_vecs[nh:nh + n_test]

    for li, ts_set in [(0, test_b), (1, test_s), (2, test_h)]:
        for v in ts_set:
            rs = [ss_b.residual(v), ss_s.residual(v), ss_h.residual(v)]
            if int(np.argmin(rs)) == li: correct += 1
            total += 1
            sr = sorted(rs)
            margins.append(sr[1] - sr[0])
    for v in test_b: buy_seps.append(ss_h.residual(v) - ss_b.residual(v))
    for v in test_s: sell_seps.append(ss_h.residual(v) - ss_s.residual(v))

    acc = correct / total * 100 if total > 0 else 0
    align = ss_b._stripes[0].subspace_alignment(ss_s._stripes[0])
    log(f"  {name}: acc={acc:.0f}%  margin={np.mean(margins):.2f}  "
        f"buy_sep={np.mean(buy_seps):+.1f}  sell_sep={np.mean(sell_seps):+.1f}  "
        f"B-S align={align:.3f}")
    return {"accuracy": acc, "margin": np.mean(margins),
            "buy_sep": np.mean(buy_seps), "sell_sep": np.mean(sell_seps),
            "ss_b": ss_b, "ss_s": ss_s, "ss_h": ss_h}


def forward_return_analysis(client, factory, df_test_ind, ss_b, ss_s, ss_h,
                            include_deriv, label=""):
    """Score every candle in test data and correlate with forward returns."""
    log(f"\n  FORWARD RETURN ANALYSIS: {label}")
    log(f"  Scoring {len(df_test_ind) - WINDOW:,} candles...")

    records = []
    t0 = time.time()
    for step in range(WINDOW, len(df_test_ind)):
        try:
            w = build_spread_walkable(factory, df_test_ind, step, include_deriv)
            if w is None:
                continue
            v = client.encoder.encode_walkable_striped(w, n_stripes=N_STRIPES)
        except Exception:
            continue

        rb = ss_b.residual(v)
        rs = ss_s.residual(v)
        rh = ss_h.residual(v)
        price = float(df_test_ind.iloc[step]["close"])

        best = min(rb, rs, rh)
        if best == rb:
            pred = "BUY"
        elif best == rs:
            pred = "SELL"
        else:
            pred = "HOLD"

        buy_margin = rh - rb
        sell_margin = rh - rs

        fwd = {}
        for h, lbl in [(1, "5m"), (3, "15m"), (6, "30m"), (12, "1h")]:
            if step + h < len(df_test_ind):
                fp = float(df_test_ind.iloc[step + h]["close"])
                fwd[lbl] = (fp / price - 1) * 100

        records.append({
            "step": step, "price": price, "pred": pred,
            "buy_r": rb, "sell_r": rs, "hold_r": rh,
            "buy_margin": buy_margin, "sell_margin": sell_margin,
            **{f"fwd_{k}": v for k, v in fwd.items()},
        })

        if (step - WINDOW) % 20000 == 0 and step > WINDOW:
            log(f"    step {step:,} ({(step - WINDOW) / (len(df_test_ind) - WINDOW) * 100:.0f}%)")

    log(f"  Scored {len(records):,} candles in {time.time() - t0:.0f}s")
    rdf = pd.DataFrame(records)

    # BUY signals by margin
    buy_signals = rdf[rdf["pred"] == "BUY"].copy()
    log(f"\n  BUY signals: {len(buy_signals):,} / {len(rdf):,} "
        f"({len(buy_signals)/len(rdf)*100:.1f}%)")

    if "fwd_1h" not in rdf.columns or buy_signals.empty:
        return

    for lo, hi in [(0, 2), (2, 5), (5, 10), (10, 20), (20, 100)]:
        band = buy_signals[(buy_signals["buy_margin"] >= lo) & (buy_signals["buy_margin"] < hi)]
        if len(band) < 10:
            continue
        if "fwd_1h" in band.columns:
            m = band["fwd_1h"].mean()
            med = band["fwd_1h"].median()
            pct_win = (band["fwd_1h"] > 0.2).mean() * 100
            log(f"    margin [{lo:>2},{hi:>3}): n={len(band):>6,}  "
                f"mean_1h={m:+.4f}%  med={med:+.4f}%  >0.2%={pct_win:.0f}%")

    # SELL signals
    sell_signals = rdf[rdf["pred"] == "SELL"].copy()
    log(f"\n  SELL signals: {len(sell_signals):,} / {len(rdf):,} "
        f"({len(sell_signals)/len(rdf)*100:.1f}%)")

    for lo, hi in [(0, 2), (2, 5), (5, 10), (10, 20), (20, 100)]:
        band = sell_signals[(sell_signals["sell_margin"] >= lo) & (sell_signals["sell_margin"] < hi)]
        if len(band) < 10:
            continue
        if "fwd_1h" in band.columns:
            m = band["fwd_1h"].mean()
            med = band["fwd_1h"].median()
            pct_drop = (band["fwd_1h"] < -0.2).mean() * 100
            log(f"    margin [{lo:>2},{hi:>3}): n={len(band):>6,}  "
                f"mean_1h={m:+.4f}%  med={med:+.4f}%  <-0.2%={pct_drop:.0f}%")

    # HOLD signals (should be near zero)
    hold_signals = rdf[rdf["pred"] == "HOLD"]
    log(f"\n  HOLD signals: {len(hold_signals):,} ({len(hold_signals)/len(rdf)*100:.1f}%)")
    if not hold_signals.empty and "fwd_1h" in hold_signals.columns:
        log(f"    mean_1h={hold_signals['fwd_1h'].mean():+.4f}%  "
            f"med={hold_signals['fwd_1h'].median():+.4f}%")

    # Quick simulated trading
    log(f"\n  SIMULATED TRADING (margin-based):")
    for min_margin in [0, 2, 5, 10, 15]:
        balance = 10000.0
        btc = 0.0
        entry = 0.0
        wins, losses = 0, 0
        for _, row in rdf.iterrows():
            if btc == 0 and row["pred"] == "BUY" and row["buy_margin"] >= min_margin:
                btc = (balance * 0.999) / row["price"]
                entry = row["price"]
                balance = 0.0
            elif btc > 0 and row["pred"] == "SELL" and row["sell_margin"] >= min_margin:
                proceeds = btc * row["price"] * 0.999
                pnl = row["price"] / entry - 1
                if pnl > 0.002:
                    wins += 1
                else:
                    losses += 1
                balance = proceeds
                btc = 0.0
        equity = balance + btc * rdf.iloc[-1]["price"]
        pnl_pct = (equity / 10000 - 1) * 100
        total = wins + losses
        wr = wins / total * 100 if total > 0 else 0
        log(f"    min_margin>={min_margin:>2}: equity=${equity:>8,.0f} ({pnl_pct:+.1f}%)  "
            f"trades={total}  wr={wr:.0f}%")


def main():
    df_ind, troughs_ind, peaks_ind, df_full, ts_full = load_data()
    factory = TechnicalFeatureFactory()
    rng = np.random.default_rng(42)

    rev_set = set(troughs_ind.tolist()) | set(peaks_ind.tolist())
    hold_pool = [i for i in range(WINDOW + 1, len(df_ind)) if i not in rev_set]
    hold_sample = rng.choice(hold_pool, size=400, replace=False)

    # ===================================================================
    # EXP 1: SPREAD w=6 (no derivatives)
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXP 1: SPREAD w=6 — no derivatives")
    log("=" * 70)
    client1 = HolonClient(dimensions=DIM)
    b1 = encode_windows(client1, factory, df_ind, troughs_ind, False, 200)
    s1 = encode_windows(client1, factory, df_ind, peaks_ind, False, 200)
    h1 = encode_windows(client1, factory, df_ind, hold_sample, False, 200)
    log(f"  {len(b1)} BUY, {len(s1)} SELL, {len(h1)} HOLD")
    r1 = measure("SPREAD_w6", b1, s1, h1)

    # Count leaves
    test_w = build_spread_walkable(factory, df_ind, int(troughs_ind[0]), False)
    n_leaves = sum(1 for k, v in test_w.items() if k != "time"
                   for _ in (v._data if hasattr(v, '_data') else [v]))
    log(f"  Leaves: {n_leaves} ({n_leaves/N_STRIPES:.1f}/stripe)")

    # ===================================================================
    # EXP 2: SPREAD w=6 + derivatives
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXP 2: SPREAD w=6 + first & second derivatives")
    log("=" * 70)
    client2 = HolonClient(dimensions=DIM)
    b2 = encode_windows(client2, factory, df_ind, troughs_ind, True, 200)
    s2 = encode_windows(client2, factory, df_ind, peaks_ind, True, 200)
    h2 = encode_windows(client2, factory, df_ind, hold_sample, True, 200)
    log(f"  {len(b2)} BUY, {len(s2)} SELL, {len(h2)} HOLD")
    r2 = measure("SPREAD_w6_deriv", b2, s2, h2)

    test_w2 = build_spread_walkable(factory, df_ind, int(troughs_ind[0]), True)
    n_leaves2 = sum(1 for k, v in test_w2.items() if k != "time"
                    for _ in (v._data if hasattr(v, '_data') else [v]))
    log(f"  Leaves: {n_leaves2} ({n_leaves2/N_STRIPES:.1f}/stripe)")

    # ===================================================================
    # FORWARD RETURN ANALYSIS on 2021 data
    # ===================================================================
    log("\n" + "=" * 70)
    log("FORWARD RETURN ANALYSIS — 2021 held-out data")
    log("=" * 70)

    test_mask = (ts_full >= "2021-01-01") & (ts_full <= "2021-12-31")
    df_test = df_full[test_mask].reset_index(drop=True)
    df_test_ind = factory.compute_indicators(df_test)
    log(f"Test data: {len(df_test_ind):,} candles")

    bah_start = float(df_test_ind.iloc[WINDOW]["close"])
    bah_end = float(df_test_ind.iloc[-1]["close"])
    log(f"Buy & Hold: ${bah_start:,.0f} → ${bah_end:,.0f} = {(bah_end/bah_start-1)*100:+.1f}%")

    if r1:
        forward_return_analysis(client1, factory, df_test_ind,
                                r1["ss_b"], r1["ss_s"], r1["ss_h"],
                                False, "SPREAD w=6")

    if r2:
        forward_return_analysis(client2, factory, df_test_ind,
                                r2["ss_b"], r2["ss_s"], r2["ss_h"],
                                True, "SPREAD w=6 + derivatives")


if __name__ == "__main__":
    main()
