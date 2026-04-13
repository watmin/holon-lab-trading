# Proposal 038 — The Hold Architecture

**Scope:** userland

## The current state

```scheme
(define (broker-on-resolution paper)
  (let ((residue (excursion paper))
        (fee (* 2 swap-fee)))
    (if (> residue fee)
      Grace
      Violence)))
```

The broker registers a paper every candle. The paper has tight
distances (0.17-0.33% trail). The paper resolves quickly. Grace
captures 0.21%. Violence loses 0.49%. After 0.70% round-trip
fees, every broker has negative expected value.

The machine scalps. The fees eat the residue.

## The problem

```scheme
(define the-move
  (list
    (buy  71200 candle-100)
    (buy  71400 candle-102)
    (buy  71300 candle-105)
    (buy  71800 candle-110)
    (hold ...)
    (hold ...)
    (hold ...)
    (sell 74800 candle-250)))

(define the-residue
  (- 74800 71200))            ;; 3600 points = 5%

(define the-cost
  (* 2 0.0035 71200))         ;; $498 round trip on $71200

(define the-net
  (- the-residue the-cost))   ;; $3102 = 4.3%
```

The move is 5%. The cost is 0.7%. The net is 4.3%. But the
current system captures 0.17% and pays 0.70%. The system sees
the move but trades it as 50 scalps instead of one hold.

## The proposed change

Three roles. Three questions. One architecture.

### The market observer: readiness

```scheme
(define (market-observer-thinks candle)
  (let ((thought (encode lens candle)))
    (predict reckoner thought)))

;; The prediction is not "act now."
;; The prediction is "something is forming."
;; Readiness is a thought, not a command.
;; High conviction at an extreme = the bottom is forming.
;; The market observer doesn't know what to DO.
;; It knows what it SEES.
```

### The exit observer: management

```scheme
(define (exit-observer-manages trade candle)
  (let ((excursion (current-excursion trade candle))
        (fee swap-fee)
        (hold-value (expected-future-residue trade candle)))

    (if (> (- excursion fee) hold-value)
      (exit trade)             ;; residue minus fee exceeds holding value
      (hold trade))))          ;; holding is worth more than exiting

;; The exit doesn't ask "did price drop 0.5%?"
;; The exit asks "is exiting now worth more than holding?"
;; The default is HOLD. The exception is EXIT.
;; A minor retracement is not a crisis.
;; A minor retracement is "deploy some more."
```

### The broker: the teacher

```scheme
(define (broker-enables market-readiness exit-management)

  ;; The broker doesn't trade. The broker teaches.
  ;; The broker PAIRS readiness with management.
  ;; The broker grades the PAIR, not the individuals.

  (when (ready? market-readiness)
    (deploy-paper exit-management))

  ;; Many papers at the bottom. Not one. Fifty.
  ;; Each one a hypothesis: "this readiness + this management
  ;; will produce residue that exceeds fees."

  ;; The paper lives. The exit manages it.
  ;; The paper resolves when the exit says "exiting now is
  ;; worth more than holding."

  ;; Grace: the residue exceeded the fee. The hold was right.
  ;; Violence: the stop fired. The hold was too long.

  ;; The broker teaches both:
  (teach market-observer
    "your readiness signal at THIS moment → Grace/Violence")
  (teach exit-observer
    "your management during THIS trade → Grace/Violence"))
```

### The treasury: deployment

```scheme
(define (treasury-deploys proposals)

  ;; The treasury doesn't fund one trade.
  ;; The treasury funds MANY trades.
  ;; Each from a different broker. Each at a different moment.
  ;; Some at the bottom. Some at higher lows.
  ;; The portfolio is the position.

  (for-each (lambda (proposal)
    (when (proven? (broker proposal))
      (let ((capital (available-capital)))
        (fund proposal (proportional-to-edge capital)))))
    proposals)

  ;; The treasury holds a PORTFOLIO of running positions.
  ;; Each position has its own trail. Its own stop. Its own
  ;; exit observer managing it.
  ;; The positions that accumulate residue → exit when
  ;; residue minus fee exceeds holding value.
  ;; The positions that fail → stop fires. Bounded loss.

  ;; Accumulation: deploy, recover principal, keep residue.
  ;; Both directions. Constant accumulation.
  ;; The treasury's job: maximize residue-after-fees over time.
  ;; Not per trade. Over time.
  )
```

## The algebraic question

The reckoners, the journals, the bundles — unchanged. The
algebra composes the same way. The LABELS change. The DISTANCES
change. The HOLDING PERIOD changes. But the primitives don't.

The exit reckoner currently predicts "what distance?" The
proposed exit reckoner predicts "hold or exit?" — a discrete
question, not continuous. Or: the continuous reckoner predicts
a WIDER distance that naturally holds longer.

The market reckoner currently predicts direction. It continues
to predict direction. Readiness IS direction prediction at
high conviction.

## The simplicity question

The current model: every candle, register a paper, resolve
quickly, learn from the resolution. Simple. Wrong.

The proposed model: register many papers at conviction extremes,
hold them, exit when residue justifies the fee. More complex.
But the complexity matches reality — the move IS 5%, the fee
IS 0.70%, holding IS the profitable strategy.

The simplification: the EXIT DEFAULT IS HOLD. The exit observer
doesn't need to decide every candle whether to stay. It needs to
decide whether to LEAVE. The absence of action IS the action.
The trailing stop protects against catastrophe. The exit observer
signals "now is worth leaving" — not "should I stay?"

## Questions for designers

1. Should the exit observer predict "hold or exit?" (discrete)
   or predict wider distances that naturally extend holding
   periods (continuous)?

2. Should papers be registered at every candle (current) or only
   when market readiness exceeds a threshold? Fewer papers =
   fewer fees = larger captures per paper.

3. The treasury currently doesn't exist. Should the treasury
   manage a portfolio of concurrent positions from different
   brokers, or should each broker manage its own positions
   independently?

4. The "expected future residue" — can the exit observer learn
   this, or is it a proxy (like ATR-based holding period)?

5. The higher lows — "deploy some more" — is this a separate
   readiness signal or the same market observer with sustained
   conviction?
