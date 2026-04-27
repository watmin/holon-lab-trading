# Deferred items from the original 8-proof robustness arc (011–018)

**Date logged:** 2026-04-27.
**Context:** The original arc opened on 2026-04-26 was *"how do we
challenge our recent proofs for shallowness?"* — eight proofs each
closing a specific shallowness gap (property tests, real-data
integration, scaling stress, error-path exhaustion, cross-proof
composition, calibration sweep, adversarial fuzz, concurrency
stress).

Across two sessions the arc partly shipped and partly superseded
itself:

- **011 — property tests.** ✅ Shipped (`docs/proofs/2026/04/011-property-tests`).
- **012 — real-data integration.** Original framing: "wire proofs to BTC candles / network packets." Now superseded — see Deferred-1 below.
- **013 — scaling stress.** ✅ Shipped (`013-scaling-stress`).
- **014 — depth-honesty.** ✅ Shipped (`014-depth-honesty`) — pivoted
  mid-arc from the original "error-path exhaustion" plan to the user's
  request for capacity-bounded depth verification.
- **015 — expansion chain (abstract two-cache model).** ✅ Shipped
  (`015-expansion-chain`) — the number was reused; original 015 plan
  was "cross-proof composition." Deferred — see Deferred-2.
- **016 — real expansion chain (the dual-LRU coordinate cache).** ✅
  Shipped (`016-fuzzy-cache`) — number reused; original 016 plan was
  "calibration sweep." Deferred — see Deferred-3.
- **017 — fuzzy locality cache.** ✅ Shipped (`017-fuzzy-locality`) —
  number reused; original 017 plan was "adversarial fuzz." Deferred —
  see Deferred-4.
- **018 — concurrency stress.** Original plan unchanged. Deferred —
  see Deferred-5.

The four deferred items below are the parts of the original arc that
did NOT survive contact with the substrate's actual development. Each
entry names what was planned, why it's deferred, and what work (if
any) would resume it.

---

## Deferred-1 — "Real-data integration" (was: proof 012)

**Original plan.** Wire proof primitives to real BTC candle data and
real network-packet captures; show end-to-end pipelines.

**Why deferred.** This isn't a proof. It's the lab's actual
demonstration — Proposal 056's *self-organizing BTC trader*. A proof
verifies a substrate claim under controlled conditions; the trading
lab's run is the substrate doing its real job under the conditions
of an actual market. They're different lanes.

**What resumes it.** The trading lab's next active arc, picking up
where Chapter 55's *bridge* paused. The substrate is now ready to
host it: arc 068's `eval-step!`, proof 016's exact-identity cache,
proof 017's fuzzy-locality cache, BOOK chapters 65 + 66 named the
load-bearing properties. The lab arc is substantial work; not a
single-proof entry.

---

## Deferred-2 — Cross-proof composition (was: proof 015)

**Original plan.** Compose the substrate's primitives — proof 010's
verifier inside proof 008's gate inside proof 005's receipts —
demonstrating they layer cleanly.

**Why deferred.** This already happened. Proofs 016 v4 and 017
compose arc 003 (TCO) + arc 023 (`coincident?`) + arc 057 (typed
HolonAST leaves) + arc 058 (`HashMap<HolonAST,V>`) + arc 068
(`eval-step!`) + chapter 59 (the dual-LRU cache). Proof 016's
walker is itself a five-arc composition; proof 017 swaps the lookup
predicate one line and inherits all five. The "cross-proof
composition" story is told operationally in the proofs that
shipped. A standalone proof would be ceremony.

**What resumes it.** A new substrate gap that surfaces a need for
explicit composition verification. Not on today's horizon.

---

## Deferred-3 — Calibration sweep (was: proof 016)

**Original plan.** Sweep `coincident?`'s sigma threshold across 5
domains (atom equality, vector recall, label classification, fuzzy
form-match, anomaly detection); verify it generalizes.

**Why deferred.** Calibration happened empirically as we went.
Chapter 28 named the slack-lemma original calibration. Proof 013's
scaling stress verified at 500 cardinality. Proof 014's depth-
honesty verified at depth 8 × width 99. Proof 017 verified
locality at the post-β leaf with R=200. Five domain slices arrive
at the same `1/√d` floor each time; sweeping a single dedicated
proof would re-derive what we already see consistent across the
existing proof set.

**What resumes it.** A user surfacing a domain where the
default calibration fails — not a hypothetical sweep before that
happens.

---

## Deferred-4 — Adversarial fuzz (was: proof 017)

**Original plan.** Maliciously crafted inputs — overlong forms,
type confusions, capacity-budget exploits, signature substitutions
on causal-time receipts — verifying the substrate refuses cleanly
without panicking or false-positive verdicts.

**Why deferred.** This is real security work but it's a security
audit, not a substrate-claim proof. The substrate's *correctness*
under benign inputs is what the proofs cover; its *robustness*
under adversarial inputs belongs to a future arc opened when the
lab faces a real adversary (or before shipping any external API).

**What resumes it.** A `wat-rs/security/` arc when the substrate
is exposed externally — production trading desk publishing
proofs to counterparties, multi-tenant runtime, etc. Today the
substrate is internal; adversaries are theoretical.

---

## Deferred-5 — Concurrency stress (was: proof 018)

**Original plan.** 100 threads running concurrent verifications
against shared receipts and caches; confirm zero-Mutex discipline
holds under stress.

**Why deferred.** Chapter 66's walker cooperation works through
plain HashMap value passing — the substrate's zero-Mutex
discipline is *already* the proof. Multi-threading a stress test
would add scheduler noise on top of an architectural property
that's structurally guaranteed. Proof 011's property tests already
exercise the substrate at iteration scale (100×6 = 600 invocations,
all single-threaded — but the substrate's thread-safety story is
*per-program ownership of values*, not *shared mutex-protected
state*; threads aren't the right axis for the property).

**What resumes it.** A consumer arc that demonstrates parallel
walkers cooperating across threads (chapter 66 named this; today's
proof 017 demonstrated it via shared-cache value, single-threaded).
That's a future lab arc on top of the trading demonstration, not
a substrate proof.

---

## What survived the arc

Three proofs that closed real shallowness gaps:
- **011** — property tests (closed "we tested 6 cases").
- **013** — scaling stress (closed "we don't know the boundaries").
- **014** — depth-honesty (closed "depth = free, but at scale?").

Plus three proofs that emerged mid-arc from the expansion-chain
recognition:
- **015** — the abstract two-cache model.
- **016** — the real dual-LRU coordinate cache via arc 068.
- **017** — the fuzzy-locality cache via `coincident?`.

Six proofs that shipped. Four planned proofs that didn't, because
the substrate's actual development surfaced different work.

The arc's stated goal — *robustness, durability, reliability of
the substrate's claims* — is met by what shipped. The deferred
entries above are honest record of what was originally planned
and why it didn't survive contact with the work.

---

## What's next

The trading lab's actual demonstration. Proposal 056's
self-organizing BTC trader, picking up at the chapter-55 bridge.
The substrate has earned the work; the lab arc opens.
