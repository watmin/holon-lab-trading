"""Adaptive Monitor v2 — Striped Subspace Classifier.

Architecture (informed by algebraic-intelligence.dev findings):
  Encoding:    16-stripe × 1024D via encode_walkable_striped (flat FQDN hashing)
               816 leaf bindings → ~51/stripe → capacity ratio ~20:1
               3x faster than hierarchical encode_data()

  Classifier:  BUY and SELL StripedSubspaces learn class manifolds via CCIPCA.
               Classification = which subspace has lower RSS residual.
               Residual profile (16-dim) adds dual-signal direction.

  Key insight: K (deflation steps) dominates DIM for rank-1 per-stripe data.
               DIM=1024, K=20, STRIPES=16 is the sweet spot.

Protocol:
  SUPERVISED (2019-2020): Train BUY/SELL subspaces from oracle labels.
  ADAPTIVE   (2021-2025): Blind — predict, wait 3h, learn from realized prices.
                           Oracle labels only for grading.

Strategies:
  Static:  RSS comparison, no updates after warm-up.
  A:       RSS comparison, always update appropriate subspace.
  B:       RSS comparison, only update on correct predictions.
  C:       RSS comparison, high amnesia (4.0) for regime tracking.
  D:       Dual-signal: RSS + profile direction via profile subspaces.
  E:       Regime-aware: dynamic amnesia based on coherence.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/adaptive_monitor.py
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/adaptive_monitor.py \\
        --window 48 --dims 1024 --stripes 16 --k 20 --workers 14
"""

from __future__ import annotations

import argparse
import multiprocessing as mp
import sqlite3
import sys
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

from holon import (
    DeterministicVectorManager,
    Encoder,
    LinearScale,
    OnlineSubspace,
    StripedSubspace,
    coherence,
)

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"

SUPERVISED_YEARS = {2019, 2020}
RESOLUTION_CANDLES = 36
MIN_MOVE_PCT = 1.0

OHLCV = ["open", "high", "low", "close", "volume"]
PRICE_CORE = ["open", "high", "low", "close", "sma20", "sma50", "sma200"]
PRICE_BB = ["bb_upper", "bb_lower"]
VOLUME = ["volume"]
RSI = ["rsi"]
MACD = ["macd_line", "macd_signal", "macd_hist"]
DMI = ["dmi_plus", "dmi_minus", "adx"]
ALL_FEATURES = PRICE_CORE + PRICE_BB + VOLUME + RSI + MACD + DMI

_g_ohlcv_only = False

SCALE = 0.01


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def sf(v):
    return 0.0 if v is None else float(v)


# =========================================================================
# Monitor normalization (same as v1)
# =========================================================================

def normalize_window(candles, idx, window_size):
    start = max(0, idx - window_size + 1)
    window = candles[start:idx + 1]
    if len(window) < window_size:
        window = [window[0]] * (window_size - len(window)) + list(window)

    price_feats = ["open", "high", "low", "close"]
    if not _g_ohlcv_only:
        price_feats = PRICE_CORE

    viewport_vals = []
    for c in window:
        for feat in price_feats:
            v = sf(c.get(feat))
            if v > 0:
                viewport_vals.append(v)

    vp_lo = min(viewport_vals) if viewport_vals else 0.0
    vp_hi = max(viewport_vals) if viewport_vals else 1.0
    vp_range = vp_hi - vp_lo if vp_hi - vp_lo > 1e-10 else 1.0
    margin = vp_range * 0.05
    vp_lo -= margin
    vp_hi += margin
    vp_range = vp_hi - vp_lo

    vol_vals = [sf(c.get("volume")) for c in window]
    v_lo, v_hi = min(vol_vals), max(vol_vals)
    v_range = v_hi - v_lo if v_hi - v_lo > 1e-10 else 1.0

    clamp = lambda v: max(0.0, min(1.0, v))

    if _g_ohlcv_only:
        normalized = []
        for c in window:
            entry = {
                "open": clamp((sf(c.get("open")) - vp_lo) / vp_range),
                "high": clamp((sf(c.get("high")) - vp_lo) / vp_range),
                "low": clamp((sf(c.get("low")) - vp_lo) / vp_range),
                "close": clamp((sf(c.get("close")) - vp_lo) / vp_range),
                "volume": clamp((sf(c.get("volume")) - v_lo) / v_range),
            }
            normalized.append(entry)
        return normalized

    macd_all = [sf(c.get(f)) for c in window for f in MACD]
    m_lo, m_hi = min(macd_all), max(macd_all)
    m_range = m_hi - m_lo if m_hi - m_lo > 1e-10 else 1.0

    normalized = []
    for c in window:
        entry = {}
        for feat in PRICE_CORE + PRICE_BB:
            entry[feat] = clamp((sf(c.get(feat)) - vp_lo) / vp_range)
        entry["volume"] = clamp((sf(c.get("volume")) - v_lo) / v_range)
        entry["rsi"] = clamp(sf(c.get("rsi")) / 100.0)
        for feat in MACD:
            entry[feat] = clamp((sf(c.get(feat)) - m_lo) / m_range)
        for feat in DMI:
            entry[feat] = clamp(sf(c.get(feat)) / 100.0)
        normalized.append(entry)

    return normalized


