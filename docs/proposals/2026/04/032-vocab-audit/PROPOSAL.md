# Proposal 032 — Vocabulary Audit: The Idealized State

**Date:** 2026-04-12
**Author:** watmin + machine
**Status:** PROPOSED

## Context

Both designers reviewed every atom across all vocabulary modules
against the VSA primers. The findings converge on encoding bugs,
dead atoms, redundancies, and a duplication epidemic between
market and exit lenses.

The reviews are at:
- `docs/vocab-review-hickey.md`
- `docs/vocab-review-beckman.md`

This proposal describes the TARGET state — what the vocabulary
should look like after all fixes. Not a diff. A destination.

## Principles

1. **Every atom earns its place.** If two atoms are linearly
   dependent, one dies. If an atom is always constant, it dies.
   If an atom encodes nothing (gap on 24/7 BTC), it dies.

2. **Every encoding matches the quantity.** Log for multiplicative
   (ratios, rates, unbounded positive). Linear for bounded additive
   (normalized [0,1] or [-1,1]). Circular for periodic (hour,
   day-of-week). No exceptions.

3. **Every scale matches the range.** A Linear atom at scale=1.0
   uses 2π of the encoding. The natural range of the quantity must
   fit within one rotation. If BTC runs 30% from SMA200, scale=0.3
   not 0.1.

4. **No duplication across stages.** The exit-regime module is a
   copy of the market-regime module. When the broker composes
   them, eight atoms are doubled. Each stage encodes DISTINCT
   atoms. Shared concepts use the extraction — the exit READS
   the market's regime atoms, it doesn't re-encode them.

5. **Names speak.** `recalib-freshness` is staleness.
   `market-direction` is signed conviction. Names match what the
   value IS, not what we wish it meant.

## Market vocabulary — target state

### momentum.rs (6 atoms)

```scheme
(Linear "close-sma20"   (/ (- close sma20) close)  0.1)   ; OK
(Linear "close-sma50"   (/ (- close sma50) close)  0.15)  ; scale 0.1→0.15
(Linear "close-sma200"  (/ (- close sma200) close) 0.3)   ; scale 0.1→0.3
(Linear "macd-hist"     (/ macd-hist close)         0.01)  ; OK
(Linear "di-spread"     (/ (- di-plus di-minus) 100) 1.0)  ; OK
(Log    "atr-ratio"     (/ atr close))                      ; OK
```

**Changes:** close-sma50 scale to 0.15. close-sma200 scale to 0.3.

### regime.rs (8 atoms)

```scheme
(Linear "kama-er"        kama-er                    1.0)   ; OK [0,1]
(Linear "choppiness"     (/ choppiness 100)         1.0)   ; OK [0,1]
(Linear "dfa-alpha"      (- dfa-alpha 0.5)          0.5)   ; CENTERED at 0.5
(Linear "variance-ratio" (- variance-ratio 1.0)     1.0)   ; CENTERED at 1.0
(Linear "entropy-rate"   entropy-rate               1.0)   ; OK [0,1]
(Linear "aroon-up"       (/ aroon-up 100)           1.0)   ; OK [0,1]
(Linear "aroon-down"     (/ aroon-down 100)         1.0)   ; OK [0,1]
(Linear "fractal-dim"    (- fractal-dim 1.5)        0.5)   ; CENTERED at 1.5
```

**Changes:** dfa-alpha centered (- 0.5, scale 0.5). variance-ratio
centered (- 1.0). fractal-dim centered (- 1.5, scale 0.5).

### oscillators.rs (8 atoms)

```scheme
(Linear "rsi"       (/ rsi 100)                 1.0)   ; FIX: normalize
(Linear "cci"       (/ cci 300)                 1.0)   ; OK
(Linear "mfi"       (/ mfi 100)                 1.0)   ; OK
(Linear "williams-r" (/ (+ williams-r 100) 100) 1.0)   ; OK [-100,0]→[0,1]
(Log    "roc-1"     (max (abs roc-1) 0.001))            ; OK
(Log    "roc-3"     (max (abs roc-3) 0.001))            ; OK
(Log    "roc-6"     (max (abs roc-6) 0.001))            ; OK
(Log    "roc-12"    (max (abs roc-12) 0.001))           ; OK
```

