# Resolution: Proposal 035 — Paper Accounting

**Date:** 2026-04-12
**Decision:** ACCEPTED — implement

## Designers

Both approved.

**Hickey:** The arithmetic gate is measurement, not model output.
Cold start: symmetric — `grace_count >= 50 AND violence_count >= 50`.
EMA half-life 200-300 papers. Reckoner can veto, cannot approve.
Log expected_value to the DB. Calls for Proposal 036 (treasury
funds on expected_value).

**Beckman:** EV formula algebraically correct. Break-even ~0.7%
excursion. EMA alpha ~0.038 (half-life 50 papers). Cold start =
2× EMA effective window. Arithmetic gate is necessary condition;
curve is sufficient condition later.

## The changes

1. **Broker struct gains accounting:**
   - `avg_grace_net: f64` — EMA of net dollars per Grace paper
   - `avg_violence_net: f64` — EMA of net dollars per Violence paper
   - `accounting_alpha: f64` — 0.038 (half-life ~50 papers)

2. **Dollar P&L at resolution:** In `propagate()` or at the
   resolution call site, compute:
   ```
   reference = 10_000.0
   entry_fee = reference × swap_fee        (0.0035)
   
   Grace:
     residue_usd = excursion × reference
     exit_value = reference + residue_usd
     exit_fee = exit_value × swap_fee
     net = residue_usd - entry_fee - exit_fee
   
   Violence:
     loss_usd = stop_distance × reference
     exit_value = reference - loss_usd
     exit_fee = exit_value × swap_fee
     net = -(loss_usd + entry_fee + exit_fee)
   ```
   Update `avg_grace_net` or `avg_violence_net` with EMA.

3. **Gate:** Replace `cached_edge > 0.0 || !curve_valid()` with:
   ```
   let cold_start = grace_count < 50 || violence_count < 50;
   let ev = grace_rate × avg_grace_net 
          + (1.0 - grace_rate) × avg_violence_net;
   cold_start || ev > 0.0
   ```

4. **Broker snapshot gains `expected_value: f64`.** The gate's
   input is visible in the DB.

5. **Reckoner stays.** Still processes the 25-atom thought.
   Still accumulates prototypes. Still diagnostic. If the curve
   validates, it adds selectivity on top. The arithmetic gate is
   the floor. The curve is the ceiling.
