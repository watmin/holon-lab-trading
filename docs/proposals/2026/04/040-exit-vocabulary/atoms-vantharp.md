# Exit Atoms: Expectancy Management (Van Tharp)

Every atom answers one question: is this trade still worth holding after fees?

## R-multiple position

```scheme
(Log "r-multiple" (/ excursion initial-risk))
```
Where you are in R-space. Below 1R you haven't covered your risk. Above 2R you're in profit territory. The single most important number for position management.

```scheme
(Linear "fee-drag" (/ round-trip-fee excursion) 1.0)
```
Fees as a fraction of current gain. At 1.0 the fee equals the gain -- exiting nets zero. Below 0.3 the fee is noise. Above 0.5 you're bleeding.

## Trade quality

```scheme
(Log "mfe-capture" (/ excursion mfe))
```
How much of the maximum favorable excursion you still hold. 1.0 means you're at peak. 0.5 means you gave back half. Measures whether the trade is running or retreating.

```scheme
(Linear "mae-risk-ratio" (/ mae initial-risk) 1.0)
```
Maximum adverse excursion as a fraction of initial risk. Above 1.0 means the trade violated your stop thesis -- even if it recovered. Measures whether the trade behaved as expected.

## Time decay of edge

```scheme
(Log "expectancy-per-candle" (/ (- excursion round-trip-fee) candles-held))
```
Net gain per unit time. A trade earning 3% in 10 candles has better expectancy-per-candle than 3% in 100 candles. Holding has opportunity cost. This atom measures it.

```scheme
(Linear "hold-efficiency" (/ excursion (* atr candles-held)) 1.0)
```
Gain normalized by what volatility offered. ATR times candles is the theoretical opportunity. Excursion divided by that is how efficiently the hold captured available movement.

## Fee breakeven

```scheme
(Linear "fee-clearance" (/ excursion (* 2.0 swap-fee)) 3.0)
```
How many round-trip fees the current excursion covers. Below 1.0 you cannot exit profitably. Between 1.0 and 2.0 you're marginal. Above 2.0 you have room. Scale is 3.0 because beyond 3x fees the atom saturates -- the fee is no longer the dominant concern.

## Summary

Seven atoms. Three themes: R-position (where am I), trade quality (is it behaving), time-fee awareness (is holding still worth it). No market atoms -- those come from extraction. These atoms think about the TRADE, not the MARKET. The exit observer's job is to manage what it already owns.