**Changes:** rsi normalized by /100.

### flow.rs (4 atoms, was 6)

```scheme
(Log    "obv-slope"        (max (abs obv-slope) 0.001))  ; OK
(Log    "vwap-distance"    (max (abs vwap-distance) 0.001)) ; OK
(Linear "buying-pressure"  buying-pressure           1.0)  ; OK [0,1]
(Linear "body-ratio"       body-ratio                1.0)  ; OK [-1,1]
```

**Removed:** selling-pressure (= 1 - buying-pressure). volume-ratio
(redundant with buying-pressure).

### persistence.rs (3 atoms)

```scheme
(Linear "hurst"           hurst                     1.0)  ; OK [0,1]
(Linear "autocorrelation" autocorrelation            1.0)  ; OK [-1,1]
(Linear "adx"             (/ adx 100)               1.0)  ; OK [0,1]
```

No changes.

### price_action.rs (5 atoms, was 7)

```scheme
(Linear "range-ratio"     range-ratio               1.0)  ; OK
(Linear "consecutive-up"  (/ consecutive-up 10)      1.0)  ; OK
(Linear "consecutive-down" (/ consecutive-down 10)   1.0)  ; OK
(Linear "upper-wick"      upper-wick                1.0)  ; OK [0,1]
(Linear "lower-wick"      lower-wick                1.0)  ; OK [0,1]
```

**Removed:** gap (always zero on BTC). body-ratio-pa (identical
to body-ratio in flow.rs).

### ichimoku.rs (6 atoms)

No changes. All encoding types and scales are correct.

### keltner.rs (5 atoms, was 6)

```scheme
(Linear "bb-pos"           bb-pos                   1.0)  ; OK [-1,1]ish
(Log    "bb-width"         (max bb-width 0.001))          ; OK
(Linear "kelt-pos"         kelt-pos                 1.0)  ; OK
(Log    "squeeze"          (max squeeze 0.001))           ; FIX: Linear→Log
(Log    "kelt-upper-dist"  (max (abs kelt-upper-dist) 0.001)) ; OK
```

