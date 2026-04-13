# Proposal 044 — Pivot Biography

**Scope:** userland

**Depends on:** Proposal 043 (broker survival), 040 (exit vocabulary)

## The thought

The market observers find pivot points. Moments in time where
conviction spikes — "something is happening here." Between
pivots, silence. The default is wait.

The pivot points are where the machine ACTS. Not every candle.
At the pivots. Enter or exit — same moment, same mechanism.
What determines the action is not the candle. It is the
HISTORY of prior actions at prior pivots.

A broker does not manage one trade. A broker manages a
PORTFOLIO of trades. A local dip produces 3 pivots — 3
entries from the same broker, each at a different price, each
with its own trail, each alive simultaneously. A peak comes —
the oldest 2 exit, the newest holds. A single broker can have
many active trades. One new entry per pivot, but many running
at once.

The constant activity: a dip is felt across many intervals.
Each interval is worth actioning. A peak is the same. The
broker enters at each pivot during the dip. Each entry is its
own position. Each position has its own biography — when it
was born, how many pivots it has survived, what the market
looked like when it entered. At the peak, each position is
evaluated independently. Some exit. Some hold. The exits
release residue. The holds ride the next move.

## The current state

The broker registers papers every candle. The exit observer
thinks about the current trade (10 atoms from Proposal 040)
and the current market (extracted from the market observer's
anomaly). Neither knows what happened at prior pivots. Neither
remembers the sequence of actions that led here.

The system is amnesiac about its own decisions. It sees this
candle. It sees this trade. It does not see the PATTERN of
its own behavior across time.

## The pivot point

A pivot is a candle where the market observer's conviction
exceeds a threshold — where the anomaly is strong enough that
the noise subspace says "this is noteworthy." The pivot is not
a signal to act. The pivot is a signal to EVALUATE.

At each pivot, each ACTIVE TRADE has its own context:

```scheme
;; Broker has 3 active trades. Same pivot. Each sees it differently.

;; Trade 1: entered 5 pivots ago at the start of the dip.
(trade-biography trade-1
  (Log "pivots-since-entry" 5)
  (Linear "entry-vs-pivot-avg" -0.03 1.0)  ;; entered below avg pivot price
  (Log "pivots-survived" 5)                 ;; survived 5 pivots = runner
  (Log "excursion" 0.047)                   ;; captured 4.7%
  (Linear "retracement" 0.12 1.0))          ;; 12% off peak

;; Context: this is a runner. 5 pivots deep. 4.7% captured.
;; The exit observer sets a WIDE trail — let it breathe.

;; Trade 2: entered 2 pivots ago at a higher low.
(trade-biography trade-2
  (Log "pivots-since-entry" 2)
  (Linear "entry-vs-pivot-avg" 0.01 1.0)   ;; entered near avg pivot price
  (Log "pivots-survived" 2)                 ;; young
  (Log "excursion" 0.018)                   ;; captured 1.8%
  (Linear "retracement" 0.31 1.0))          ;; 31% off peak

;; Context: young trade, moderate excursion, significant retracement.
;; The exit observer sets a TIGHT trail — protect the principal.

;; Trade 3: entered THIS pivot. Newborn.
(trade-biography trade-3
  (Log "pivots-since-entry" 0)
  (Linear "entry-vs-pivot-avg" 0.02 1.0)   ;; entered above avg
  (Log "pivots-survived" 0)                 ;; just born
  (Log "excursion" 0.0)                     ;; nothing yet
  (Linear "retracement" 0.0 1.0))           ;; no peak yet

;; Context: brand new. The exit observer uses the default trail.
;; The market will teach this trade what it should become.
```

Same broker. Same candle. Three trades. Three biographies.
Three different trail distances from the exit observer. The
runner gets room. The young trade gets protection. The newborn
gets the default. Each correct given its biography.

## The broker's portfolio

At any given candle, a broker may have N active trades:

```scheme
;; A dip produces 3 pivots over 150 candles.
;; Candle 100: pivot. Broker enters trade-1. (1 active)
;; Candle 147: pivot. Broker enters trade-2. (2 active)
;; Candle 198: pivot. Broker enters trade-3. (3 active)

;; The move extends. 2 more pivots.
;; Candle 243: pivot. All 3 trades evaluated.
;;   trade-1: 4.7% excursion, survived 3 pivots → hold (wide trail)
;;   trade-2: 2.1% excursion, survived 1 pivot → hold (medium trail)
;;   trade-3: 0.8% excursion, survived 0 pivots → hold (tight trail)
;;   Broker enters trade-4. (4 active)

;; Candle 301: pivot. Peak area.
;;   trade-1: 6.2% excursion, survived 4 pivots, retracing → EXIT.
;;            Principal returns. Residue: 5.5%. Permanent.
;;   trade-2: 3.8% excursion, survived 2 pivots → hold
;;   trade-3: 2.1% excursion, survived 1 pivot → hold
;;   trade-4: 0.9% excursion, survived 0 pivots → hold
;;   (3 active. 1 exited with residue.)

;; Another broker at candle 301 — same pivot, different biography:
;; Has been waiting. No active trades. This pivot is its ENTRY.
;; Buy and sell at the same moment. Constant accumulation.
```

