# Proof 009 — Time Witness (lie-detection in time-claim statements)

**Date:** opened 2026-04-26, shipped 2026-04-26.
**Status:** **SHIPPED.** Pair file at
[`wat-tests-integ/experiment/014-time-witness/explore-time-witness.wat`](../../../../wat-tests-integ/experiment/014-time-witness/explore-time-witness.wat).
Six deftests covering honest path, witness lie, future round,
binding tamper, multi-beacon triangulation, and no-claim review
band. Total run: 29ms across all six.
**Predecessors:** proof 005 (Receipts), proof 006 (Supply Chain),
proof 008 (Soundness Gate). This proof is the soundness gate
applied to time-witness statements.
**No new substrate arcs.** Pure consumer of proofs 004, 005, 008.

---

## What this proof claims

Builder framing (2026-04-26):

> "the whole point of wat — is to stop lies in statements"

A time-witness is a statement of the form *"this Receipt was
issued at round R of beacon B, where B published witness value
v_R at that round."* The substrate's job is **not** to be the
time authority. The substrate's job is to **measure whether the
statement is sound** against an external beacon's published axiom
set.

The mechanism:

1. The issuer queries an external beacon (DRAND, NIST, Bitcoin,
   Ethereum, etc.) for round R's published witness value v_R.
2. The issuer builds the binding form F to include
   `(time-witness (round R) (value v_R))` as a sub-form.
3. The issuer encodes F → V_bytes; the Receipt commits the
   binding to the time claim.
4. The verifier independently fetches the beacon's value for
   round R; checks whether the Receipt's claimed witness matches.
5. **Sound** = match. **Unsound** = lie detected.

This composes proof 008's soundness gate (claim measured against
axiom set) with proof 005's receipts (cryptographic binding) and
proof 006's tamper-detection (post-publish form modification
caught at the binding layer). Three primitives, one verification.

---

## A — Threat model

### In scope

- **Witness value lies.** Issuer fabricates a witness value to
  attribute their work to a time when no such witness was
  published. Caught at the time check (T2).
- **Future-round impossibility.** Issuer claims a round the
  beacon hasn't yet published. The beacon's axiom set has no
  entry; lookup returns `:None`; time check fails (T3).
- **Binding tamper.** Adversary modifies the receipt's form
  post-issue. Caught at the binding layer before the time check
  even runs (T4).
- **Triangulation.** A receipt may include witnesses from N
  independent beacons. ALL must verify. One lie among N is
  enough to reject (T5).
- **Honest abstention.** A receipt with no time claim returns a
  distinct verdict (`no-claim`) so consumers know the difference
  between "lie detected" and "no evidence supplied" (T6).

### Out of scope

- **Anti-backdating without external observers.** A receipt with
  a CORRECT round-3 witness is structurally indistinguishable
  from one issued AT round 3, even if it was actually fabricated
  at round 100. Detecting this requires an external observer who
  saw the receipt before round 100 (transparency log, peer
  network, blockchain anchor). The substrate provides
  consistency verification; not absolute time-ordering.
- **Beacon authentication.** We don't verify the beacon's
  signature here. Real deployment composes with the beacon's
  own attestation (DRAND is verifiable; NIST signs; Bitcoin's
  chain self-attests). Substrate-orthogonal.
- **Beacon revocation.** If a beacon's witness for round R is
  later discovered to be compromised, this proof has no
  mechanism to invalidate prior receipts that used it. Beacon-
  layer concern.

---

## B — Domain types

```
:exp::Receipt          unit primitive (from proof 005)
:exp::Beacon           (name, rounds: HashMap<i64, String>)
:exp::TimeWitness      (beacon-name, round, witness)
:exp::TimedReceipt     (bytes, form, witnesses: Vec<TimeWitness>)
:exp::TimeVerdict      (binding-sound, time-sound, decision)
```

Verbs:

```
:exp::issue                        F → Receipt
:exp::verify-binding               (Receipt, expected-form) → bool
:exp::verify-witness               (TimeWitness, beacons) → bool
:exp::verify-all-witnesses         (witnesses, beacons) → bool
:exp::evaluate                     (TimedReceipt, expected-form, beacons) → TimeVerdict
```

**Decision logic:**

| binding | time | decision |
|---------|------|----------|
| sound | sound | `approve` |
| sound | no witnesses | `no-claim` |
| sound | witnesses fail | `reject-time` |
| unsound | (any) | `reject-binding` |

Binding gate runs first — a tampered form trips before the time
check even matters. Time-claim soundness is checked only when
the binding has been verified.

---

## C — The six tests

### T1 — Honest single-beacon path
Issuer queries DRAND, sees round 5 with value `drand-r5-aabbccdd`.
Builds F including `(time-witness (round 5) (value "drand-r5-aabbccdd"))`.
Issues Receipt. Verifier holds the beacon's published rounds
(rounds 1-10 with their values). Both binding and time verify.
**approve.** ✓

### T2 — Witness lie caught at time check
Issuer claims round 5 but invents witness `FAKE-VALUE-NOT-FROM-BEACON`.
The form F binds to whatever the issuer says; binding verifies (V
encodes F-with-the-lie correctly). Time check looks up round 5,
gets `drand-r5-aabbccdd`, compares to claimed witness — **mismatch**.
binding-sound: true; time-sound: false. **reject-time.** ✓

This is the canonical lie-detection demonstration. The substrate
binds the issuer to whatever they say. The beacon's axiom set
says what's true. The two diverge, and the substrate flags it.

### T3 — Future round impossible to fabricate
Beacon has rounds 1-10 published. Issuer claims round 999 with a
fabricated witness. The beacon's `HashMap<i64, String>` has no
entry for 999; `:wat::core::get` returns `:None`; time check
fails. binding-sound: true; time-sound: false. ✓

