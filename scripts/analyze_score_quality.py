"""Analyze whether prototype score magnitude predicts trade quality.

For each BUY signal fired during 2021, compute the forward return and
correlate with the prototype score. This tells us whether being more
selective (higher threshold) actually improves trade quality, or if the
signal is uniformly mediocre.

Also tests: what if we require BOTH a strong BUY entry AND wait for a
strong SELL signal to exit? (Signal-to-signal trading instead of
signal-to-any-exit.)

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/analyze_score_quality.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.signal import find_peaks

sys.path.insert(0, str(Path(__file__).parent.parent))

from trading.encoder import OHLCVEncoder
from trading.features import TechnicalFeatureFactory
from holon import HolonClient
from holon.kernel.primitives import prototype, negate

DIM = 1024
N_STRIPES = OHLCVEncoder.N_STRIPES
WINDOW = OHLCVEncoder.WINDOW_CANDLES
FEE_RATE = 0.001


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def cos(a, b):
    na, nb = np.linalg.norm(a), np.linalg.norm(b)
    return float(np.dot(a.astype(float), b.astype(float)) / (na * nb)) if na > 1e-9 and nb > 1e-9 else 0.0


def main():
    log("Loading data...")
    df = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df["ts"])

    # Build prototypes from seed period
    df_seed = df[ts <= "2020-12-31"].reset_index(drop=True)
    close = df_seed["close"].values
    prominence = float(np.median(close)) * 0.02

    peaks, _ = find_peaks(close, prominence=prominence, distance=12)
    troughs, _ = find_peaks(-close, prominence=prominence, distance=12)

    factory = TechnicalFeatureFactory()
    df_seed_ind = factory.compute_indicators(df_seed)
    n_dropped = len(df_seed) - len(df_seed_ind)

    peaks_ind = peaks - n_dropped
    troughs_ind = troughs - n_dropped
    peaks_ind = peaks_ind[(peaks_ind >= WINDOW) & (peaks_ind < len(df_seed_ind))]
    troughs_ind = troughs_ind[(troughs_ind >= WINDOW) & (troughs_ind < len(df_seed_ind))]

    client = HolonClient(dimensions=DIM)
    encoder = OHLCVEncoder(client, n_stripes=N_STRIPES)
    rng = np.random.default_rng(42)

    def encode_at(df_ind, indices, max_n):
        vecs = []
        for idx in indices[:max_n + 50]:
            start = int(idx) - WINDOW + 1
            if start < 0 or int(idx) >= len(df_ind):
                continue
            w = df_ind.iloc[start:int(idx) + 1]
            if len(w) < WINDOW:
                continue
            try:
                v = encoder.encode_from_precomputed(w)
                vecs.append(v)
            except Exception:
                continue
            if len(vecs) >= max_n:
                break
        return vecs

    buy_vecs = encode_at(df_seed_ind, troughs_ind, 300)
    sell_vecs = encode_at(df_seed_ind, peaks_ind, 300)

    rev_set = set(troughs_ind.tolist()) | set(peaks_ind.tolist())
    hold_pool = [i for i in range(WINDOW, len(df_seed_ind)) if i not in rev_set]
    hold_sample = rng.choice(hold_pool, size=300, replace=False)
    hold_vecs = encode_at(df_seed_ind, hold_sample, 300)

    log(f"Building prototypes: {len(buy_vecs)} BUY, {len(sell_vecs)} SELL, {len(hold_vecs)} HOLD")

    buy_protos = []
    sell_protos = []
    hold_protos = []
    for s in range(N_STRIPES):
        buy_protos.append(prototype([v[s] for v in buy_vecs]))
        sell_protos.append(prototype([v[s] for v in sell_vecs]))
        hold_protos.append(prototype([v[s] for v in hold_vecs]))

    buy_signal = [negate(buy_protos[s], hold_protos[s]) for s in range(N_STRIPES)]
    sell_signal = [negate(sell_protos[s], hold_protos[s]) for s in range(N_STRIPES)]

    # Load 2021 test data
    test_mask = (ts >= "2021-01-01") & (ts <= "2021-12-31")
    df_test = df[test_mask].reset_index(drop=True)
    df_test_ind = factory.compute_indicators(df_test)
    log(f"Test data: {len(df_test_ind):,} candles")

    # Score every candle and record forward returns
    log("Scoring all candles (this takes a while)...")
    records = []
    t0 = time.time()

    for step in range(WINDOW, len(df_test_ind)):
        start = step - WINDOW + 1
        w = df_test_ind.iloc[start:step + 1]
        if len(w) < WINDOW:
            continue

        try:
            v = encoder.encode_from_precomputed(w)
        except Exception:
            continue

        buy_score = np.mean([cos(v[s], buy_signal[s]) for s in range(N_STRIPES)])
        sell_score = np.mean([cos(v[s], sell_signal[s]) for s in range(N_STRIPES)])

        price = float(df_test_ind.iloc[step]["close"])

        # Forward returns at various horizons
        fwd = {}
        for h, label in [(3, "15m"), (6, "30m"), (12, "1h"), (24, "2h"), (48, "4h")]:
            if step + h < len(df_test_ind):
                fp = float(df_test_ind.iloc[step + h]["close"])
                fwd[label] = (fp / price - 1) * 100
            else:
                fwd[label] = None

        records.append({
            "step": step, "price": price,
            "buy_score": buy_score, "sell_score": sell_score,
            **{f"fwd_{k}": v for k, v in fwd.items()},
        })

        if (step - WINDOW) % 10000 == 0:
            elapsed = time.time() - t0
            log(f"  step {step:,} ({(step - WINDOW) / (len(df_test_ind) - WINDOW) * 100:.0f}%) "
                f"  {elapsed:.0f}s")

    log(f"Scored {len(records):,} candles in {time.time() - t0:.0f}s")

    rdf = pd.DataFrame(records)

    # ===================================================================
    # ANALYSIS 1: Does score magnitude predict forward return?
    # ===================================================================
    log("\n" + "=" * 70)
    log("ANALYSIS 1: BUY score magnitude vs forward 1h return")
    log("=" * 70)

    buy_signals = rdf[rdf["buy_score"] > rdf["sell_score"]].copy()
    buy_signals = buy_signals[buy_signals["fwd_1h"].notna()]

    for lo, hi in [(0.10, 0.15), (0.15, 0.18), (0.18, 0.22), (0.22, 0.30), (0.10, 0.30)]:
        band = buy_signals[(buy_signals["buy_score"] >= lo) & (buy_signals["buy_score"] < hi)]
        if len(band) < 10:
            continue
        mean_ret = band["fwd_1h"].mean()
        median_ret = band["fwd_1h"].median()
        pct_positive = (band["fwd_1h"] > 0.2).mean() * 100  # > fee threshold
        log(f"  score [{lo:.2f}, {hi:.2f}): n={len(band):,}  "
            f"mean_1h={mean_ret:+.3f}%  median_1h={median_ret:+.3f}%  "
            f">0.2%={pct_positive:.0f}%")

    # ===================================================================
    # ANALYSIS 2: Same for SELL signals
    # ===================================================================
    log("\n" + "=" * 70)
    log("ANALYSIS 2: SELL score magnitude vs forward 1h return")
    log("  (expecting negative returns = price drops after SELL signal)")
    log("=" * 70)

    sell_signals = rdf[rdf["sell_score"] > rdf["buy_score"]].copy()
    sell_signals = sell_signals[sell_signals["fwd_1h"].notna()]

    for lo, hi in [(0.10, 0.15), (0.15, 0.18), (0.18, 0.22), (0.22, 0.30), (0.10, 0.30)]:
        band = sell_signals[(sell_signals["sell_score"] >= lo) & (sell_signals["sell_score"] < hi)]
        if len(band) < 10:
            continue
        mean_ret = band["fwd_1h"].mean()
        median_ret = band["fwd_1h"].median()
        pct_negative = (band["fwd_1h"] < -0.2).mean() * 100  # price drops > fee
        log(f"  score [{lo:.2f}, {hi:.2f}): n={len(band):,}  "
            f"mean_1h={mean_ret:+.3f}%  median_1h={median_ret:+.3f}%  "
            f"<-0.2%={pct_negative:.0f}%")

    # ===================================================================
    # ANALYSIS 3: Signal-to-signal trading simulation
    # ===================================================================
    log("\n" + "=" * 70)
    log("ANALYSIS 3: Signal-to-signal trading")
    log("  BUY when buy_score > thresh, SELL only when sell_score > thresh")
    log("  (instead of selling at any sell signal)")
    log("=" * 70)

    for buy_thresh in [0.15, 0.18, 0.20, 0.22, 0.25]:
        for sell_thresh in [0.15, 0.18, 0.20]:
            balance = 10000.0
            btc = 0.0
            entry_price = 0.0
            wins = 0
            losses = 0
            win_pnls = []
            loss_pnls = []

            for _, row in rdf.iterrows():
                bs = row["buy_score"]
                ss = row["sell_score"]
                price = row["price"]

                if btc == 0 and bs > ss and bs > buy_thresh:
                    btc = (balance * (1 - FEE_RATE)) / price
                    entry_price = price
                    balance = 0.0
                elif btc > 0 and ss > bs and ss > sell_thresh:
                    proceeds = btc * price * (1 - FEE_RATE)
                    pnl = (price / entry_price - 1) * 100 - 0.2
                    if pnl > 0:
                        wins += 1
                        win_pnls.append(pnl)
                    else:
                        losses += 1
                        loss_pnls.append(pnl)
                    balance = proceeds
                    btc = 0.0

            equity = balance + btc * rdf.iloc[-1]["price"]
            pnl_pct = (equity / 10000 - 1) * 100
            total = wins + losses
            wr = wins / total * 100 if total > 0 else 0
            avg_win = np.mean(win_pnls) if win_pnls else 0
            avg_loss = np.mean(loss_pnls) if loss_pnls else 0
            expect = (wins * avg_win + losses * avg_loss) / total if total > 0 else 0

            log(f"  buy>{buy_thresh:.2f} sell>{sell_thresh:.2f}: "
                f"equity=${equity:,.0f} ({pnl_pct:+.1f}%)  "
                f"trades={total}  wr={wr:.0f}%  "
                f"avg_w={avg_win:+.2f}% avg_l={avg_loss:+.2f}%  "
                f"expect={expect:+.3f}%/trade")

    # ===================================================================
    # ANALYSIS 4: What's the baseline? Buy & hold for 2021
    # ===================================================================
    log("\n" + "=" * 70)
    log("ANALYSIS 4: Baseline — Buy & Hold 2021")
    log("=" * 70)
    bah_start = rdf.iloc[0]["price"]
    bah_end = rdf.iloc[-1]["price"]
    bah_ret = (bah_end / bah_start - 1) * 100
    log(f"  ${bah_start:,.0f} → ${bah_end:,.0f} = {bah_ret:+.1f}%")

    # ===================================================================
    # ANALYSIS 5: Score distribution — how many signals at each level?
    # ===================================================================
    log("\n" + "=" * 70)
    log("ANALYSIS 5: Score distribution — signal frequency")
    log("=" * 70)

    for thresh in [0.10, 0.15, 0.18, 0.20, 0.22, 0.25, 0.30]:
        n_buy = (buy_signals["buy_score"] >= thresh).sum()
        n_sell = (sell_signals["sell_score"] >= thresh).sum()
        total_candles = len(rdf)
        log(f"  thresh={thresh:.2f}: {n_buy:,} BUY signals ({n_buy/total_candles*100:.1f}%)  "
            f"{n_sell:,} SELL signals ({n_sell/total_candles*100:.1f}%)")


if __name__ == "__main__":
    main()