The portfolio IS the biography. The number of active trades.
Their ages. Their excursions. Their survival count. These are
all facts. All encodable. The exit observer sees the trade's
individual biography. The broker sees the portfolio's shape.

## The biography atoms

Two levels of biography. The TRADE biography flows to the exit
observer (per-trade). The PORTFOLIO biography flows to the
broker's own reckoner (aggregate).

### Trade biography (per-trade, to exit observer)

Extends the 10 trade atoms from Proposal 040:

```scheme
;; NEW — pivot-aware trade atoms
(Log "pivots-since-entry" ...)      ;; how many pivots old
(Log "pivots-survived" ...)         ;; pivots where exit could have fired but didn't
(Linear "entry-vs-pivot-avg" ...)   ;; where I entered relative to recent pivot prices
```

These compose with the existing trade atoms (excursion,
retracement, age, peak-age, signaled, trail-distance,
stop-distance, r-multiple, heat, trail-cushion). The exit
observer now thinks about the trade's TEMPORAL POSITION in
the sequence of pivots, not just its price position.

### Portfolio biography (aggregate, to broker reckoner)

```scheme
;; The broker's portfolio state at this candle
(Log "active-trade-count" ...)      ;; how many running
(Log "oldest-trade-pivots" ...)     ;; age of the oldest runner
(Log "newest-trade-pivots" ...)     ;; age of the youngest
(Log "portfolio-excursion" ...)     ;; weighted avg excursion across trades
(Linear "portfolio-heat" ...)       ;; total exposure as fraction of capital

;; The broker's pivot memory — the shape of recent decisions
(Linear "pivot-price-trend" ...)    ;; regression slope of recent pivot prices
(Linear "pivot-regularity" ...)     ;; stddev/mean of pivot spacing
(Linear "pivot-entry-ratio" ...)    ;; fraction of recent pivots that were entries
(Log "pivot-avg-spacing" ...)       ;; mean candles between pivots
(Linear "pivot-price-vs-avg" ...)   ;; current price vs mean of recent pivot prices
```

The portfolio biography tells the broker: "I have 4 trades
running. The oldest is 5 pivots deep. The youngest was just
entered. My recent pivots have been entries at rising prices,
47 candles apart. This is an accumulation pattern." Or: "I
have 1 trade running. It's 8 pivots deep. My recent pivots
have been flat. This is distribution. The next pivot may be
my exit."

## The pivot detection

A pivot is detected when the market observer's conviction
exceeds a threshold. The conviction already measures
"something is happening." High conviction = pivot. The
machinery exists. No new mechanism needed.

## The broker's pivot memory

The broker maintains a bounded list of recent pivots:

```scheme
(struct pivot-record
  candle        ;; when
  price         ;; at what price
  conviction    ;; how strong
  action        ;; what I did (enter, exit-N, hold)
  trade-count)  ;; how many active trades at this pivot

(define PIVOT_MEMORY 10)  ;; remember last 10 pivots
```

At each candle, the broker checks: is this a pivot? If yes,
record it. At each pivot, evaluate EACH active trade
independently — the exit observer produces a trail distance
per trade given that trade's biography. Some trades exit.
Some hold. New trades may enter. The pivot record captures
the aggregate action.

## The exit observer's view

The exit observer already evaluates per-trade (Proposal 040).
The chain already carries trade atoms per active paper. This
proposal adds 3 pivot-aware atoms to each trade's thought.
The exit observer now sees:

1. **Market** — what the candle says (via extraction)
2. **Trade** — what THIS position says (040 atoms + 3 pivot atoms)
3. The exit observer predicts trail distance for THIS trade
   given THIS trade's full biography.

A runner (5 pivots survived, high excursion, entered below
average pivot price) gets a wide trail. A newborn (0 pivots,
no excursion) gets a tight trail. Same exit observer. Same
reckoner. Different thought. Different distance. The biography
IS the context.

## Why this matters

A single broker can:
- Enter at a local dip (pivot 1)
- Enter AGAIN at a higher low (pivot 2)
- Enter AGAIN at a confirmed breakout (pivot 3)
- Hold all three through noise
- Exit the oldest at the peak (residue captured)
- Hold the younger two through the next dip
- Enter fresh at the next dip (pivot 7)

This is constant activity. Not scalping — accumulating. Each
entry is small. Each has its own trail. Each survives or dies
on its own merits. The ones that survive become runners. The
runners produce residue. The residue is permanent.

