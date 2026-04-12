# Resolution: Proposal 035 — Paper Accounting

**Date:** 2026-04-12
**Decision:** ACCEPTED — implement

## Designers

Both approved.

**Hickey:** The arithmetic gate is measurement, not model output.
Cold start: symmetric — `grace_count >= 50 AND violence_count >= 50`.
Reckoner can veto, cannot approve. Log expected_value to the DB.

**Beckman:** EV formula algebraically correct. Break-even ~0.7%
excursion. EMA alpha ~0.038 (half-life 50 papers).

## The datamancer's decision

The reckoner is REMOVED from the broker. Not demoted. Removed.
The broker proved across 10 runs that it cannot predict
Grace/Violence per-candle. The reckoner costs O(K×D) noise
subspace update + O(N×D) predict per candle per broker — 24
brokers — for a discriminant that doesn't separate.

The broker becomes: accounting + gate + log. Pure arithmetic.
No algebra. No vectors beyond the thought encoding for the
glass box.

The broker still receives `(raw, anomaly, ast)` from market
and exit through the pipe. The protocol carries them. The broker
accepts them. The broker does not use them. They exist for
record keeping. The protocol is intact.

The 25-atom readiness thought is still encoded and logged to the
DB as EDN — the glass box. The thoughts are the debug interface.
They are what was known at time of execution. They are logs, not
inputs to a reckoner.

## The changes

1. **Remove from broker:** reckoner, noise_subspace,
   good_state_subspace, last_composed_anomaly, cached_edge,
   recalib_wins, recalib_total, last_recalib_count, engram gate
   logic. All of it. The broker becomes a pure accounting struct.

2. **Broker struct gains accounting:**
   - `avg_grace_net: f64` — EMA of net dollars per Grace paper
   - `avg_violence_net: f64` — EMA of net dollars per Violence paper
   - `accounting_alpha: f64` — 0.038 (half-life ~50 papers)
   - `expected_value: f64` — computed from the above

3. **Dollar P&L at resolution:** Compute:
   ```
   reference = 10_000.0
   entry_fee = reference × swap_fee
   
   Grace:
     residue_usd = excursion × reference
     exit_fee = (reference + residue_usd) × swap_fee
     net = residue_usd - entry_fee - exit_fee
   
   Violence:
     loss_usd = stop_distance × reference
     exit_fee = (reference - loss_usd) × swap_fee
     net = -(loss_usd + entry_fee + exit_fee)
   ```
   Update `avg_grace_net` or `avg_violence_net` with EMA.

4. **Gate:** Replace `cached_edge > 0.0 || !curve_valid()` with:
   ```
   let cold_start = grace_count < 50 || violence_count < 50;
   let ev = grace_rate × avg_grace_net 
          + (1.0 - grace_rate) × avg_violence_net;
   cold_start || ev > 0.0
   ```

5. **Broker snapshot simplified:** Remove disc_strength,
   last_conviction, curve_valid, resolved_count, proto_cos.
   Add expected_value, avg_grace_net, avg_violence_net. The
   thought_ast stays — it's the glass box.

6. **propagate() simplified:** No reckoner.observe(). No
   reckoner.resolve(). No reckoner.predict(). No engram gate.
   Just: update accounting (dollar P&L, grace/violence counts,
   EMA metrics), update scalar accumulators, return
   PropagationFacts.

7. **propose() removed or gutted.** No noise subspace. No
   predict. No cached_edge. The broker might not need propose()
   at all — the gate is arithmetic, not prediction-based.
   propose() becomes a no-op or is removed entirely.

## What doesn't change

- The thought encoding (25 atoms for the glass box log)
- The paper mechanics (trail, stop, excursion)
- The market and exit observers
- The pipe protocol (raw, anomaly, ast flow through)
- The scalar accumulators (trail/stop distance learning)
- The paper registration (gate decides, paper stores thought)
