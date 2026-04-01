# Proposal 001: Streaming Indicator Closures

## Scope: userland

## Current state

candle.wat declares 52 derived fields via `(field raw-candle name computation)`.
The Candle struct has 52 pre-computed fields loaded from SQLite. The Python/Rust
build pipeline pre-computes all indicators for all 652k candles. The enterprise
loads them as a flat struct.

This works for backtesting. It does not work for:
- Live streaming (websocket feeds one candle at a time)
- Multi-asset (different assets need different indicator state)
- Memory (652k × 52 fields all in memory)

candle.wat has 17 phantom forms because the helper functions describe
streaming computations (`wilder-smooth`, `prev-ema`, `gains`, `losses`)
that can't be expressed as pure functions — they need state across candles.

## Problem

1. The `(field raw-candle name computation)` pattern is a lie. Fields aren't
   properties of a candle — they're computed from candle *history*. SMA(20)
   needs the last 20 closes. Wilder RSI needs smoothed state from every
   previous candle. These are stream processors, not field derivations.

2. build-candles.wat pre-computes everything. The streaming interface
   replaces it. Each indicator should compute incrementally.

3. The 52-field Candle struct couples every module to every indicator.
   An observer using only RSI and MACD still loads all 52 fields.

## Proposal

Replace `(field ...)` declarations with **indicator closures**. Each indicator
is a function that returns a closure. The closure maintains its own state.
Feed it one candle (or one value), get the indicator back.

```scheme
;; The raw input — only OHLCV
(struct raw-candle ts open high low close volume)

;; Each indicator is a closure factory
(define (make-sma period)
  (let ((buffer (deque)))
    (lambda (value)
      (push-back buffer value)
      (when (> (len buffer) period) (pop-front buffer))
      (/ (fold + 0.0 buffer) (len buffer)))))

(define (make-wilder period)
  (let ((count 0) (accum 0.0) (prev 0.0))
    (lambda (value)
      (inc! count)
      (if (<= count period)
          (begin (set! accum (+ accum value))
                 (when (= count period) (set! prev (/ accum period)))
                 (/ accum count))
          (let ((new (/ (+ (* prev (- period 1)) value) period)))
            (set! prev new)
            new)))))

(define (make-ema period)
  (let ((alpha (/ 2.0 (+ period 1))) (started false) (prev 0.0))
    (lambda (value)
      (if started
          (let ((new (+ (* alpha value) (* (- 1.0 alpha) prev))))
            (set! prev new) new)
          (begin (set! started true) (set! prev value) value)))))
```

### Memory model

Each closure manages its own depth:
- `make-sma 20` — deque of 20 values. O(period) memory.
- `make-wilder 14` — two floats (prev, accum). O(1) after warmup.
- `make-ema 26` — one float (prev). O(1).
- `make-rsi 14` — two wilder closures. O(1).
- `make-atr 14` — one wilder + prev-close. O(1).

No indicator accumulates indefinitely. Each tracks exactly what it needs.

### Composition: higher-order indicators

Indicators that depend on other indicators compose via closures:

```scheme
(define (make-rsi period)
  (let ((gain-smooth (make-wilder period))
        (loss-smooth (make-wilder period))
        (prev-close 0.0) (started false))
    (lambda (close)
      (if (not started)
          (begin (set! started true) (set! prev-close close) 50.0)
          (let ((change (- close prev-close)))
            (set! prev-close close)
            (- 100.0 (/ 100.0
              (+ 1.0 (/ (gain-smooth (max 0.0 change))
                        (max 1e-10 (loss-smooth (max 0.0 (- change)))))))))))))

(define (make-bollinger period num-stddev)
  (let ((sma-fn (make-sma period))
        (buffer (deque)))
    (lambda (close)
      (push-back buffer close)
      (when (> (len buffer) period) (pop-front buffer))
      (let ((mid (sma-fn close))
            (std (sqrt (/ (fold + 0.0
                            (map (lambda (x) (* (- x mid) (- x mid))) buffer))
                          (len buffer)))))
        (list mid (+ mid (* num-stddev std)) (- mid (* num-stddev std)))))))
```

### Two separate concerns

1. **Indicator state** — closures. O(1) per indicator. Each manages its own depth.
   Created at startup. Fed per-candle by the streaming interface.

2. **Candle window** — the raw OHLCV ring buffer for vocab modules.
   Vocab modules like `eval-ichimoku` need the last 26 raw candles.
   `eval-fibonacci` needs the full observer window for swing high/low.
   This is the enterprise's concern — one shared ring buffer, sliced per observer.

These must not be conflated. The indicator closures compute derived values
from raw OHLCV. The candle window stores raw OHLCV for vocab modules
that need spatial patterns (not just point-in-time indicators).

### What this replaces

- `(field raw-candle name computation)` — gone. Indicators are closures.
- 52-field Candle struct — replaced by raw-candle + indicator bank.
- build-candles.wat — dissolved. The closures ARE the build pipeline.
- 17 phantom forms in candle.wat — dissolved. Every computation is a real define.

### What this does NOT change

- Vocab modules still return Fact data. The encoder still weaves.
- Observers still sample windows. The window-sampler is unchanged.
- The enterprise fold shape is unchanged — `(state, event) → state`.
- The learning pipeline (journal, observe, predict, resolve, curve) is unchanged.

## Questions for designers

1. Should the indicator bank be a flat list of closures, or a struct with
   named fields? Flat list is simpler but loses type safety. Named struct
   preserves the "sma20 is sma20" identity.

2. Should the candle window (raw OHLCV ring buffer) be shared across
   observers, or should each observer maintain its own? Shared saves memory.
   Per-observer allows different retention policies.

3. The `set!` inside closures is mutation. Is this acceptable for a
   specification language? The closures are inherently stateful — they
   ARE state machines. The mutation is bounded and encapsulated.
