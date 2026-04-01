# Resolution: ACCEPTED — fold steps, not closures

Both designers conditional. The datamancer composes both.

Hickey: closures with set! are objects in disguise. State is data,
computation is pure function. The enterprise is a fold; indicators
should be folds too.

Beckman: the closure-as-coalgebra is sound, but five seams must close:
named bank, dual-source vocab, warmup partiality, history bridge,
ownership invariant.

They agree from different angles: make the state visible and the step pure.

## The decision

Each indicator is a pair: a **state struct** (a value) and a **pure step
function** `(state, input) → (state, output)`. No closures. No set!.
State is data, computation is function. They are separate.

```scheme
(struct wilder-state count accum prev)

(define (wilder-step period state value)
  (let ((count (+ (:count state) 1)))
    (if (<= count period)
        (let ((accum (+ (:accum state) value)))
          (list (wilder-state :count count :accum accum
                  :prev (if (= count period) (/ accum period) (:prev state)))
                (if (= count period) (/ accum period) (:prev state))))
        (let ((new (/ (+ (* (:prev state) (- period 1)) value) period)))
          (list (wilder-state :count count :accum (:accum state) :prev new)
                new)))))
```

Higher-order indicators compose via nested fold steps:

```scheme
(struct rsi-state gain-state loss-state prev-close started)

(define (rsi-step period state close)
  (if (not (:started state))
      (list (update state :started true :prev-close close) 50.0)
      (let* ((change (- close (:prev-close state)))
             (g (wilder-step period (:gain-state state) (max 0.0 change)))
             (l (wilder-step period (:loss-state state) (max 0.0 (- change)))))
        (list (update state
                :gain-state (first g) :loss-state (first l) :prev-close close)
              (- 100.0 (/ 100.0 (+ 1.0 (/ (second g) (max (second l) 1e-10)))))))))
```

## Five decisions from the designers

### 1. Indicator bank is a named struct of states

Product type with projections. Not a flat list.

```scheme
(struct indicator-bank
  sma20-state sma50-state sma200-state
  rsi-state atr-state macd-state
  ;; ... one state per indicator
  ;; Current + prev for cross-detection
  rsi-prev? rsi-current?
  stoch-k-prev? stoch-k-current?
  ;; ... prev/current pairs for all indicators vocab modules compare
  )
```

Optional fields (?) are absent during warmup. `when-let` propagates.

### 2. Vocab modules take dual source

```scheme
(define (eval-stochastic candles bank)
  "Raw candles for spatial patterns, bank for derived values."
  (when (and (some? (:stoch-k-current? bank))
             (some? (:stoch-k-prev? bank)))
    ...))
```

### 3. Warmup returns absent

Optional fields on the bank. `(:rsi-current? bank)` is absent until
the Wilder smoother has seen `period` candles. Vocab modules that
require the indicator return absent during warmup. The journal never
learns from garbage.

### 4. History bridge: prev + current

The bank stores two snapshots per indicator value. `tick-indicators`
shifts current → prev, new → current. Cross-detection modules
(stochastic crosses, MACD crosses) see both.

### 5. tick-indicators is a fold step

```scheme
(define (tick-indicators bank candle)
  "Step all indicators. Pure. Returns new bank."
  (let* ((close (:close candle))
         (sma20  (sma-step 20 (:sma20-state bank) close))
         (rsi    (rsi-step 14 (:rsi-state bank) close))
         ...)
    (update bank
      :sma20-state     (first sma20)
      :rsi-state       (first rsi)
      :rsi-prev?       (:rsi-current? bank)
      :rsi-current?    (second rsi)
      ...)))
```

A fold inside the fold. Same shape at every level. Inspectable,
serializable, checkpointable. No closures. No hidden state.

## Two kinds of perception

Hickey's naming: scalar stream processors vs spatial pattern recognizers.

**Scalar stream processors** — fold state + step function. O(1) memory
after warmup (except SMA/Bollinger which need O(period) ring buffers).
RSI, ATR, EMA, MACD, ADX, Stochastic.

**Spatial pattern recognizers** — raw candle window. O(window) memory.
Ichimoku, Fibonacci, PELT, divergence. These need multiple candles
simultaneously to detect geometric patterns.

The indicator bank handles the first. The per-observer candle window
handles the second. They compose as a bifunctor:

```
F : IndicatorBank × CandleWindow → Facts
```

## What this replaces

- `(field raw-candle name computation)` — gone
- 52-field Candle struct — becomes raw-candle + indicator-bank
- build-candles.wat — dissolved (streaming replaces batch)
- 17 phantom forms — dissolved (every computation is a real define)

## What this preserves

- Vocab modules return Fact data. The encoder weaves.
- Observers sample windows. Window-sampler unchanged.
- Enterprise fold shape: `(state, event) → state`
- Journal coalgebra: observe, predict, resolve, curve
- Per-observer candle windows (Hickey: no sharing)
