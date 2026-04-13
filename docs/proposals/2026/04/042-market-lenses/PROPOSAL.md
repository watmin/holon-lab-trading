# Proposal 042 — Market Lenses

**Scope:** userland

**Depends on:** Proposal 041 (market vocabulary challenge)

## The current state

Six market observers: momentum, structure, volume, narrative,
regime, generalist. Each selects ~20-40 atoms from the 80+
vocabulary. The generalist gets all atoms.

Proposal 041 cut 80 to ~20 consensus atoms. Three voices agreed.
Fibonacci, ichimoku, stochastic, most keltner — cut.

## The consensus atoms (~20)

```scheme
;; All three agreed:
volume-ratio obv-slope adx di-spread close-sma20
rsi hurst kama-er roc-1 roc-6 roc-12
rsi-divergence-bull rsi-divergence-bear

;; Two of three:
macd-hist atr-ratio choppiness mfi
buying-pressure selling-pressure
tf-agreement squeeze
```

## The question

How do we group these ~20 atoms into market observer lenses?

The current six lenses were vocabulary subsets. 041 collapsed
the vocabulary. If every observer sees the same 20 atoms,
the lenses are identical — no diversity. If we split the 20
into subsets, what are the NATURAL groups?

For the exit observers (040), three voices converged on the
SAME atoms. We used 2 observers: core (5) and full (10).
Diversity through atom count, not atom selection.

For the market observers: the atoms naturally cluster by
WHAT QUESTION they answer:

1. **Trend** — is a trend established and persisting?
2. **Momentum** — is momentum leading or diverging from price?
3. **Volume** — is volume confirming the move?
4. **Regime** — is the market trending or choppy?

Or do we follow the exit pattern: 2 observers (lean and full)?
Or one generalist with all 20?

## For the designers

Given the ~20 consensus atoms from Proposal 041, propose:

1. How many market observers? (currently 6)
2. What are the groups? Name them. List the atoms in each.
3. Should there be a generalist (all atoms)?
4. What is the grid? N market × 2 exit = ? brokers.

The grid determines the thread count, the fee multiplication,
the sample size per broker. Fewer observers = fewer brokers =
less diversity but more data per broker.

Express your groups as wat:
```scheme
(define (market-lens-name)
  (list
    (atom-1)
    (atom-2)
    ...))
```
