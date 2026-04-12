# Proposal 026 — Exit Vocabulary

**Date:** 2026-04-11
**Author:** watmin + machine
**Status:** PROPOSED

## The diagnosis

The exit observer predicts distances — trail and stop — from a
composed vector. The composed vector is `(bundle market-thought
exit-thought)`. The exit has 16 atoms across three lenses:
volatility (6), structure (5), timing (5).

Two problems:

### 1. The composition is wrong

The exit reckoner queries on `(bundle market-thought exit-thought)`.
The market-thought is the market observer's noise-stripped anomaly —
a direction signal. "The market says Up" or "the market says Down."

The exit's question is: "how far should the trail be? how far
should the stop be?" The answer depends on volatility, regime,
structure, time. It does NOT depend on direction. "ATR is high
and Hurst says trending" → wide trail. Whether the trend is Up
or Down doesn't change the distance.

The direction signal is noise in the exit's input. Half the
composed vector is irrelevant to the exit's question. The
reckoner's K=10 buckets must accommodate direction variation
that carries no information about distances.

The fix: the exit reckoner queries on `exit-thought` only.

```scheme
;; Today:
(reckoner-distances exit-obs (bundle market-thought exit-thought))

;; Proposed:
(reckoner-distances exit-obs exit-thought)
```

### 2. The vocabulary is thin

The exit has 16 atoms. It thinks about the candle. It does not
think about the regime, the time, or its own performance.

**Missing: regime (6 atoms).** These exist on the market regime
lens. The exit doesn't use them.

```scheme
(Linear "hurst"          hurst)           ; trending vs mean-reverting
(Linear "choppiness"     choppiness)      ; orderly vs chaotic
(Linear "dfa-alpha"      dfa-alpha)       ; persistent vs anti-persistent
(Linear "entropy-rate"   entropy-rate)    ; predictable vs random
(Linear "fractal-dim"    fractal-dim)     ; complexity of the series
(Linear "variance-ratio" variance-ratio)  ; random walk departure
```

A trending market (Hurst > 0.5, high ADX, low choppiness) needs
wider trails — let the trend run. A choppy market (Hurst < 0.5,
low ADX, high choppiness) needs tighter stops — cut fast. The
exit can't see this. The regime atoms are the exit's missing
context for WHY distances should be wide or tight.

**Missing: time (2 atoms).** Hour and day-of-week exist in shared
time vocab. The exit doesn't use them.

```scheme
(Circular "hour"        hour 24)        ; Asian/European/US session
(Circular "day-of-week" day-of-week 7)  ; weekend vs weekday
```

Session liquidity differs dramatically. Asian session (UTC 0-8)
is thin. US session (UTC 14-21) is deep. Thin liquidity means
wider stops (more noise), tighter trails (less momentum). The
exit can't distinguish sessions.

Minute and month are noise for the exit's question. Minute
granularity is too fine — distances don't change within an hour.
Month is too coarse — the regime atoms already capture seasonal
character. Hour and day-of-week are the right resolution.

**Missing: self-assessment (2 atoms).** The exit's own recent
performance.

```scheme
(Linear "exit-grace-rate"    (/ grace-count total))  ; fraction Grace recently
(Linear "exit-avg-residue"   avg-residue)            ; average residue per paper
```

The designers have warned about self-assessment in prior reviews.
The concern: positive feedback loops. If grace-rate is high, the
exit trusts itself more, which might amplify errors. But the
self-assessment facts are now HONEST — both sides teach, the
simulation is the teacher, the numbers are real. The exit's
grace-rate IS a fact about the current regime's fit. High
grace-rate in a trending market is information: "my distances
work here." Low grace-rate in chop is information: "my distances
fail here." The discriminant can learn this.

### Summary of changes

```scheme
;; Today: 16 atoms, composed with market-thought
(define exit-input
  (bundle market-thought
    (bundle volatility-facts structure-facts timing-facts)))

;; Proposed: 26 atoms, exit-thought only
(define exit-input
  (bundle
    ;; Existing (16)
    volatility-facts    ; atr-ratio, atr-r, atr-roc-6, atr-roc-12, squeeze, bb-width
    structure-facts     ; trend-consistency-{6,12,24}, adx, exit-kama-er
    timing-facts        ; rsi, stoch-k, stoch-kd-spread, macd-hist, cci

    ;; New: regime (6)
    regime-facts        ; hurst, choppiness, dfa-alpha, entropy-rate,
                        ; fractal-dim, variance-ratio

    ;; New: time (2)
    time-facts          ; hour, day-of-week

    ;; New: self-assessment (2)
    self-facts))        ; exit-grace-rate, exit-avg-residue
```

The exit reckoner sees 26 atoms about the market state, the
time, and its own performance. It does NOT see the market
observer's direction prediction. The composition with market-thought
happens at the BROKER level — that's the broker's job.

## What changes

1. **Exit reckoner input:** `exit-thought` only, not composed.
2. **Exit vocab gains regime module:** 6 atoms from candle fields
   that already exist (computed by the indicator bank).
3. **Exit vocab gains time atoms:** hour + day-of-week from shared
   time vocab (already computed).
4. **Exit vocab gains self-assessment:** 2 atoms computed from the
   exit observer's own recent performance.
5. **Exit lenses updated:** each lens gains its subset of the new
   atoms. Generalist gets all 26.

## What doesn't change

- The broker's composed thought (still bundles market + exit).
- The broker's reckoner input (still the composed anomaly).
- The market observer vocabulary.
- The simulation functions.
- The paper mechanics.
- The cascade: reckoner → accumulator → default.

## Questions

1. Should the exit observer strip noise on its own input? It
   currently has no noise subspace. The market observer does.
   If the exit queries on exit-thought only, should it also
   learn a background distribution and predict on the anomaly?

2. The self-assessment atoms require the exit observer to track
   its own grace-rate and average residue. Currently it doesn't
   track outcomes — it just accumulates reckoner observations.
   Should these live on the exit observer struct or be passed
   in from the broker?

3. The composition change means the broker composes market +
   exit for ITS reckoner, but the exit reckoner sees only exit.
   Two different inputs for two different questions. Is this
   a separation or a complication?