def build_holon_data(candles, idx, window_size):
    normalized = normalize_window(candles, idx, window_size)
    data = {}
    for t, entry in enumerate(normalized):
        if _g_ohlcv_only:
            data[f"t{t}"] = {
                "open": LinearScale(entry["open"], scale=SCALE),
                "high": LinearScale(entry["high"], scale=SCALE),
                "low": LinearScale(entry["low"], scale=SCALE),
                "close": LinearScale(entry["close"], scale=SCALE),
                "volume": LinearScale(entry["volume"], scale=SCALE),
            }
        else:
            data[f"t{t}"] = {
                "price": {
                    "open": LinearScale(entry["open"], scale=SCALE),
                    "high": LinearScale(entry["high"], scale=SCALE),
                    "low": LinearScale(entry["low"], scale=SCALE),
                    "close": LinearScale(entry["close"], scale=SCALE),
                    "sma20": LinearScale(entry["sma20"], scale=SCALE),
                    "sma50": LinearScale(entry["sma50"], scale=SCALE),
                    "sma200": LinearScale(entry["sma200"], scale=SCALE),
                    "bb_upper": LinearScale(entry["bb_upper"], scale=SCALE),
                    "bb_lower": LinearScale(entry["bb_lower"], scale=SCALE),
                },
                "volume": LinearScale(entry["volume"], scale=SCALE),
                "rsi": LinearScale(entry["rsi"], scale=SCALE),
                "macd": {
                    "line": LinearScale(entry["macd_line"], scale=SCALE),
                    "signal": LinearScale(entry["macd_signal"], scale=SCALE),
                    "hist": LinearScale(entry["macd_hist"], scale=SCALE),
                },
                "dmi": {
                    "plus": LinearScale(entry["dmi_plus"], scale=SCALE),
                    "minus": LinearScale(entry["dmi_minus"], scale=SCALE),
                    "adx": LinearScale(entry["adx"], scale=SCALE),
                },
            }
    return data


# =========================================================================
# Parallel encoding — module-level globals for fork COW
# =========================================================================

_g_candles = None
_g_window = None
_g_dim = None
_g_stripes = None
_g_encoder = None


def _worker_init():
    global _g_encoder
    _g_encoder = Encoder(DeterministicVectorManager(dimensions=_g_dim))


def _worker_encode(idx):
    data = build_holon_data(_g_candles, idx, _g_window)
    stripe_list = _g_encoder.encode_walkable_striped(data, _g_stripes)
    return idx, np.stack(stripe_list)


# =========================================================================
# Compute actual from realized prices
# =========================================================================

