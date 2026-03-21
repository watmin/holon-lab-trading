"""Explore field-series encoding: transpose the data axis.

Instead of {t0: {rsi, macd, ...}, t1: {...}, ...}
encode as  {rsi: [t0, t1, ...], macd: [t0, t1, ...], ...}

Each field becomes a time series that Holon encodes as a list.
Tests List (composed leaf) vs Spread (fan-out) vs current flat.
Also tests different window sizes: 6, 12, 24, 48.
Also fixes TimeScale usage for time features.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/explore_field_series.py
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
from holon.kernel.encoder import Encoder, ListEncodeMode
from holon.kernel.walkable import LinearScale, TimeScale, WalkableSpread
from holon.memory import StripedSubspace

DIM = 1024
K = 4
N_STRIPES = 32


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
    log(f"  {len(df_ind):,} rows, {len(troughs_ind)} BUY, {len(peaks_ind)} SELL raw labels")
    return df_ind, troughs_ind, peaks_ind


def build_field_series_walkable(factory, df_ind, idx, window):
    """Build a field-series walkable: {field_name: [val_t0, ..., val_tN]}."""
    start = int(idx) - window + 1
    if start < 0 or int(idx) >= len(df_ind):
        return None

    # Collect raw candle dicts for the window
    candles = []
    for i in range(window):
        row_idx = start + i
        raw = factory.compute_candle_row(df_ind, row_idx)
        candles.append(raw)

    # Transpose: field → [val_t0, val_t1, ...]
    walkable = {
        "ohlcv_open_r":  [LinearScale(c["ohlcv"]["open_r"]) for c in candles],
        "ohlcv_high_r":  [LinearScale(c["ohlcv"]["high_r"]) for c in candles],
        "ohlcv_low_r":   [LinearScale(c["ohlcv"]["low_r"]) for c in candles],
        "vol_r":         [LinearScale(c["vol_r"]) for c in candles],
        "atr_r":         [LinearScale(c["atr_r"]) for c in candles],
        "rsi":           [LinearScale(c["rsi"]) for c in candles],
        "ret":           [LinearScale(c["ret"]) for c in candles],
        "sma_s20_r":     [LinearScale(c["sma"]["s20_r"]) for c in candles],
        "sma_s50_r":     [LinearScale(c["sma"]["s50_r"]) for c in candles],
        "sma_s200_r":    [LinearScale(c["sma"]["s200_r"]) for c in candles],
        "macd_line_r":   [LinearScale(c["macd"]["line_r"]) for c in candles],
        "macd_signal_r": [LinearScale(c["macd"]["signal_r"]) for c in candles],
        "macd_hist_r":   [LinearScale(c["macd"]["hist_r"]) for c in candles],
        "bb_width":      [LinearScale(c["bb"]["width"]) for c in candles],
        "dmi_plus":      [LinearScale(c["dmi"]["plus"]) for c in candles],
        "dmi_minus":     [LinearScale(c["dmi"]["minus"]) for c in candles],
        "adx":           [LinearScale(c["dmi"]["adx"]) for c in candles],
    }

    # Time feature from last candle
    ts_col = "ts" if "ts" in df_ind.columns else "timestamp"
    if ts_col in df_ind.columns:
        last_ts = pd.to_datetime(df_ind[ts_col].iloc[int(idx)])
        walkable["time"] = TimeScale(last_ts.timestamp())

    return walkable


def build_field_series_spread(factory, df_ind, idx, window):
    """Same as field_series but values are WalkableSpread (fan-out)."""
    start = int(idx) - window + 1
    if start < 0 or int(idx) >= len(df_ind):
        return None

    candles = []
    for i in range(window):
        row_idx = start + i
        raw = factory.compute_candle_row(df_ind, row_idx)
        candles.append(raw)

    walkable = {
        "ohlcv_open_r":  WalkableSpread([LinearScale(c["ohlcv"]["open_r"]) for c in candles]),
        "ohlcv_high_r":  WalkableSpread([LinearScale(c["ohlcv"]["high_r"]) for c in candles]),
        "ohlcv_low_r":   WalkableSpread([LinearScale(c["ohlcv"]["low_r"]) for c in candles]),
        "vol_r":         WalkableSpread([LinearScale(c["vol_r"]) for c in candles]),
        "atr_r":         WalkableSpread([LinearScale(c["atr_r"]) for c in candles]),
        "rsi":           WalkableSpread([LinearScale(c["rsi"]) for c in candles]),
        "ret":           WalkableSpread([LinearScale(c["ret"]) for c in candles]),
        "sma_s20_r":     WalkableSpread([LinearScale(c["sma"]["s20_r"]) for c in candles]),
        "sma_s50_r":     WalkableSpread([LinearScale(c["sma"]["s50_r"]) for c in candles]),
        "sma_s200_r":    WalkableSpread([LinearScale(c["sma"]["s200_r"]) for c in candles]),
        "macd_line_r":   WalkableSpread([LinearScale(c["macd"]["line_r"]) for c in candles]),
        "macd_signal_r": WalkableSpread([LinearScale(c["macd"]["signal_r"]) for c in candles]),
        "macd_hist_r":   WalkableSpread([LinearScale(c["macd"]["hist_r"]) for c in candles]),
        "bb_width":      WalkableSpread([LinearScale(c["bb"]["width"]) for c in candles]),
        "dmi_plus":      WalkableSpread([LinearScale(c["dmi"]["plus"]) for c in candles]),
        "dmi_minus":     WalkableSpread([LinearScale(c["dmi"]["minus"]) for c in candles]),
        "adx":           WalkableSpread([LinearScale(c["dmi"]["adx"]) for c in candles]),
    }

    ts_col = "ts" if "ts" in df_ind.columns else "timestamp"
    if ts_col in df_ind.columns:
        last_ts = pd.to_datetime(df_ind[ts_col].iloc[int(idx)])
        walkable["time"] = TimeScale(last_ts.timestamp())

    return walkable


def build_flat_walkable(factory, encoder, df_ind, idx, window):
    """Current flat tN-keyed encoding."""
    start = int(idx) - window + 1
    if start < 0 or int(idx) >= len(df_ind):
        return None
    w = df_ind.iloc[start:int(idx) + 1]
    if len(w) < window:
        return None

    walkable = {}
    for i in range(window):
        row_idx = len(w) - window + i
        candle_raw = factory.compute_candle_row(w, row_idx)
        walkable[f"t{i}"] = encoder._wrap_candle(candle_raw)

    ts_col = "ts" if "ts" in df_ind.columns else "timestamp"
    if ts_col in df_ind.columns:
        last_ts = pd.to_datetime(df_ind[ts_col].iloc[int(idx)])
        walkable["time"] = TimeScale(last_ts.timestamp())

    return walkable


def encode_windows(enc_func, indices, max_n=200):
    vecs = []
    for idx in indices[:max_n + 50]:
        try:
            v = enc_func(idx)
            if v is not None:
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
        log(f"  {name}: insufficient data (b={len(buy_vecs)} s={len(sell_vecs)} h={len(hold_vecs)})")
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

    for li, ts in [(0, test_b), (1, test_s), (2, test_h)]:
        for v in ts:
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
            "alignment": align}


def main():
    df_ind, troughs_ind, peaks_ind = load_data()
    factory = TechnicalFeatureFactory()
    rng = np.random.default_rng(42)

    for window in [6, 12, 24, 48]:
        # Filter indices that have enough lookback
        valid_buy = troughs_ind[troughs_ind >= window]
        valid_sell = peaks_ind[peaks_ind >= window]
        rev_set = set(valid_buy.tolist()) | set(valid_sell.tolist())
        hold_pool = [i for i in range(window + 1, len(df_ind)) if i not in rev_set]
        hold_sample = rng.choice(hold_pool, size=min(400, len(hold_pool)), replace=False)

        log(f"\n{'=' * 70}")
        log(f"WINDOW = {window} candles ({window * 5} minutes)")
        log(f"  {len(valid_buy)} BUY, {len(valid_sell)} SELL available")
        log(f"{'=' * 70}")

        # Leaf count per encoding
        leaves_flat = 17 * window + 1  # 17 fields × window + time
        leaves_spread = 17 * window + 1
        leaves_list = 17 + 1  # 17 composed leaves + time
        log(f"  Leaf bindings: flat={leaves_flat}  spread={leaves_spread}  list={leaves_list}")
        log(f"  Leaves/stripe: flat={leaves_flat/N_STRIPES:.1f}  "
            f"spread={leaves_spread/N_STRIPES:.1f}  list={leaves_list/N_STRIPES:.1f}")

        for list_mode in ["positional", "chained", "ngram"]:
            client = HolonClient(dimensions=DIM)
            client.encoder.default_list_mode = ListEncodeMode(list_mode)
            encoder = OHLCVEncoder(client, window_candles=window, n_stripes=N_STRIPES)

            # ----- FLAT (current approach, with TimeScale fix) -----
            if list_mode == "positional":
                log(f"\n  --- FLAT tN-keyed (window={window}) ---")

                def enc_flat(idx, _w=window, _f=factory, _e=encoder, _c=client):
                    w = build_flat_walkable(_f, _e, df_ind, idx, _w)
                    return _c.encoder.encode_walkable_striped(w, n_stripes=N_STRIPES) if w else None

                b = encode_windows(enc_flat, valid_buy, 200)
                s = encode_windows(enc_flat, valid_sell, 200)
                h = encode_windows(enc_flat, hold_sample, 200)
                log(f"    {len(b)} BUY, {len(s)} SELL, {len(h)} HOLD")
                measure(f"FLAT w={window}", b, s, h)

            # ----- FIELD-SERIES LIST -----
            log(f"\n  --- FIELD-SERIES LIST mode={list_mode} (window={window}) ---")

            def enc_list(idx, _w=window, _f=factory, _c=client):
                w = build_field_series_walkable(_f, df_ind, idx, _w)
                return _c.encoder.encode_walkable_striped(w, n_stripes=N_STRIPES) if w else None

            b = encode_windows(enc_list, valid_buy, 200)
            s = encode_windows(enc_list, valid_sell, 200)
            h = encode_windows(enc_list, hold_sample, 200)
            log(f"    {len(b)} BUY, {len(s)} SELL, {len(h)} HOLD")
            measure(f"LIST[{list_mode}] w={window}", b, s, h)

            # ----- FIELD-SERIES SPREAD -----
            if list_mode == "positional":
                log(f"\n  --- FIELD-SERIES SPREAD (window={window}) ---")

                def enc_spread(idx, _w=window, _f=factory, _c=client):
                    w = build_field_series_spread(_f, df_ind, idx, _w)
                    return _c.encoder.encode_walkable_striped(w, n_stripes=N_STRIPES) if w else None

                b = encode_windows(enc_spread, valid_buy, 200)
                s = encode_windows(enc_spread, valid_sell, 200)
                h = encode_windows(enc_spread, hold_sample, 200)
                log(f"    {len(b)} BUY, {len(s)} SELL, {len(h)} HOLD")
                measure(f"SPREAD w={window}", b, s, h)


if __name__ == "__main__":
    main()
