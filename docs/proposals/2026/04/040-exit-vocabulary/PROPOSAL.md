# Proposal 040 — Exit Trade Vocabulary

**Scope:** userland

**Depends on:** Proposals 038, 039

**Prior attempt:** Three designers proposed atoms independently.
The atoms were reasonable but naive — proposed without understanding
the machinery that consumes them. This revision shows the system.

## How the exit observer works

The exit observer receives a MarketChain from the market observer.
It EXTRACTS facts from the market's frozen superposition (cosine
tomography). It encodes its OWN facts. It bundles everything.
It encodes the bundle into a 10,000-dimensional vector. It strips
noise. The reckoner queries the anomaly and predicts a DISTANCE
(trail width) as a continuous value.

```scheme
(define (exit-observer-on-candle chain)
  (let* (;; Market facts arrive through the chain
         (market-facts (extract chain.market-anomaly
                         (collect-facts chain.market-ast)
                         encode-via-cache))

         ;; Exit's OWN facts — about the market (existing)
         (exit-market-facts (exit-lens-facts lens candle scales))

         ;; Exit's SELF facts — grace-rate, avg-residue (existing)
         (self-facts (exit-self-assessment-facts
                       grace-rate avg-residue scales))

         ;; Exit's TRADE facts — about the position (NEW — 040)
         (trade-facts (exit-trade-facts paper))

         ;; Bundle everything
         (all-facts (append exit-market-facts
                           self-facts
                           trade-facts
                           (absorbed market-facts)))

         ;; Encode → strip noise → query reckoner
         (thought (encode (Bundle all-facts)))
         (anomaly (strip-noise thought))
         (trail-width (query trail-reckoner anomaly))
         (stop-width  (query stop-reckoner anomaly)))

    (Distances trail-width stop-width)))
```

## What exists today (28 atoms — all market-facing)

The current exit vocabulary thinks about the CANDLE:

```scheme
;; Volatility lens (8 atoms):
(Linear "exit-atr-ratio" ...)
(Linear "exit-bb-width" ...)
(Linear "exit-bb-pos" ...)
(Linear "exit-kelt-pos" ...)
(Linear "exit-squeeze" ...)
(Linear "exit-atr-roc-6" ...)
(Linear "exit-atr-roc-12" ...)
(Linear "exit-range-ratio" ...)

;; Structure lens (6 atoms):
(Linear "exit-range-pos" ...)
(Linear "exit-trend-consistency" ...)
(Linear "exit-consecutive" ...)
(Linear "exit-sma20-dist" ...)
(Linear "exit-sma50-dist" ...)
(Linear "exit-gap" ...)

;; Timing lens (4 atoms):
(Linear "exit-stoch-k" ...)
(Linear "exit-rsi" ...)
(Linear "exit-williams-r" ...)
(Linear "exit-cci" ...)

;; Regime (8 atoms — all lenses get these):
(Linear "exit-hurst" ...)
(Linear "exit-kama-er" ...)
(Linear "exit-choppiness" ...)
(Linear "exit-entropy" ...)
(Linear "exit-dfa-alpha" ...)
(Linear "exit-aroon" ...)
(Linear "exit-fractal-dim" ...)
(Linear "exit-variance-ratio" ...)

;; Self-assessment (2 atoms):
(Linear "exit-grace-rate" ...)
(Log "exit-avg-residue" ...)
```

Zero atoms about the TRADE. All 28 think about the candle.

## What the paper knows

The trade state lives on the paper:

```scheme
(struct paper-entry
  paper-id          ;; unique id
  entry-price       ;; price at creation
  distances         ;; (trail stop) at entry
  extreme           ;; best price in predicted direction
  trail-level       ;; ratcheting floor
  stop-level        ;; fixed capital protection
  signaled          ;; has trail crossed?
  resolved          ;; is paper done?
  age               ;; candles alive
  price-history)    ;; every tick
```

From these fields, the exit observer can compute:

```scheme
;; Computable from paper state:
excursion           ;; (extreme - entry) / entry
retracement         ;; (extreme - current) / (extreme - entry)
trail-distance      ;; (extreme - trail-level) / extreme
stop-distance       ;; |entry - stop-level| / entry
age                 ;; candles since entry
signaled            ;; bool: has trail crossed?
price-velocity      ;; rate of change of price in the window
peak-age            ;; candles since the peak formed
```

## The question for designers

Given:
1. The existing 28 market-facing atoms (arrive through extraction)
2. The paper's trade state (computable at each candle)
3. The reckoner predicts trail WIDTH (continuous distance)
4. The journey grading teaches: error ratio against hindsight optimal
5. The self-assessment atoms (grace-rate, avg-residue)

**What TRADE-STATE atoms should the exit observer encode?**

Not what YOU think the exit should do (philosophy). What FACTS
about the trade should be NAMED so the reckoner can learn from
them? The reckoner discovers which facts predict good trail width.
We provide the vocabulary. The reckoner provides the judgment.

Express your atoms as ThoughtAST:
```scheme
(Linear "atom-name" value scale)
(Log "atom-name" value)
(Circular "atom-name" value period)
```

Each atom must be computable from the paper's fields listed above.
No market data — that comes through extraction.