def compute_actual(candles, queue_idx):
    entry_price = sf(candles[queue_idx].get("close"))
    if entry_price <= 0:
        return "QUIET"

    target_up = entry_price * (1 + MIN_MOVE_PCT / 100)
    target_down = entry_price * (1 - MIN_MOVE_PCT / 100)

    first_buy = first_sell = -1
    end = min(queue_idx + 1 + RESOLUTION_CANDLES, len(candles))

    for j in range(queue_idx + 1, end):
        close_j = sf(candles[j].get("close"))
        if first_buy < 0 and close_j >= target_up:
            first_buy = j
        if first_sell < 0 and close_j <= target_down:
            first_sell = j
        if first_buy >= 0 and first_sell >= 0:
            break

    if first_buy >= 0 and (first_sell < 0 or first_buy <= first_sell):
        return "BUY"
    elif first_sell >= 0:
        return "SELL"
    return "QUIET"


# =========================================================================
# Pending trade
# =========================================================================

@dataclass
class PendingTrade:
    candle_idx: int
    year: int
    stripe_arr: np.ndarray  # shape (n_stripes, dim), int8
    predictions: dict = field(default_factory=dict)


# =========================================================================
# Strategy state
# =========================================================================

@dataclass
class StrategyState:
    name: str
    buy_sub: StripedSubspace
    sell_sub: StripedSubspace
    correct: int = 0
    total_pred: int = 0
    quiet_count: int = 0
    year_correct: dict = field(default_factory=dict)
    year_total: dict = field(default_factory=dict)
    rolling: deque = field(default_factory=lambda: deque(maxlen=500))
    extra: dict = field(default_factory=dict)

    def accuracy(self):
        return self.correct / self.total_pred * 100 if self.total_pred > 0 else 0.0

    def rolling_accuracy(self):
        return sum(self.rolling) / len(self.rolling) * 100 if self.rolling else 0.0

    def dir_accuracy(self):
        d = self.total_pred - self.quiet_count
        return self.correct / d * 100 if d > 0 else 0.0

    def record(self, correct, year, quiet=False):
        self.total_pred += 1
        if quiet:
            self.quiet_count += 1
        if correct:
            self.correct += 1
        self.rolling.append(1 if correct else 0)
        self.year_correct[year] = self.year_correct.get(year, 0) + (
            1 if correct else 0
        )
        self.year_total[year] = self.year_total.get(year, 0) + 1

    def predict(self, svecs: List[np.ndarray]) -> str:
        buy_rss = self.buy_sub.residual(svecs)
        sell_rss = self.sell_sub.residual(svecs)
        return "BUY" if buy_rss < sell_rss else "SELL"


# =========================================================================
# Strategy updates — vary in how/when subspaces are updated
# =========================================================================

def update_A(s, svecs, predicted, actual, correct):
    """Always update appropriate class subspace."""
    if actual == "QUIET":
        return
    (s.buy_sub if actual == "BUY" else s.sell_sub).update(svecs)


def update_B(s, svecs, predicted, actual, correct):
    """Only update when prediction was correct (reinforcement)."""
    if actual == "QUIET":
        return
    if correct:
        (s.buy_sub if actual == "BUY" else s.sell_sub).update(svecs)


def update_C(s, svecs, predicted, actual, correct):
    """High amnesia (4.0) — same logic as A, faster forgetting."""
    if actual == "QUIET":
        return
    (s.buy_sub if actual == "BUY" else s.sell_sub).update(svecs)


def update_D(s, svecs, predicted, actual, correct):
    """Dual-signal: update class subspace + profile subspace."""
    if actual == "QUIET":
        return
    (s.buy_sub if actual == "BUY" else s.sell_sub).update(svecs)
    buy_prof = s.buy_sub.residual_profile(svecs)
    sell_prof = s.sell_sub.residual_profile(svecs)
    diff = sell_prof - buy_prof
    if actual == "BUY":
        s.extra["buy_prof_sub"].update(diff)
    else:
        s.extra["sell_prof_sub"].update(diff)


