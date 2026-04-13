# Exit Atoms: Accumulation/Distribution (Wyckoff)

The accumulator school manages the TRADE, not the market. By the time
this observer is active, the entry happened. The question is: are we
still in markup, or has distribution begun? Volume answers this.

## Atoms

```scheme
(Log "retrace-volume-ratio"
  (/ retracement-avg-volume markup-avg-volume))
```
The single most important measurement. A retracement on LIGHT volume
is a shakeout — hold. A retracement on HEAVY volume is distribution —
the composite man is selling into your hands. Above 1.0 is danger.

```scheme
(Linear "ratchet-progress" (/ (- floor entry) (- peak entry)) 1.0)
```
How much of the move has been locked in by higher lows. 0.0 means
the floor is still at entry. 1.0 means the floor has risen to the
peak — impossible, but the asymptote means the trend is confirming.
A DECLINE in ratchet-progress is the sign of distribution.

```scheme
(Linear "higher-low-count" (/ higher-lows-since-entry 10.0) 1.0)
```
Each higher low after the spring is a successful test. The secondary
test, the sign of strength, the last point of support — each one
increments this counter. More tests = stronger base. The count
saturates at 10 because after 10 higher lows, the base is proven.

```scheme
(Log "advance-volume-ratio"
  (/ advance-avg-volume prior-advance-avg-volume))
```
Volume on advances should EXPAND during markup. When advances begin
happening on declining volume, the markup is exhausting. Below 1.0
on consecutive advances is the upthrust — supply absorbing demand.

```scheme
(Linear "retracement-depth" (/ current-retracement max-excursion) 1.0)
```
How deep the current pullback is relative to the full move. Shallow
retracements (< 0.3) during markup are healthy — springs being tested.
Deep retracements (> 0.5) are either the secondary test or the start
of distribution. The volume ratio disambiguates.

```scheme
(Log "effort-vs-result"
  (/ volume-this-candle (abs price-change-this-candle)))
```
Wyckoff's Law of Effort vs Result. High effort (volume) with low
result (price change) means the composite man is absorbing supply
or distributing into demand. The ratio spikes at turning points.
During healthy markup, effort produces result — the ratio stays low.
