"""Explore clustered engrams + hybrid scoring.

Tests whether regime-segmented engrams (oversold vs moderate) with prototype-
based scoring outperform monolithic engrams.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/explore_clustered.py
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
from holon.kernel.primitives import prototype, negate, resonance
from holon.memory import StripedSubspace

DIM = 1024
K = 4
N_STRIPES = 32
WINDOW = OHLCVEncoder.WINDOW_CANDLES


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
    peaks_ind = peaks_ind[peaks_ind >= WINDOW + 1]
    troughs_ind = troughs_ind[troughs_ind >= WINDOW + 1]

    log(f"  {len(troughs_ind)} BUY, {len(peaks_ind)} SELL reversals")
    return df_ind, troughs_ind, peaks_ind


def encode_windows(encoder, df_ind, indices, max_n=400):
    vecs = []
    valid_idx = []
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
            valid_idx.append(int(idx))
        except Exception:
            continue
        if len(vecs) >= max_n:
            break
    return vecs, valid_idx


def classify_regime(df_ind, idx):
    """Classify the market regime at a given index."""
    row = df_ind.iloc[idx]
    rsi = row.get("rsi", 50)
    vol = row.get("volume", 0)
    vol_sma = df_ind["volume"].iloc[max(0, idx - 50):idx].mean() if idx > 50 else vol

    is_oversold = rsi < 35
    is_overbought = rsi > 65
    is_high_vol = vol > vol_sma * 1.2

    if is_oversold:
        return "oversold_vol" if is_high_vol else "oversold_quiet"
    elif is_overbought:
        return "overbought_vol" if is_high_vol else "overbought_quiet"
    else:
        return "moderate_vol" if is_high_vol else "moderate_quiet"


def cos(a, b):
    na, nb = np.linalg.norm(a), np.linalg.norm(b)
    return float(np.dot(a.astype(float), b.astype(float)) / (na * nb)) if na > 1e-9 and nb > 1e-9 else 0.0


def main():
    df_ind, troughs_ind, peaks_ind = load_data()

    client = HolonClient(dimensions=DIM)
    encoder = OHLCVEncoder(client, n_stripes=N_STRIPES)
    rng = np.random.default_rng(42)

    rev_set = set(troughs_ind.tolist()) | set(peaks_ind.tolist())
    hold_pool = [i for i in range(WINDOW + 1, len(df_ind)) if i not in rev_set]
    hold_sample = rng.choice(hold_pool, size=400, replace=False)

    log("Encoding all windows...")
    buy_vecs, buy_idx = encode_windows(encoder, df_ind, troughs_ind, max_n=400)
    sell_vecs, sell_idx = encode_windows(encoder, df_ind, peaks_ind, max_n=400)
    hold_vecs, hold_idx = encode_windows(encoder, df_ind, hold_sample, max_n=400)
    log(f"  {len(buy_vecs)} BUY, {len(sell_vecs)} SELL, {len(hold_vecs)} HOLD")

    # ===================================================================
    # Classify regimes
    # ===================================================================
    buy_regimes = [classify_regime(df_ind, i) for i in buy_idx]
    sell_regimes = [classify_regime(df_ind, i) for i in sell_idx]

    log("\nBUY regime distribution:")
    for regime in sorted(set(buy_regimes)):
        cnt = buy_regimes.count(regime)
        log(f"  {regime}: {cnt} ({cnt/len(buy_regimes)*100:.0f}%)")

    log("\nSELL regime distribution:")
    for regime in sorted(set(sell_regimes)):
        cnt = sell_regimes.count(regime)
        log(f"  {regime}: {cnt} ({cnt/len(sell_regimes)*100:.0f}%)")

    # ===================================================================
    # EXPERIMENT A: MONOLITHIC (baseline)
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXPERIMENT A: MONOLITHIC — single BUY, SELL, HOLD engram")
    log("=" * 70)
    n_train = 200
    n_test = 100

    ss_b = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    ss_s = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    ss_h = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)

    for v in buy_vecs[:n_train]:
        ss_b.update(v)
    for v in sell_vecs[:n_train]:
        ss_s.update(v)
    for v in hold_vecs[:n_train]:
        ss_h.update(v)

    log(f"  Trained on {n_train} each")

    test_buy = buy_vecs[n_train:n_train + n_test]
    test_sell = sell_vecs[n_train:n_train + n_test]
    test_hold = hold_vecs[n_train:n_train + n_test]

    correct_mono = 0
    total_mono = 0
    mono_trades = []

    for label, test_set in [("BUY", test_buy), ("SELL", test_sell), ("HOLD", test_hold)]:
        for v in test_set:
            rb = ss_b.residual(v)
            rs = ss_s.residual(v)
            rh = ss_h.residual(v)
            best_r = min(rb, rs, rh)
            predicted = {rb: "BUY", rs: "SELL", rh: "HOLD"}[best_r]
            if predicted == label:
                correct_mono += 1
            total_mono += 1
            mono_trades.append({
                "true": label, "pred": predicted,
                "buy_r": rb, "sell_r": rs, "hold_r": rh,
            })

    mono_acc = correct_mono / total_mono * 100
    log(f"  MONOLITHIC accuracy: {mono_acc:.0f}%")

    # Compute per-class accuracy
    for label in ["BUY", "SELL", "HOLD"]:
        subset = [t for t in mono_trades if t["true"] == label]
        correct = sum(1 for t in subset if t["pred"] == label)
        log(f"    {label}: {correct}/{len(subset)} ({correct/len(subset)*100:.0f}%)")

    # ===================================================================
    # EXPERIMENT B: CLUSTERED ENGRAMS — regime-specific
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXPERIMENT B: CLUSTERED — oversold vs moderate engrams")
    log("=" * 70)

    # Split BUY by regime
    buy_oversold = [(v, i) for v, r, i in zip(buy_vecs, buy_regimes, buy_idx)
                    if r.startswith("oversold")]
    buy_moderate = [(v, i) for v, r, i in zip(buy_vecs, buy_regimes, buy_idx)
                    if r.startswith("moderate")]

    sell_overbought = [(v, i) for v, r, i in zip(sell_vecs, sell_regimes, sell_idx)
                       if r.startswith("overbought")]
    sell_moderate = [(v, i) for v, r, i in zip(sell_vecs, sell_regimes, sell_idx)
                     if r.startswith("moderate")]

    log(f"  BUY clusters: oversold={len(buy_oversold)}, moderate={len(buy_moderate)}")
    log(f"  SELL clusters: overbought={len(sell_overbought)}, moderate={len(sell_moderate)}")

    # Train cluster-specific subspaces
    clusters = {}
    for name, data in [
        ("BUY_oversold", buy_oversold),
        ("BUY_moderate", buy_moderate),
        ("SELL_overbought", sell_overbought),
        ("SELL_moderate", sell_moderate),
    ]:
        if len(data) < 20:
            log(f"  Skipping {name} — only {len(data)} samples")
            continue
        ss = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
        n_t = min(len(data) // 2, n_train)
        for v, _ in data[:n_t]:
            ss.update(v)
        clusters[name] = {"subspace": ss, "train_n": n_t, "test_data": data[n_t:]}
        log(f"  {name}: trained on {n_t}")

    # Test: for each test window, compute residual against all clusters + HOLD
    correct_clust = 0
    total_clust = 0

    for true_label, test_set in [("BUY", test_buy), ("SELL", test_sell), ("HOLD", test_hold)]:
        for v in test_set:
            rh = ss_h.residual(v)
            best_buy_r = float("inf")
            best_sell_r = float("inf")

            for name, info in clusters.items():
                r = info["subspace"].residual(v)
                if name.startswith("BUY"):
                    best_buy_r = min(best_buy_r, r)
                elif name.startswith("SELL"):
                    best_sell_r = min(best_sell_r, r)

            best = min(best_buy_r, best_sell_r, rh)
            if best == best_buy_r:
                predicted = "BUY"
            elif best == best_sell_r:
                predicted = "SELL"
            else:
                predicted = "HOLD"

            if predicted == true_label:
                correct_clust += 1
            total_clust += 1

    clust_acc = correct_clust / total_clust * 100
    log(f"  CLUSTERED accuracy: {clust_acc:.0f}%")

    for true_label, test_set in [("BUY", test_buy), ("SELL", test_sell), ("HOLD", test_hold)]:
        correct = 0
        for v in test_set:
            rh = ss_h.residual(v)
            best_buy_r = min(
                (clusters[n]["subspace"].residual(v) for n in clusters if n.startswith("BUY")),
                default=float("inf"))
            best_sell_r = min(
                (clusters[n]["subspace"].residual(v) for n in clusters if n.startswith("SELL")),
                default=float("inf"))
            best = min(best_buy_r, best_sell_r, rh)
            pred = "BUY" if best == best_buy_r else ("SELL" if best == best_sell_r else "HOLD")
            if pred == true_label:
                correct += 1
        log(f"    {true_label}: {correct}/{len(test_set)} ({correct/len(test_set)*100:.0f}%)")

    # ===================================================================
    # EXPERIMENT C: PROTOTYPE SCORING (no subspace)
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXPERIMENT C: PROTOTYPE SCORING — algebraic, no subspace")
    log("  Score = mean cosine(window, class_proto - hold_proto) per stripe")
    log("=" * 70)

    buy_protos = []
    sell_protos = []
    hold_protos = []
    for s in range(N_STRIPES):
        bp = prototype([v[s] for v in buy_vecs[:n_train]])
        sp = prototype([v[s] for v in sell_vecs[:n_train]])
        hp = prototype([v[s] for v in hold_vecs[:n_train]])
        buy_protos.append(bp)
        sell_protos.append(sp)
        hold_protos.append(hp)

    buy_signal = [negate(buy_protos[s], hold_protos[s]) for s in range(N_STRIPES)]
    sell_signal = [negate(sell_protos[s], hold_protos[s]) for s in range(N_STRIPES)]

    correct_proto = 0
    total_proto = 0
    proto_details = {"BUY": [], "SELL": [], "HOLD": []}

    for true_label, test_set in [("BUY", test_buy), ("SELL", test_sell), ("HOLD", test_hold)]:
        for v in test_set:
            buy_score = np.mean([cos(v[s], buy_signal[s]) for s in range(N_STRIPES)])
            sell_score = np.mean([cos(v[s], sell_signal[s]) for s in range(N_STRIPES)])

            if buy_score > sell_score and buy_score > 0.05:
                predicted = "BUY"
            elif sell_score > buy_score and sell_score > 0.05:
                predicted = "SELL"
            else:
                predicted = "HOLD"

            if predicted == true_label:
                correct_proto += 1
            total_proto += 1
            proto_details[true_label].append({
                "buy_score": buy_score, "sell_score": sell_score, "pred": predicted,
            })

    proto_acc = correct_proto / total_proto * 100
    log(f"  PROTOTYPE accuracy: {proto_acc:.0f}%")
    for label in ["BUY", "SELL", "HOLD"]:
        dets = proto_details[label]
        correct = sum(1 for d in dets if d["pred"] == label)
        avg_buy = np.mean([d["buy_score"] for d in dets])
        avg_sell = np.mean([d["sell_score"] for d in dets])
        log(f"    {label}: {correct}/{len(dets)} ({correct/len(dets)*100:.0f}%)  "
            f"avg_buy_score={avg_buy:.4f}  avg_sell_score={avg_sell:.4f}")

    # ===================================================================
    # EXPERIMENT D: HYBRID — prototype pre-filter + subspace residual
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXPERIMENT D: HYBRID — prototype filter → subspace residual")
    log("  Only act when prototype score > threshold, then use residual for sizing")
    log("=" * 70)

    thresholds = [0.03, 0.05, 0.07, 0.10, 0.15, 0.20]
    for thresh in thresholds:
        correct = 0
        total = 0
        acted = 0
        for true_label, test_set in [("BUY", test_buy), ("SELL", test_sell), ("HOLD", test_hold)]:
            for v in test_set:
                buy_score = np.mean([cos(v[s], buy_signal[s]) for s in range(N_STRIPES)])
                sell_score = np.mean([cos(v[s], sell_signal[s]) for s in range(N_STRIPES)])
                max_score = max(buy_score, sell_score)

                if max_score < thresh:
                    predicted = "HOLD"
                else:
                    rb = ss_b.residual(v)
                    rs = ss_s.residual(v)
                    rh = ss_h.residual(v)
                    if buy_score > sell_score and rb < rh:
                        predicted = "BUY"
                    elif sell_score > buy_score and rs < rh:
                        predicted = "SELL"
                    else:
                        predicted = "HOLD"

                if predicted != "HOLD":
                    acted += 1
                if predicted == true_label:
                    correct += 1
                total += 1

        acc = correct / total * 100
        buy_recall = sum(1 for d in proto_details["BUY"]
                        if max(d["buy_score"], d["sell_score"]) >= thresh) / len(test_buy) * 100
        log(f"  threshold={thresh:.2f}: acc={acc:.0f}%  acted={acted}/{total}  "
            f"buy_recall≈{buy_recall:.0f}%")

    # ===================================================================
    # EXPERIMENT E: CLUSTERED + PROTOTYPE PRE-FILTER
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXPERIMENT E: CLUSTERED + PROTOTYPE — best of both worlds")
    log("=" * 70)

    for thresh in [0.05, 0.10]:
        correct = 0
        total = 0
        acted = 0
        tp_buy = 0
        fp_buy = 0
        tp_sell = 0
        fp_sell = 0

        for true_label, test_set in [("BUY", test_buy), ("SELL", test_sell), ("HOLD", test_hold)]:
            for v in test_set:
                buy_score = np.mean([cos(v[s], buy_signal[s]) for s in range(N_STRIPES)])
                sell_score = np.mean([cos(v[s], sell_signal[s]) for s in range(N_STRIPES)])
                max_score = max(buy_score, sell_score)

                if max_score < thresh:
                    predicted = "HOLD"
                else:
                    rh = ss_h.residual(v)
                    best_buy_r = min(
                        (clusters[n]["subspace"].residual(v)
                         for n in clusters if n.startswith("BUY")),
                        default=float("inf"))
                    best_sell_r = min(
                        (clusters[n]["subspace"].residual(v)
                         for n in clusters if n.startswith("SELL")),
                        default=float("inf"))

                    if buy_score > sell_score and best_buy_r < rh:
                        predicted = "BUY"
                    elif sell_score > buy_score and best_sell_r < rh:
                        predicted = "SELL"
                    else:
                        predicted = "HOLD"

                if predicted != "HOLD":
                    acted += 1
                if predicted == "BUY":
                    if true_label == "BUY":
                        tp_buy += 1
                    else:
                        fp_buy += 1
                if predicted == "SELL":
                    if true_label == "SELL":
                        tp_sell += 1
                    else:
                        fp_sell += 1
                if predicted == true_label:
                    correct += 1
                total += 1

        acc = correct / total * 100
        precision_buy = tp_buy / (tp_buy + fp_buy) * 100 if (tp_buy + fp_buy) > 0 else 0
        precision_sell = tp_sell / (tp_sell + fp_sell) * 100 if (tp_sell + fp_sell) > 0 else 0
        log(f"  threshold={thresh:.2f}: acc={acc:.0f}%  acted={acted}/{total}  "
            f"BUY precision={precision_buy:.0f}%  SELL precision={precision_sell:.0f}%")

    # ===================================================================
    # EXPERIMENT F: PURE PROTOTYPE SCORING — what precision/recall?
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXPERIMENT F: PROTOTYPE ONLY — precision/recall sweep")
    log("  At different thresholds, what's the quality of signals?")
    log("=" * 70)

    for thresh in [0.05, 0.08, 0.10, 0.12, 0.15, 0.18, 0.20, 0.25]:
        tp_b, fp_b, fn_b = 0, 0, 0
        tp_s, fp_s, fn_s = 0, 0, 0

        for true_label, test_set in [("BUY", test_buy), ("SELL", test_sell), ("HOLD", test_hold)]:
            for v in test_set:
                buy_score = np.mean([cos(v[s], buy_signal[s]) for s in range(N_STRIPES)])
                sell_score = np.mean([cos(v[s], sell_signal[s]) for s in range(N_STRIPES)])

                if buy_score > sell_score and buy_score > thresh:
                    if true_label == "BUY":
                        tp_b += 1
                    else:
                        fp_b += 1
                elif sell_score > buy_score and sell_score > thresh:
                    if true_label == "SELL":
                        tp_s += 1
                    else:
                        fp_s += 1
                else:
                    if true_label == "BUY":
                        fn_b += 1
                    elif true_label == "SELL":
                        fn_s += 1

        prec_b = tp_b / (tp_b + fp_b) * 100 if (tp_b + fp_b) > 0 else 0
        recall_b = tp_b / (tp_b + fn_b) * 100 if (tp_b + fn_b) > 0 else 0
        prec_s = tp_s / (tp_s + fp_s) * 100 if (tp_s + fp_s) > 0 else 0
        recall_s = tp_s / (tp_s + fn_s) * 100 if (tp_s + fn_s) > 0 else 0
        log(f"  thresh={thresh:.2f}: BUY prec={prec_b:.0f}% recall={recall_b:.0f}%  |  "
            f"SELL prec={prec_s:.0f}% recall={recall_s:.0f}%")


if __name__ == "__main__":
    main()