def predict_D(s, svecs):
    """Dual-signal: RSS magnitude + profile direction."""
    buy_rss = s.buy_sub.residual(svecs)
    sell_rss = s.sell_sub.residual(svecs)
    rss_pred = "BUY" if buy_rss < sell_rss else "SELL"

    bp = s.extra.get("buy_prof_sub")
    sp = s.extra.get("sell_prof_sub")
    if bp and sp and bp.n >= 50 and sp.n >= 50:
        buy_prof = s.buy_sub.residual_profile(svecs)
        sell_prof = s.sell_sub.residual_profile(svecs)
        diff = sell_prof - buy_prof
        bp_res = bp.residual(diff)
        sp_res = sp.residual(diff)
        prof_pred = "BUY" if bp_res < sp_res else "SELL"
        if prof_pred != rss_pred:
            rss_gap = abs(sell_rss - buy_rss) / max(sell_rss + buy_rss, 1e-10)
            prof_gap = abs(sp_res - bp_res) / max(sp_res + bp_res, 1e-10)
            return prof_pred if prof_gap > rss_gap else rss_pred

    return rss_pred


def update_E(s, svecs, predicted, actual, correct):
    """Regime-aware: dynamic amnesia from profile coherence."""
    if "recent_profiles" not in s.extra:
        s.extra["recent_profiles"] = deque(maxlen=50)

    buy_prof = s.buy_sub.residual_profile(svecs)
    sell_prof = s.sell_sub.residual_profile(svecs)
    s.extra["recent_profiles"].append(sell_prof - buy_prof)

    if actual == "QUIET":
        return

    if len(s.extra["recent_profiles"]) >= 10:
        recent = list(s.extra["recent_profiles"])[-10:]
        coh = coherence(recent)
        for stripe_sub in s.buy_sub._stripes + s.sell_sub._stripes:
            if coh < 0.3:
                stripe_sub.amnesia = min(6.0, stripe_sub.amnesia * 1.05)
            elif coh > 0.7:
                stripe_sub.amnesia = max(1.5, stripe_sub.amnesia * 0.98)

    (s.buy_sub if actual == "BUY" else s.sell_sub).update(svecs)


STRATEGIES = {"A": update_A, "B": update_B, "C": update_C,
              "D": update_D, "E": update_E}
CUSTOM_PREDICT = {"D": predict_D}


# =========================================================================
# Main
# =========================================================================