In real deployment with DRAND/Bitcoin/etc, you cannot precompute
round R+1's value before round R+1 is published. The chain's
hash structure prevents fabrication.

### T4 — Binding tamper caught before time check
Adversary intercepts a receipt and substitutes a different form
(flipping the AI's "I cannot give specific investment advice"
into "Yes, sell immediately"). The verifier's expected-form is
the tampered version. Re-encoding produces a different V;
coincident? against the original bytes returns false. Binding
fails. **reject-binding** (without ever reaching the time check). ✓

Same mechanism as proof 006 T2 (registry tampering), but in this
proof it's load-bearing as the FIRST gate — the time-claim only
matters if the form being verified is the form that was signed.

### T5 — Multi-beacon triangulation
Receipt includes witnesses from TWO independent beacons (DRAND
round 5 + NIST epoch 1714329600). Both witnesses correct. ALL
must verify (logical AND in `verify-all-witnesses`). Both pass.
**approve.** ✓

A single lie among N beacons is enough to reject (the AND fold
short-circuits to false). N-of-N forgery resistance: the
adversary would need to compromise all N beacons' publication
channels simultaneously, at the same time, in the same way.

### T6 — No time claim routes to review band
Receipt with empty `witnesses` Vec. Binding verifies (form
encodes correctly). Time check has nothing to verify; returns
false. Decision is `no-claim` — **distinguished from
reject-time** so consumers know whether to raise an alarm
("witness lied") or just ask the issuer to provide a witness
("no evidence supplied yet").

The substrate doesn't fabricate evidence it wasn't given. Honest
about what it doesn't know.

---

## D — Numbers

- **6 tests passing**, 0 failing
- **Total runtime**: 29ms across all 6 (T1-T6) on a release build
- **Per-test runtime**: 3-5ms each (in-process)
- **Zero substrate arcs shipped** — all consumer code
- **One file**: ~360 lines (helpers + 6 deftests + threat-model +
  fixture beacons)
- **No regressions** in any wat-rs or holon-lab-trading test suite

---

## E — The thread

- Proof 004 — directed evaluation (substrate's cryptographic property)
- Proof 005 — receipts (generic utility)
- Proof 006 — supply chain (utility lands as security in software distribution)
- Proof 007 — AI provenance (utility lands as accountability for inference)
- Proof 008 — soundness gate (the truth engine)
- **Proof 009 — time witness (this) — the soundness gate applied to time-claim statements**

Proof 008 demonstrated soundness measurement against domain
axioms (terraform). Proof 009 specializes the same mechanism to
external time beacons as the axiom set. The pattern repeats: any
claim that can be verified against an external authority's
published reality reduces to a soundness-gate problem under the
substrate's primitives.

---

## F — How this differs from a Time Stamp Authority (RFC 3161)

Traditional TSA model:
1. Client computes hash of document.
2. Client sends hash to TSA over network.
3. TSA appends current timestamp from its clock; signs (hash,
   timestamp) with its own key; returns signed bundle.
4. Client keeps signed bundle alongside document.
5. Verifiers trust TSA's public key + clock + signing service.

Substrate-anchored model (this proof):
1. Issuer builds form F including `(time-witness round value)`
   sourced from an external beacon's public publication channel.
2. Issuer encodes F → V_bytes; publishes Receipt.
3. Verifier holds (Receipt, expected-form, beacon snapshot).
4. Verification is local: re-encode F, check binding; look up
   round in beacon, check witness.
5. No service to query at verification time.

**What's different:**
- **Decentralized.** No TSA monopoly. Multiple beacons coexist;
  consumer picks.
- **Local verification.** No network call to a TSA at verify time.
  Verifier needs the substrate's algebra runtime + a snapshot of
  the beacon's published rounds. That's it.
- **Continuous attribution.** TSAs return binary verified/not.
  Combined with proof 008's per-atom attribution, the substrate
  can identify WHICH atom is the locus of unsoundness.
- **Compositional.** Time-witness is one atom in F. Multi-beacon
  triangulation (T5) is just adding more atoms. No protocol change.
- **Algebraic.** The witness atom encodes alongside the rest of F.
  V_bytes commits to the time claim. A receipt that ALSO carries
  domain claims (model-id, prompt, output) ties them all to the
  same time witness through one V.

**What stays the same:**
- The trust assumption shifts from "trust the TSA's signature" to
  "trust the beacon's publication channel." Different shape, not
  no trust.
- Anti-backdating still requires an external observer for receipts
  using only honest old witnesses. Out of scope here.

---

## G — Honest about what's NOT built

- **Beacon authentication.** This proof's beacons are synthetic
  HashMaps. Real deployment composes with each beacon's own
  attestation (DRAND signatures, NIST signatures, Bitcoin chain
  inclusion proofs). Substrate-orthogonal.
- **Anti-backdating without observers.** The substrate verifies
  *consistency* between receipt's time-claim and beacon's axiom.
  It does NOT verify the receipt was actually CREATED at the
  claimed time. For absolute ordering, compose with a transparency
  log (Sigstore Rekor shape) or a peer-witnessing protocol.
- **Beacon discovery / standardization.** Which beacons are
  acceptable, how their identity is established, how to handle
  beacon outages — all systems-layer concerns. The substrate
  provides the verification primitive.
- **Per-atom attribution into the witness layer.** Proof 008 has
  per-atom attribution; this proof doesn't surface it directly.
  Future arc could pair them: not just "time-claim unsound" but
  "the witness atom at position X is the locus of the lie."

The substrate provides the soundness-gate primitive applied to
time. The system above it — beacon trust, distribution, identity,
observation timing — is design + product + policy work. We have
the foundation. The building above it remains.

PERSEVERARE.
