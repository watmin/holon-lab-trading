# Resolution: Proposal 035 — Paper Accounting

**Date:** 2026-04-12
**Decision:** ACCEPTED — implement

## Designers

Both approved.

**Hickey:** The arithmetic gate is measurement, not model output.
Cold start: symmetric — `grace_count >= 50 AND violence_count >= 50`.
Log expected_value to the DB.

**Beckman:** EV formula algebraically correct. Break-even ~0.7%
excursion. EMA alpha ~0.038 (half-life 50 papers).

## The datamancer's decision

The reckoner is REMOVED from the broker. The broker proved across
10 runs that it cannot predict Grace/Violence per-candle. The
broker becomes: accounting + gate + log. Pure arithmetic.

The 25-atom readiness thought exists as a ThoughtAST — NOT as a
vector. The AST IS the data. It IS readable. It IS the log. The
vector is the opaque form — you encode into it when you need to
do algebra, you can't see into it. The broker doesn't need
algebra. The broker needs arithmetic and a log.

The AST representation IS the vector in transparent form. Same
atoms, same values, same structure. A consumer who wants the
vector takes the AST and encodes it — at their own dims, with
their own noise subspace, for their own purpose. That is a log
stream consumer, not the broker. The broker produces data. The
consumer does algebra.

The broker does not spin cycles encoding thoughts that no one
consumes as vectors. The encoding is deferred until a consumer
chooses to do it. The system is deterministic — same AST, same
dims, same seed, same vector. The deferral loses nothing.

## The protocol

The broker still receives `(raw, anomaly, ast)` from market and
exit through the pipe. The protocol carries them. The broker
accepts them. The broker does not use them. They exist for
record keeping. The protocol is intact. A log consumer could
read the broker's received inputs alongside the broker's own
thought AST and reconstruct the full picture.

## The changes

1. **Remove from broker:** reckoner, noise_subspace,
   good_state_subspace, last_composed_anomaly, cached_edge,
   recalib_wins, recalib_total, last_recalib_count, engram gate.
   All of it.

2. **Remove from broker thread:** encoder handle usage for
   thought encoding. No `brk_enc.encode()`. No `propose()`.
   The broker thread computes scalar facts, builds the AST,
   logs it, checks the gate.

3. **Broker struct gains accounting:**
   - `avg_grace_net: f64` — EMA of net dollars per Grace paper
   - `avg_violence_net: f64` — EMA of net dollars per Violence paper
   - `accounting_alpha: f64` — 0.038 (half-life ~50 papers)
   - `expected_value: f64` — computed from the above

4. **Dollar P&L at resolution:**
   ```
   reference = 10_000.0
   swap_fee = 0.0035

   Grace:
     residue_usd = excursion × reference
     exit_fee = (reference + residue_usd) × swap_fee
     net = residue_usd - entry_fee - exit_fee

   Violence:
     loss_usd = stop_distance × reference
     exit_fee = (reference - loss_usd) × swap_fee
     net = -(loss_usd + entry_fee + exit_fee)
   ```

5. **Gate:** Replace `cached_edge > 0.0 || !curve_valid()` with:
   ```
   let cold_start = grace_count < 50 || violence_count < 50;
   let ev = grace_rate × avg_grace_net
          + (1.0 - grace_rate) × avg_violence_net;
   cold_start || ev > 0.0
   ```

6. **Broker snapshot simplified:** Remove disc_strength,
   last_conviction, curve_valid, resolved_count, proto_cos.
   Add expected_value, avg_grace_net, avg_violence_net. The
   thought_ast stays — the AST as EDN, the glass box.

7. **propagate() simplified:** No reckoner. Just: update
   accounting (dollar P&L, counts, EMA), update scalar
   accumulators, return PropagationFacts.

8. **propose() removed.** No noise subspace. No predict.
   The broker has no propose step. The gate is arithmetic.

## What doesn't change

- The ThoughtAST computation (25 atoms — opinions + self + derived)
- The paper mechanics (trail, stop, excursion)
- The market and exit observers
- The pipe protocol (raw, anomaly, ast flow through)
- The scalar accumulators (trail/stop distance learning)
