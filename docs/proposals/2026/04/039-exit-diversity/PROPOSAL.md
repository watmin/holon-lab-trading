# Proposal 039 — Exit Diversity

**Scope:** userland

**Depends on:** Proposal 038 (hold architecture)

## The current state

```scheme
(define EXIT-LENSES
  (list Volatility Timing Structure Generalist))
```

Four exit observers. Each with a different VOCABULARY subset
but the same MANAGEMENT philosophy — tight distances, fast
resolution, 0.17% residue. The lenses select which facts to
encode. They do not select how to manage the trade.

## The problem

```scheme
(define the-question
  "should I hold or leave?")

(define the-current-answer
  "leave — the distance is 0.17%")

(define the-missing-answers
  (list
    "hold — the trend is still producing higher lows"
    "hold — ATR says this retracement is noise"
    "leave — the swing measurement says we're at target"
    "hold — accumulate more, the base is still forming"))
```

The exit observers all think the same way. They differ in what
they see (vocabulary) but not in how they manage (philosophy).
A population of identical strategies cannot discover edge
through competition. The curve has nothing to select from.

## The proposed change

Exit lenses become MANAGEMENT SCHOOLS, not vocabulary subsets.
Each school thinks different thoughts about the trade. Each
school has its own atoms. Each school produces different
distances. Each school holds differently.

```scheme
(define EXIT-SCHOOLS
  (list

    (school :trend-follower
      (atoms
        (Linear "atr-trail-multiple"
          (/ trail-distance atr))
        (Linear "trend-age"
          (/ candles-since-entry 100.0))
        (Linear "breakout-distance"
          (/ (- peak entry) entry))
        (Linear "retracement-from-peak"
          (/ (- peak current) (- peak entry))))
      (philosophy
        "wide trail. let it run. exit when the trend breaks.
         the default is hold. the exception is a lower low
         that exceeds N × ATR from the peak."))

    (school :accumulator
      (atoms
        (Linear "higher-low-count"
          (/ higher-lows-since-entry 10.0))
        (Linear "retracement-ratio"
          (/ current-retracement max-excursion))
        (Linear "ratchet-progress"
          (/ (- floor entry) (- peak entry)))
        (Linear "retracement-acceleration"
          (/ retracement-speed prior-retracement-speed)))
      (philosophy
        "ratchet higher lows. hold through noise. a minor
         retracement is 'deploy more' not 'get out.' exit
         when a lower low breaks the ratchet floor."))

    (school :swing
      (atoms
        (Linear "swing-completion"
          (/ excursion measured-swing-target))
        (Linear "cycle-position"
          (/ candles-in-swing average-swing-duration))
        (Circular "time-in-trade"
          candles-since-entry max-expected-duration)
        (Linear "momentum-exhaustion"
          (/ current-momentum entry-momentum)))
      (philosophy
        "hold for the measured swing. exit at target or
         when momentum exhausts. time-aware — swings have
         expected durations."))

    (school :patient
      (atoms
        (Linear "residue-vs-fee"
          (/ (- excursion swap-fee) swap-fee))
        (Linear "hold-value-proxy"
          (* conviction atr-ratio))
        (Linear "time-decay"
          (/ 1.0 (+ 1.0 (/ candles-since-entry 500.0))))
        (Linear "fee-breakeven-ratio"
          (/ excursion (* 2.0 swap-fee))))
      (philosophy
        "the exit is expensive. hold until residue minus
         fee exceeds the expected future residue from
         holding. the fee-breakeven-ratio IS the gate.
         below 1.0 = hold. above 2.0 = consider exiting."))))
```

## The grid

```scheme
(define N 6)   ;; market observers (analysis)
(define M 4)   ;; exit observers (management)

;; 24 brokers. Each a (analysis, management) pair.
;; momentum × trend-follower
;; momentum × accumulator
;; momentum × swing
;; momentum × patient
;; structure × trend-follower
;; ... 24 combinations total.

;; Each broker grades its pair.
;; Each broker teaches both members.
;; The pairs that produce residue exceeding fees survive.
;; The pairs that don't starve.
;; Natural selection on (analysis × management) strategies.
```

## The algebraic question

The atoms are new. The algebra is unchanged. Each school's
atoms are Linear, Circular, Log — the same scalar encodings.
Each school's thought is a Bundle of its atoms — the same
composition. Each school's reckoner predicts distances — the
same continuous readout. The two templates. The six primitives.
Applied to new vocabulary. No new forms needed.

## The simplicity question

Four management schools is more complex than four vocabulary
subsets. But the current four subsets produce identical behavior.
Identical behavior cannot discover edge through competition.
The complexity matches the question: there IS more than one way
to manage a trade. The schools name those ways. The curve judges
which ways work.

The schools can grow. A fifth school. A sixth. Each is a new
exit observer with new atoms. The grid grows. The brokers
multiply. The selection pressure increases. But each school
is simple — a small set of atoms and a philosophy. The
complexity is in the POPULATION, not in any individual.

## Questions for designers

1. Should the schools completely replace the current exit lenses,
   or should the current lenses (vocabulary-based) continue
   alongside the new schools (philosophy-based)?

2. The atoms reference TRADE STATE (excursion, higher-low-count,
   candles-since-entry). The current architecture computes these
   from the paper's price history. Is the paper the right place
   for this state, or does it belong on the exit observer?

3. Each school has ~4 atoms. The market observers have ~20-100.
   Is 4 enough for the exit to learn from, or do the schools
   need richer vocabulary?

4. The "patient" school's fee-breakeven-ratio is a direct
   encoding of the fee. Should the fee be in the vocabulary
   (the exit thinks about it) or in the gate (the treasury
   decides)?

5. Can the market observer's atoms (RSI, ATR, regime) be
   SHARED with the exit schools through extraction (the
   existing pattern), or do the schools need their own
   market-awareness atoms?