**Changes:** squeeze from Linear to Log (it's a ratio).
**Removed:** kelt-lower-dist (symmetric with kelt-upper-dist
relative to kelt-pos — redundant).

### stochastic.rs (3 atoms, was 4)

```scheme
(Linear "stoch-k"          (/ stoch-k 100)          1.0)  ; OK
(Linear "stoch-d"          (/ stoch-d 100)          1.0)  ; OK
(Linear "stoch-kd-spread"  (/ (- stoch-k stoch-d) 100) 1.0) ; OK
```

**Removed:** stoch-cross-delta (derivative of stoch-kd-spread —
linearly dependent on the spread).

### fibonacci.rs (3 atoms, was 8)

```scheme
(Linear "range-pos-12"  range-pos-12               1.0)  ; OK [0,1]
(Linear "range-pos-24"  range-pos-24               1.0)  ; OK [0,1]
(Linear "range-pos-48"  range-pos-48               1.0)  ; OK [0,1]
```

**Removed:** All five fib-dist-* atoms (constant shifts of
range-pos-48 — zero additional information).

### divergence.rs (3 atoms)

No changes. Conditional emission is correct.

### timeframe.rs (5 atoms, was 6)

```scheme
(Linear "tf-1h-trend"     tf-1h-trend               1.0)   ; OK [-1,1]
(Log    "tf-1h-ret"       (max (abs tf-1h-ret) 0.001))     ; OK
(Linear "tf-4h-trend"     tf-4h-trend               1.0)   ; OK [-1,1]
(Log    "tf-4h-ret"       (max (abs tf-4h-ret) 0.001))     ; OK
(Linear "tf-agreement"    tf-agreement               1.0)   ; OK [-1,1]
```

**Removed:** tf-5m-1h-align (wrong scale, noisy, redundant
with tf-agreement).

### standard.rs (7 atoms, was 8)

```scheme
(Log    "since-rsi-extreme" (max since-rsi-extreme 1))     ; OK
(Log    "since-vol-spike"   (max since-vol-spike 1))       ; OK
(Log    "since-large-move"  (max since-large-move 1))      ; OK
(Linear "dist-from-high"    dist-from-high           1.0)  ; OK [0,1]
(Linear "dist-from-low"     dist-from-low            1.0)  ; OK [0,1]
(Linear "dist-from-midpoint" dist-from-midpoint      1.0)  ; OK [-0.5,0.5]
(Log    "dist-from-sma200"  (max (abs dist-from-sma200) 0.001)) ; OK
```

**Removed:** session-depth (constant after warmup).

## Exit vocabulary — target state

### exit/volatility.rs (6 atoms)

No changes. All correct.

### exit/structure.rs (5 atoms)

No changes. All correct.

### exit/timing.rs (5 atoms)

```scheme
(Linear "rsi"              (/ rsi 100)              1.0)   ; FIX: normalize
(Linear "stoch-k"          (/ stoch-k 100)          1.0)   ; OK
(Linear "stoch-kd-spread"  (/ (- stoch-k stoch-d) 100) 1.0) ; OK
(Linear "macd-hist"        (/ macd-hist close)       0.01) ; OK
(Linear "cci"              (/ cci 300)               1.0)  ; OK
```

**Changes:** rsi normalized by /100.

### exit/regime.rs (8 atoms)

Same centering fixes as market/regime.rs: dfa-alpha, variance-ratio,
fractal-dim.

### exit/time.rs (2 atoms)

No changes.

### exit/self_assessment.rs (2 atoms)

No changes.

## Duplication resolution

The exit/regime module duplicates market/regime. When both are
in the broker's composed thought, 8 atoms are doubled.

The fix is NOT to remove exit/regime. The exit needs regime
awareness (Proposal 026 proved this). The fix is that the exit
EXTRACTS the market's regime atoms through the extraction
pipeline instead of re-encoding them from the candle. The
extracted atoms have m: prefix — different vectors, no doubling.

But today, the exit re-encodes from the candle. The extraction
adds ADDITIONAL atoms from the market anomaly. Both the
re-encoded and extracted versions exist. The broker sees both.

Target: the exit drops its re-encoded regime/timing atoms and
relies SOLELY on extraction from the market anomaly for shared
concepts. The exit's OWN vocab is only facts the market doesn't
encode — self-assessment, exit-specific structure thoughts.

This is a larger architectural change. Deferred. The immediate
fixes are the encoding bugs and dead atoms.

## Broker vocabulary — target state

### broker/opinions.rs (7 atoms)

```scheme
(Linear "market-signed-conviction" signed-conviction 1.0) ; RENAME
(Linear "market-conviction"        conviction         1.0) ; OK
(Linear "market-edge"              edge               1.0) ; OK
(Log    "exit-trail"               trail)                   ; OK
(Log    "exit-stop"                stop)                    ; OK
(Linear "exit-grace-rate"          grace-rate          1.0) ; OK
(Log    "exit-avg-residue"         avg-residue)             ; OK
```

**Changes:** market-direction → market-signed-conviction (honest name).

### broker/self_assessment.rs (7 atoms)

```scheme
(Linear "grace-rate"          grace-rate              1.0) ; OK
(Log    "paper-duration-avg"  paper-duration)               ; OK
(Log    "paper-count"         paper-count)                  ; OK
(Log    "trail-distance"      trail)                        ; OK
(Log    "stop-distance"       stop)                         ; OK
(Log    "recalib-staleness"   staleness)                    ; RENAME
(Log    "excursion-avg"       excursion)                    ; OK
```

**Changes:** recalib-freshness → recalib-staleness (honest name).

### broker/derived.rs (11 atoms)

No changes. Just implemented. Already reviewed.

## Summary

| Category | Before | After | Delta |
|----------|--------|-------|-------|
| Market atoms | ~90 | ~76 | -14 |
| Exit atoms | ~28 | ~28 | 0 |
| Broker atoms | ~25 | ~25 | 0 |
| Encoding bugs fixed | — | 5 | — |
| Dead atoms removed | — | 10 | — |
| Redundant atoms removed | — | 4 | — |
| Names corrected | — | 2 | — |

The vocabulary gets SMALLER and MORE HONEST. Fewer atoms, each
one earning its place, each one encoded correctly.