def main():
    global _g_candles, _g_window, _g_dim, _g_stripes

    parser = argparse.ArgumentParser()
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    parser.add_argument("--window", type=int, default=48)
    parser.add_argument("--dims", type=int, default=1024)
    parser.add_argument("--stripes", type=int, default=16)
    parser.add_argument("--k", type=int, default=20)
    parser.add_argument("--workers", type=int, default=mp.cpu_count())
    parser.add_argument("--ohlcv-only", action="store_true",
                        help="Raw OHLCV only — no TA indicators")
    parser.add_argument("--save-cache", type=str, default=None,
                        help="Save encoded vectors to .npz file")
    parser.add_argument("--load-cache", type=str, default=None,
                        help="Load encoded vectors from .npz file (skip encoding)")
    args = parser.parse_args()

    global _g_ohlcv_only
    _g_ohlcv_only = args.ohlcv_only

    window_size = args.window
    dim = args.dims
    n_stripes = args.stripes
    k = args.k

    feat_list = OHLCV if args.ohlcv_only else ALL_FEATURES
    feat_label = "OHLCV only" if args.ohlcv_only else "OHLCV + TA"
    leaves = window_size * len(feat_list)
    per_stripe = leaves / n_stripes

    log("=" * 80)
    log("ADAPTIVE MONITOR v2 — Striped Subspace Classifier")
    log(f"  Features:     {feat_label} ({len(feat_list)} per candle)")
    log(f"  Encoding:     {n_stripes} stripes × {dim}D "
        f"(= {n_stripes * dim:,} total dims)")
    log(f"  Subspace:     K={k} deflation steps/stripe")
    log(f"  Window:       {window_size} candles ({window_size * 5 / 60:.0f}h)")
    log(f"  Leaf bindings: {leaves} total, ~{per_stripe:.0f}/stripe "
        f"(capacity ratio {dim / per_stripe:.0f}:1)")
    log(f"  Supervised:   {sorted(SUPERVISED_YEARS)} (oracle labels)")
    log(f"  Adaptive:     2021+ (blind, realized-price learning)")
    log(f"  Workers:      {args.workers}")
    log("=" * 80)

    # ------------------------------------------------------------------
    # Load data
    # ------------------------------------------------------------------
    conn = sqlite3.connect(str(DB_PATH))
    seen = set()
    cols = []
    needed = ["ts", "year", "close"] + feat_list + [args.label, "atr_r"]
    if not args.ohlcv_only:
        needed += PRICE_BB
    for c in needed:
        if c not in seen:
            cols.append(c)
            seen.add(c)

    all_rows = conn.execute(
        f"SELECT {', '.join(cols)} FROM candles ORDER BY ts"
    ).fetchall()
    conn.close()
    candles = [{cols[j]: r[j] for j in range(len(cols))} for r in all_rows]
    log(f"Loaded {len(candles):,} candles")

    _g_candles = candles
    _g_window = window_size
    _g_dim = dim
    _g_stripes = n_stripes

    # ------------------------------------------------------------------
    # Identify tradeable indices
    # ------------------------------------------------------------------
    supervised_indices = []
    adaptive_indices = []

    for i in range(window_size - 1, len(candles)):
        atr_r = candles[i].get("atr_r") or 0
        if atr_r <= args.vol_threshold:
            continue
        year = candles[i].get("year")
        if year in SUPERVISED_YEARS:
            supervised_indices.append(i)
        else:
            adaptive_indices.append(i)

    all_indices = supervised_indices + adaptive_indices
    log(f"Supervised: {len(supervised_indices):,} candles (2019-2020)")
    log(f"Adaptive:   {len(adaptive_indices):,} candles (2021+)")
    log(f"Total:      {len(all_indices):,} to encode")

    # ------------------------------------------------------------------
    # Phase 1: Parallel striped encode (or load from cache)
    # ------------------------------------------------------------------
    if args.load_cache:
        log(f"\n--- LOADING CACHE: {args.load_cache} ---")
        t_enc = time.time()
        cached = np.load(args.load_cache)
        cached_indices = cached["indices"]
        cached_vectors = cached["vectors"]
        vec_cache = {int(cached_indices[i]): cached_vectors[i]
                     for i in range(len(cached_indices))}
        enc_elapsed = time.time() - t_enc
        log(f"Loaded {len(vec_cache):,} cached vectors in {enc_elapsed:.1f}s")
        all_indices = [i for i in all_indices if i in vec_cache]
        supervised_indices = [i for i in supervised_indices if i in vec_cache]
        adaptive_indices = [i for i in adaptive_indices if i in vec_cache]
    else:
        log(f"\n--- ENCODING ({args.workers} workers, {n_stripes} stripes) ---")
        t_enc = time.time()

        with mp.Pool(args.workers, initializer=_worker_init) as pool:
            results = []
            done = 0
            for result in pool.imap_unordered(
                _worker_encode, all_indices, chunksize=50
            ):
                results.append(result)
                done += 1
                if done % 2000 == 0:
                    elapsed = time.time() - t_enc
                    rate = done / elapsed
                    remaining = len(all_indices) - done
                    log(f"  {done:,}/{len(all_indices):,} ({rate:.0f}/s) "
                        f"ETA {remaining / rate / 60:.1f}min")

        vec_cache = dict(results)
        enc_elapsed = time.time() - t_enc
        log(f"Encoding done: {len(vec_cache):,} striped vectors in {enc_elapsed:.1f}s "
            f"({len(vec_cache) / enc_elapsed:.0f}/s)")

        if args.save_cache:
            indices_arr = np.array(sorted(vec_cache.keys()), dtype=np.int32)
            vectors_arr = np.stack([vec_cache[i] for i in indices_arr])
            np.savez(args.save_cache, indices=indices_arr, vectors=vectors_arr)
            log(f"Saved cache: {args.save_cache} "
                f"({vectors_arr.nbytes / 1e6:.0f} MB)")

    def as_list(idx):
        """Convert stacked (n_stripes, dim) array to list for StripedSubspace."""
        return list(vec_cache[idx])

    # ------------------------------------------------------------------
    # Phase 2: Supervised warm-up (2019-2020)
    # ------------------------------------------------------------------
    log("\n--- SUPERVISED PHASE (2019-2020) ---")

    base_buy = StripedSubspace(dim=dim, k=k, n_stripes=n_stripes, amnesia=2.0)
    base_sell = StripedSubspace(dim=dim, k=k, n_stripes=n_stripes, amnesia=2.0)

    buy_count = sell_count = skip_count = 0
    t_warm = time.time()
    for i in supervised_indices:
        label = candles[i].get(args.label)
        svecs = as_list(i)
        if label == "BUY":
            base_buy.update(svecs)
            buy_count += 1
        elif label == "SELL":
            base_sell.update(svecs)
            sell_count += 1
        else:
            skip_count += 1
        if (buy_count + sell_count) % 10000 == 0:
            log(f"  Warm-up: {buy_count + sell_count:,} trained...")

    warmup_elapsed = time.time() - t_warm
    log(f"Trained: {buy_count:,} BUY + {sell_count:,} SELL "
        f"({skip_count:,} skipped) in {warmup_elapsed:.1f}s")
    log(f"BUY subspace:  n={base_buy.n}, threshold={base_buy.threshold:.2f}")
    log(f"SELL subspace: n={base_sell.n}, threshold={base_sell.threshold:.2f}")

    # In-sample accuracy check
    in_correct = in_total = 0
    for i in supervised_indices:
        label = candles[i].get(args.label)
        if label not in ("BUY", "SELL"):
            continue
        svecs = as_list(i)
        buy_rss = base_buy.residual(svecs)
        sell_rss = base_sell.residual(svecs)
        if ("BUY" if buy_rss < sell_rss else "SELL") == label:
            in_correct += 1
        in_total += 1
    log(f"In-sample accuracy: {in_correct}/{in_total} "
        f"= {in_correct / in_total * 100:.1f}%")

    # ------------------------------------------------------------------
    # Phase 3: Create strategy copies from base snapshot
    # ------------------------------------------------------------------
    buy_snap = base_buy.snapshot()
    sell_snap = base_sell.snapshot()

    strategies: dict[str, StrategyState] = {}

    for name in ("A", "B", "E"):
        strategies[name] = StrategyState(
            name=f"Strategy {name}",
            buy_sub=StripedSubspace.from_snapshot(buy_snap),
            sell_sub=StripedSubspace.from_snapshot(sell_snap),
        )

    # C: high amnesia — copy then adjust
    strategies["C"] = StrategyState(
        name="Strategy C",
        buy_sub=StripedSubspace.from_snapshot(buy_snap),
        sell_sub=StripedSubspace.from_snapshot(sell_snap),
    )
    for sub in strategies["C"].buy_sub._stripes + strategies["C"].sell_sub._stripes:
        sub.amnesia = 4.0

    # D: dual-signal — copy subspaces, then train profile subspaces
    strategies["D"] = StrategyState(
        name="Strategy D",
        buy_sub=StripedSubspace.from_snapshot(buy_snap),
        sell_sub=StripedSubspace.from_snapshot(sell_snap),
    )
    buy_prof_sub = OnlineSubspace(dim=n_stripes, k=1, amnesia=2.0)
    sell_prof_sub = OnlineSubspace(dim=n_stripes, k=1, amnesia=2.0)
    d_buy_sub = strategies["D"].buy_sub
    d_sell_sub = strategies["D"].sell_sub
    for i in supervised_indices:
        label = candles[i].get(args.label)
        if label not in ("BUY", "SELL"):
            continue
        svecs = as_list(i)
        diff = d_sell_sub.residual_profile(svecs) - d_buy_sub.residual_profile(svecs)
        if label == "BUY":
            buy_prof_sub.update(diff)
        else:
            sell_prof_sub.update(diff)
    strategies["D"].extra["buy_prof_sub"] = buy_prof_sub
    strategies["D"].extra["sell_prof_sub"] = sell_prof_sub
    log(f"D profile subspaces: BUY.n={buy_prof_sub.n}, SELL.n={sell_prof_sub.n}")

    static = StrategyState(
        name="Static",
        buy_sub=StripedSubspace.from_snapshot(buy_snap),
        sell_sub=StripedSubspace.from_snapshot(sell_snap),
    )

    log(f"Initialized {len(strategies)} strategies + static baseline")

    # ------------------------------------------------------------------
    # Phase 4: Adaptive walk-forward (2021+ blind)
    # ------------------------------------------------------------------
    log("\n--- ADAPTIVE PHASE (2021+ blind) ---")

    pending: list[PendingTrade] = []
    resolved_count = 0
    last_report = 0
    report_interval = 2000
    quiet_total = 0

    t0 = time.time()

    for i in adaptive_indices:
        year = candles[i].get("year")

        # --- Resolve pending trades ---
        still_pending = []
        for pt in pending:
            if i - pt.candle_idx >= RESOLUTION_CANDLES:
                actual = compute_actual(candles, pt.candle_idx)
                resolved_count += 1
                is_quiet = actual == "QUIET"
                if is_quiet:
                    quiet_total += 1

                svecs = list(pt.stripe_arr)
                for name, strat in strategies.items():
                    pred = pt.predictions[name]
                    is_correct = (pred == actual) and not is_quiet
                    strat.record(is_correct, pt.year, quiet=is_quiet)
                    STRATEGIES[name](strat, svecs, pred, actual, is_correct)

                static.record(
                    (pt.predictions["Static"] == actual) and not is_quiet,
                    pt.year, quiet=is_quiet,
                )
            else:
                still_pending.append(pt)
        pending = still_pending

        # --- Queue with predictions locked now ---
        svecs = as_list(i)
        preds = {}
        for name, strat in strategies.items():
            pfn = CUSTOM_PREDICT.get(name)
            preds[name] = pfn(strat, svecs) if pfn else strat.predict(svecs)
        preds["Static"] = static.predict(svecs)

        pending.append(PendingTrade(
            candle_idx=i, year=year, stripe_arr=vec_cache[i],
            predictions=preds,
        ))

        if resolved_count > 0 and resolved_count >= last_report + report_interval:
            last_report = resolved_count
            elapsed = time.time() - t0
            rate = resolved_count / elapsed
            log(f"\n  [{resolved_count:,} resolved | {quiet_total:,} quiet "
                f"| year {year} | {rate:.0f} trades/s]")
            log(f"  {'Strategy':<15s} {'Overall':>8s} {'DirAcc':>8s} {'Roll500':>8s}")
            log(f"  {'-' * 43}")
            for n in sorted(strategies.keys()):
                s = strategies[n]
                log(f"  {s.name:<15s} {s.accuracy():>7.1f}% "
                    f"{s.dir_accuracy():>7.1f}% {s.rolling_accuracy():>7.1f}%")
            log(f"  {'Static':<15s} {static.accuracy():>7.1f}% "
                f"{static.dir_accuracy():>7.1f}% {static.rolling_accuracy():>7.1f}%")

    # Resolve remaining
    for pt in pending:
        actual = compute_actual(candles, pt.candle_idx)
        resolved_count += 1
        is_quiet = actual == "QUIET"
        if is_quiet:
            quiet_total += 1
        for name, strat in strategies.items():
            pred = pt.predictions[name]
            strat.record(
                (pred == actual) and not is_quiet, pt.year, quiet=is_quiet
            )
        static.record(
            (pt.predictions["Static"] == actual) and not is_quiet,
            pt.year, quiet=is_quiet,
        )

    walk_elapsed = time.time() - t0

    # ------------------------------------------------------------------
    # FINAL RESULTS
    # ------------------------------------------------------------------
    log("")
    log("=" * 80)
    log(f"FINAL RESULTS — {resolved_count:,} trades ({quiet_total:,} quiet)")
    log(f"  Config:     {n_stripes}×{dim}D, K={k}, window={window_size}")
    log(f"  Supervised: {buy_count + sell_count:,} (2019-2020)")
    log(f"  Graded on:  {resolved_count:,} blind trades (2021+)")
    log(f"  In-sample:  {in_correct / in_total * 100:.1f}%")
    log("=" * 80)

    non_quiet = resolved_count - quiet_total
    log(f"\n  Non-quiet: {non_quiet:,}/{resolved_count:,} "
        f"({non_quiet / resolved_count * 100:.1f}%)")

    log(f"\n  {'Strategy':<15s} {'Overall':>8s} {'DirAcc':>8s} {'Roll500':>8s}")
    log(f"  {'-' * 43}")
    for n in sorted(strategies.keys()):
        s = strategies[n]
        log(f"  {s.name:<15s} {s.accuracy():>7.1f}% "
            f"{s.dir_accuracy():>7.1f}% {s.rolling_accuracy():>7.1f}%")
    log(f"  {'Static':<15s} {static.accuracy():>7.1f}% "
        f"{static.dir_accuracy():>7.1f}% {static.rolling_accuracy():>7.1f}%")

    # Per-year breakdown
    all_years = set()
    for s in list(strategies.values()) + [static]:
        all_years.update(s.year_total.keys())
    all_years = sorted(all_years)

    log(f"\n  {'Strategy':<15s}" + "".join(f" {y:>7d}" for y in all_years))
    log(f"  {'-' * (15 + 8 * len(all_years))}")
    for n in sorted(strategies.keys()):
        s = strategies[n]
        row = f"  {s.name:<15s}"
        for y in all_years:
            t = s.year_total.get(y, 0)
            c = s.year_correct.get(y, 0)
            row += f" {c / t * 100 if t else 0:>6.1f}%"
        log(row)
    row = f"  {'Static':<15s}"
    for y in all_years:
        t = static.year_total.get(y, 0)
        c = static.year_correct.get(y, 0)
        row += f" {c / t * 100 if t else 0:>6.1f}%"
    log(row)

    row = f"\n  {'Trades/year':<15s}"
    for y in all_years:
        row += f" {static.year_total.get(y, 0):>7,d}"
    log(row)

    # ------------------------------------------------------------------
    # DIAGNOSTICS
    # ------------------------------------------------------------------
    log(f"\n{'=' * 80}")
    log("DIAGNOSTICS")
    log("=" * 80)

    for n in sorted(strategies.keys()):
        s = strategies[n]
        log(f"  {s.name}: BUY.n={s.buy_sub.n:,} SELL.n={s.sell_sub.n:,} "
            f"BUY.thresh={s.buy_sub.threshold:.2f} "
            f"SELL.thresh={s.sell_sub.threshold:.2f}")
    log(f"  Static:      BUY.n={static.buy_sub.n:,} SELL.n={static.sell_sub.n:,}")

    d = strategies["D"]
    bp = d.extra.get("buy_prof_sub")
    sp = d.extra.get("sell_prof_sub")
    if bp and sp:
        log(f"  D profile:   BUY.n={bp.n} SELL.n={sp.n} "
            f"BUY.thresh={bp.threshold:.4f} SELL.thresh={sp.threshold:.4f}")

    e = strategies["E"]
    if e.buy_sub._stripes:
        amn = [sub.amnesia for sub in e.buy_sub._stripes + e.sell_sub._stripes]
        log(f"  E amnesia:   min={min(amn):.2f} max={max(amn):.2f} "
            f"mean={np.mean(amn):.2f}")

    log(f"\n  Encoding: {enc_elapsed:.1f}s | Warm-up: {warmup_elapsed:.1f}s | "
        f"Walk-forward: {walk_elapsed:.1f}s")
    log("DONE")


if __name__ == "__main__":
    main()