And ACROSS brokers: while Broker A exits its oldest trade at
the peak, Broker B enters fresh. The capital recycles. The
residue stays. The portfolio rotates. Both are correct given
their biographies.

The 22 brokers don't just differ by lens. They differ by
biography. They differ by HOW MANY trades are active. They
differ by WHEN they entered. They differ by WHAT they did at
the last 10 pivots. The diversity isn't perception. It's
experience. And experience is the thought.

## The pivot series as scalars

The pivots are not just moments. They form a SERIES. The
series has shape. The shape degrades before the stop fires.
The shape IS the exit signal.

```scheme
;; The pivot series for one trade:
;;   low  $100 → high $108    range $8     higher high
;;   low  $106 → high $112    range $6     higher low, higher high
;;   low  $110 → high $111    range $1     higher low, range compressing
;;   low  $106                              LOWER LOW — pattern broke. GET OUT.

;; Each pivot is relative to the prior. Each relationship is a scalar.

(define (pivot-series-atoms pivots)
  (list
    ;; Low-to-low trend: are the lows still rising?
    ;; 100 → 106 → 110 = rising. 110 → 106 = FALLING. Get out.
    (Linear "pivot-low-trend"
      (/ (- (last-low pivots) (prev-low pivots))
         (prev-low pivots))
      1.0)

    ;; High-to-high trend: are the highs still rising?
    ;; 108 → 112 = rising. 112 → 111 = FALLING. Momentum dying.
    (Linear "pivot-high-trend"
      (/ (- (last-high pivots) (prev-high pivots))
         (prev-high pivots))
      1.0)

    ;; Range compression: is the range expanding or dying?
    ;; 8 → 6 → 1 = compressing. The energy is leaving.
    (Linear "pivot-range-trend"
      (/ (last-range pivots) (prev-range pivots))
      1.0)

    ;; Spacing trend: are pivots getting closer or farther?
    ;; Accelerating pivots = urgency. Decelerating = exhaustion.
    (Linear "pivot-spacing-trend"
      (/ (last-spacing pivots) (prev-spacing pivots))
      1.0)

    ;; How many candles since the last pivot? Are we in a pause?
    ;; Long pause after compressed range = the move is over.
    (Log "candles-since-pivot" (- current-candle (candle (last pivots))))

    ;; The pivot count in this trade's lifetime.
    ;; More pivots = more structure = more information.
    (Log "pivot-count-in-trade" (count-pivots-since-entry pivots trade))))
```

The exit observer sees these alongside the trade atoms (040)
and the per-trade biography. The pivot series tells the exit
what the trailing stop cannot: the STRUCTURE is degrading.
Lower low. Falling high. Compressed range. The stop fires
after the damage. The pivot series sees it forming.

The same series works for entries. Rising lows, expanding
range, regular spacing — the structure is building. Enter.
The market observer's conviction fires at the pivots. The
pivot series tells the broker WHETHER this pivot is an entry
or just noise.

The scalars are all relative — this pivot vs the last pivot.
No absolute prices. No magic levels. The relationship between
consecutive pivots IS the thought. The sequence of
relationships IS the biography of the move.

## The algebraic question

All atoms are Linear, Log, Circular — the same encodings.
They bundle with existing atoms. No new forms. No new
primitives. The reckoner sees biography the same way it sees
RSI. The exit observer sees trade biography the same way it
sees excursion. The vocabulary grows. The machinery doesn't.

## The simplicity question

The trade biography adds 3 atoms per trade. The portfolio
biography adds ~10 atoms per broker. The pivot memory adds a
bounded VecDeque of 10 records per broker. The pivot detection
reuses conviction. No new mechanisms. The complexity is in the
VOCABULARY, not the machinery.

## Questions for designers

1. **Pivot detection:** should the pivot be defined by market
   observer conviction, or does it need its own mechanism?

2. **Pivot memory size:** 10 pivots? 20? Should it be
   discovered or fixed?

3. **Trade biography on the chain:** the 3 new trade atoms
   flow through the existing chain to the exit observer. Should
   the pivot memory also flow, or should only the computed atoms
   travel?

4. **Portfolio biography scope:** the broker's portfolio state
   (active count, oldest, newest) — does this compose with the
   market thought in the broker's reckoner, or should it be a
   separate input?

5. **Entry decisions:** at a pivot with 3 active trades, should
   the broker still enter a 4th? What governs the maximum
   concurrent trades? A hard cap? The portfolio-heat atom
   (the reckoner learns when heat is too high)?

6. **The simultaneous buy/sell across brokers:** when Broker A
   exits and Broker B enters at the same pivot, the treasury
   sees both proposals. Should the treasury treat these as
   independent (fund both) or netted?
