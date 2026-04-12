# Proposal 035 — Paper Accounting

**Date:** 2026-04-12
**Author:** watmin + machine
**Status:** PROPOSED

## The situation

The broker's reckoner cannot predict Grace/Violence per-candle.
Proposal 034 reframed the broker as a readiness gate — "am I
ready to be accountable?" The readiness thoughts (25 atoms) are
the glass box — the log of what was known at decision time. The
reckoner is a diagnostic consumer of those thoughts, not the gate.

The gate is arithmetic: is the broker making money after costs?
The broker needs to track its own profitability in dollar terms
against a reference position.

## The reference position

$10,000 at the current candle's close. Fixed dollar amount.
Variable BTC amount. Each paper: "if I swapped $10,000 USDC → BTC
at this close, what happens?"

```scheme
(define reference-usd 10000.0)
(define entry-close (:close candle))
(define position-btc (/ reference-usd entry-close))

;; Entry fee: 0.35% of $10,000
(define entry-fee (* reference-usd 0.0035))   ;; $35

;; The paper lives. Trail or stop fires.

;; Grace: trail fires at some exit price.
;; residue-pct = excursion (fraction of entry)
;; residue-usd = residue-pct × reference-usd
;; exit-fee = (reference-usd + residue-usd) × 0.0035
;; net-grace = residue-usd - entry-fee - exit-fee

;; Violence: stop fires.
;; loss-pct = stop-distance (fraction of entry)
;; loss-usd = loss-pct × reference-usd
;; exit-fee = (reference-usd - loss-usd) × 0.0035
;; net-violence = -(loss-usd + entry-fee + exit-fee)
```

## Rolling metrics (on the broker)

```scheme
(struct broker-accounting
  [grace-count       : usize]      ;; already exists
  [violence-count    : usize]      ;; already exists
  [total-net-residue : f64]        ;; sum of net-grace and net-violence
  [avg-net-residue   : f64]        ;; EMA of net per paper
  [avg-grace-net     : f64]        ;; EMA of net per Grace paper
  [avg-violence-net  : f64])       ;; EMA of net per Violence paper (negative)
```

Updated at every paper resolution in propagate() or tick_papers().

## The gate

```scheme
(define (broker-gate broker)
  (let ((ev (+ (* (:grace-rate broker) (:avg-grace-net broker))
               (* (- 1 (:grace-rate broker)) (:avg-violence-net broker)))))
    ;; Expected value per paper, in dollars, after fees.
    ;; Positive = making money. Negative = losing money.
    (> ev 0.0)))
```

One multiplication. One comparison. The gate opens when the
expected value is positive. Papers register. The gate closes
when expected value goes negative. Papers stop.

The gate replaces: `broker.cached_edge > 0.0 || !broker.reckoner.curve_valid()`.
Cold start: the gate starts OPEN (no history, give the broker a
chance to learn). After N papers (e.g. 100), the gate begins
gating.

## The thoughts remain

The 25-atom readiness bundle is still encoded. Still logged to
the DB as EDN. Still the glass box. The reckoner still processes
it — still accumulates Grace/Violence prototypes. If the curve
ever validates, the curve adds selectivity on top of the
arithmetic gate. The thoughts are the log first. The reckoner
is a consumer second.

```scheme
;; Per candle, per broker:
;; 1. Encode 25 readiness atoms → thought AST → logged to DB
;; 2. Reckoner processes thought → diagnostic (proto_cos, disc_strength)
;; 3. Arithmetic gate: expected_value > 0? → decision
;; 4. If gate open AND (curve says edge OR cold start): register paper
```

## What changes

1. **Broker struct gains accounting fields:** total-net-residue,
   avg-net-residue, avg-grace-net, avg-violence-net.

2. **Paper resolution computes dollar P&L:** At resolution,
   compute net residue in dollars using $10,000 reference position,
   the entry close (on the paper), the excursion or stop distance,
   and the venue fees (entry 0.35% + exit 0.35%).

3. **Gate changes:** from `cached_edge > 0.0 || !curve_valid()`
   to `expected_value > 0.0 || cold_start`. Cold start = fewer
   than 100 resolved papers.

4. **Broker snapshot gains accounting:** Log the expected_value,
   avg-grace-net, avg-violence-net to the DB for diagnostics.

## What doesn't change

- The thought encoding (25 atoms, opinions + self + derived)
- The reckoner (still runs, still accumulates, still diagnostic)
- The paper mechanics (trail, stop, excursion)
- The market and exit observers
- The treasury (still funds based on edge — future work to
  integrate paper accounting)

## Questions

1. Should the accounting use the candle close or the paper's
   entry_price? The paper stores entry_price. The $10,000
   reference is at entry_price. Use entry_price.

2. The EMA decay rate for rolling metrics — should it match
   the recalib interval? Or be independent? The gate should
   respond to regime shifts (fast decay) but not overreact to
   single bad papers (not too fast).

3. The cold start: 100 papers before gating. Is that too many?
   Too few? The bootstrap produces near-zero-distance papers
   that resolve fast. 100 papers might be 10 candles.
