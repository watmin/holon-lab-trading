# Resolution: Proposal 031 — Broker Derived Thoughts

**Date:** 2026-04-12
**Decision:** ACCEPTED — implement

## Designers

Both approved.

**Hickey:** Pure functions, correct home. Keep derivation graph
shallow. ATR as f64 on the pipe (option C). Self-exit-agreement
is structurally interesting — describes the pairing.

**Beckman:** Algebra holds — derived thoughts are algebraically
independent of raw components due to atom binding. Two scale
corrections applied:

1. risk-reward-ratio → Log (multiplicative structure)
2. conviction-vol → Log(abs) + sign as separate atom (avoids
   saturation at range ~500)

## The changes

1. **New vocab module:** `src/vocab/broker/derived.rs` — pure
   functions, 11 atoms total.

2. **Broker pipe gains atr_ratio:** One f64 from the enriched
   candle. Computed at grid level.

3. **Anomaly norms:** Computed in the broker thread from the
   vectors already on the pipe. `market_anomaly.norm()` and
   `exit_anomaly.norm()`. No pipe change needed.

4. **Broker thread encodes derived facts:** Appended to the
   bundle alongside opinions + extracted + self.

## The atoms (final, with corrections)

```scheme
;; Distance relative to volatility (2 atoms)
(Log "trail-atr-multiple" (/ trail (max atr-ratio 0.001)))
(Log "stop-atr-multiple"  (/ stop  (max atr-ratio 0.001)))

;; Risk-reward ratio (1 atom) — Log per Beckman
(Log "risk-reward-ratio" (/ trail (max stop 0.001)))

;; Conviction-volatility interaction (2 atoms) — split per Beckman
(Log    "conviction-vol-magnitude" (* (abs signed-conviction) (/ 1.0 (max atr-ratio 0.001))))
(Linear "conviction-vol-sign"      (signum signed-conviction) 1.0)

;; Exit confidence (1 atom)
(Linear "exit-confidence" (* exit-grace-rate (max exit-avg-residue 0.001)) 1.0)

;; Self-exit agreement (1 atom)
(Linear "self-exit-agreement" (- broker-grace-rate exit-grace-rate) 1.0)

;; Activity rate (1 atom)
(Log "activity-rate" (/ (max paper-count 1) (max paper-duration 1)))

;; Excursion-trail ratio (1 atom)
(Linear "excursion-trail-ratio" (/ excursion-avg (max trail 0.001)) 1.0)

;; Signal strength (2 atoms)
(Log "market-signal-strength" (max (norm market-anomaly) 0.001))
(Log "exit-signal-strength"   (max (norm exit-anomaly) 0.001))
```
