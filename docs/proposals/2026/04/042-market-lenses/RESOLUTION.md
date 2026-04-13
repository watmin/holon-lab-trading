# Resolution: Proposals 041 + 042 — Market Vocabulary + Lenses

**Decision: ALL of them. 11 market observers. 22 brokers. Measure.**

## The lenses

Three schools. Each school's groupings compete. The curve judges.

### Dow school (4 lenses)

```scheme
(lens :dow-trend
  (list close-sma20 close-sma50 close-sma200
        adx di-spread macd-hist
        hurst kama-er tf-agreement choppiness))

(lens :dow-volume
  (list volume-ratio obv-slope
        buying-pressure selling-pressure
        since-vol-spike squeeze))

(lens :dow-cycle
  (list rsi bb-width atr-ratio
        dist-from-high dist-from-low
        since-large-move tf-4h-trend tf-5m-1h-align))

(lens :dow-generalist
  (list all-24-dow-atoms))
```

### Pring school (4 lenses)

```scheme
(lens :pring-impulse
  (list roc-1 roc-6 roc-12
        macd-hist di-spread adx))

(lens :pring-confirmation
  (list obv-slope volume-ratio mfi
        rsi-divergence-bull rsi-divergence-bear
        rsi tf-agreement))

(lens :pring-regime
  (list kama-er hurst adx choppiness squeeze))

(lens :pring-generalist
  (list all-20-pring-atoms))
```

### Wyckoff school (3 lenses)

```scheme
(lens :wyckoff-effort
  (list volume-ratio obv-slope
        buying-pressure selling-pressure
        lower-wick upper-wick mfi
        body-ratio-pa since-vol-spike))

(lens :wyckoff-persistence
  (list adx hurst kama-er choppiness
        atr-ratio roc-6 roc-12 aroon-up))

(lens :wyckoff-position
  (list close-sma20 close-sma50 close-sma200
        dist-from-high dist-from-low
        aroon-up aroon-down
        rsi-divergence-bull rsi-divergence-bear
        range-pos-48))
```

## The grid

11 market × 2 exit = 22 brokers. Under the 24 we ran before.

## What changes

1. `types/enums.rs`: `MarketLens` gains 11 variants
2. `domain/config.rs`: `MARKET_LENSES` and `create_market_observers`
3. `domain/lens.rs`: `market_lens_facts` dispatches to 11 lenses
4. `bin/wat-vm.rs`: num_market = 11, grid = 22
5. Vocab modules: some may be trimmed (fibonacci, ichimoku, stochastic REMOVED)

## What doesn't change

- The pipeline. The exit observers. The brokers. The telemetry.
- The trade atoms (040). The journey grading (036, 037).
- The three primitives. The architecture just is.
