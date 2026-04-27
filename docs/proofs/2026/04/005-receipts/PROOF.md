# Proof 005 — Receipts (generic utility on top of proof-of-computation)

**Date:** opened 2026-04-26, shipped 2026-04-26.
**Status:** **SHIPPED.** Pair file at
[`wat-tests-integ/experiment/010-receipts/explore-receipts.wat`](../../../../wat-tests-integ/experiment/010-receipts/explore-receipts.wat).
Sixteen deftests (T1–T16) demonstrate three views of one underlying
object — Receipt, Journal, Registry — plus three applied
demonstrations (build-cache, decision-journal, dual-stored receipt).
Total run: 55ms across all 16 tests.
**Predecessor:** proof 004 (directed-evaluation) shipped the
substrate's proof-of-computation property. This proof builds the
first generic utility on top.
**No new substrate arcs.** Everything ships with the substrate as it
stands post-arc-066. Proof 005 is pure consumer.

---

## The claim

**The proof-of-computation primitive composes into useful utilities
without further substrate work.** Specifically:

1. **Receipt** — a portable record `(bytes, form, seed-hint)` that
   any party with `(form, seed)` can verify by re-encoding. Carries
   F in the clear (this is *not* encryption); the cryptographic
   property is verifiability, not secrecy.
2. **Journal** — `Vec<Receipt>` for ordered append-only audit
   trails. Position is part of the record; cross-position swaps
   are detectable. The shape any auditable decision log wants.
3. **Registry** — `HashMap<hex(bytes), Receipt>` for content-
   addressed lookup. Given V (the public commitment), recover the
   full receipt. The shape any build cache, content-addressable
   store, or program-by-output index wants.
4. **Each utility is one wat program** built only on substrate
   primitives that proof 004 left in place. No new arc work
   required for the consumer to land utility.

---

## Naming verdict (gaze ward)

The /gaze ward (subagent invocation 2026-04-26) returned the naming
bundle. Sharp verdicts on alternatives:

| Surface | Chosen | Rejected (Level 1 lies) |
|---------|--------|--------------------------|
| Proof name | `005-receipts` | `generic-utility` (says nothing about WHAT); `verifiable-receipts` (redundant — receipts are verifiable here by definition) |
| Unit type | `Receipt` | `Commitment` (cryptographic commitments hide F until reveal; ours ships F); `Witness` (in ZK, a witness is the *secret* input); `Proof` (too strong — this is evidence, not a proof object) |
| Ordered collection | `Journal` | `Ledger` (implies double-entry/balance accounting); `Chain` (implies hash-linked entries — we don't link); `Vault` (implies secrecy) |
| Content-addressed collection | `Registry` | `Repository` / `Catalog` / `Store` (Level 3 taste, weaker) |
| Unit verbs | `issue` / `verify` | `mint` (implies scarcity); `commit` (collides with cryptographic-commitment vocabulary); `forge` (implies tamper-resistance we don't add at this layer); `prove` (matches the rejected `Proof` lie) |
| Journal verbs | `append` / `verify-at` | `inscribe` (taste); `commit` for append (would collide with rejected unit verb) |
| Registry verbs | `register` / `lookup` | `recover` (Level 1 lie: implies reversing the directed graph — proof 004 says that's unbounded); `resolve` (DNS/promise baggage); `publish` (implies broadcast) |
| Field names | `bytes` / `form` / `seed-hint` | `V_bytes` (definition-site artifact); `F` (Level 2 mumble outside tight scope); `K_hint` (same mumble) |

The bundle survives gaze because each name says exactly what the
operation does — no metaphor reaches beyond what's actually
implemented.

---

## A — Surface

The whole experiment is one file (`explore-receipts.wat`), one
make-deftest helper block defining three structs and seven verbs:

| Op | Type | Use |
|----|------|-----|
| `:exp::Receipt/new` | `(bytes, form, seed-hint) → Receipt` | struct constructor |
| `:exp::issue` | `(form, seed-hint) → Receipt` | encode + wrap as Receipt |
| `:exp::verify` | `(Receipt, candidate-form) → bool` | re-encode + coincident? against stored bytes |
| `:exp::Journal/new` | `(Vec<Receipt>) → Journal` | struct constructor |
| `:exp::journal-empty` | `→ Journal` | empty constructor |
| `:exp::append` | `(Journal, Receipt) → Journal` | functional append |
| `:exp::verify-at` | `(Journal, idx, candidate-form) → bool` | bounded-index verify |
| `:exp::Registry/new` | `(HashMap<String,Receipt>) → Registry` | struct constructor |
| `:exp::registry-empty` | `→ Registry` | empty constructor |
| `:exp::register` | `(Registry, Receipt) → Registry` | hex(bytes) → Receipt insert |
| `:exp::lookup` | `(Registry, bytes) → Option<Receipt>` | by-content lookup |

All built on top of: `:wat::holon::encode` / `:wat::holon::vector-bytes`
/ `:wat::holon::bytes-vector` / `:wat::holon::coincident?` /
`:wat::core::Bytes::to-hex` / `:wat::core::HashMap` /
`:wat::core::assoc` / `:wat::core::get` / `:wat::core::conj` /
`:wat::core::length`.

---

## B — The sixteen tests

| # | Test | Section | Claim |
|---|------|---------|-------|
| T1 | issue-and-verify | Receipt | issue + verify(matching form) → true |
| T2 | rejects-wrong-form | Receipt | verify(receipt, different form) → false |
| T3 | tamper-detect | Receipt | Receipt with empty bytes → verify rejects (decode fails) |
| T4 | accessors | Receipt | struct fields round-trip; form preserved structurally |
| T5 | receipts-compose | Receipt | re-issued receipts cross-verify; encoding is deterministic |
| T6 | journal-append-and-verify | Journal | empty → append one → verify-at(0) → true; len=1 |
| T7 | journal-multi-entry-order | Journal | three receipts, each verifies at its own index |
| T8 | journal-cross-mismatch | Journal | verify-at(idx, wrong-form) rejects; position is binding |
| T9 | journal-out-of-range | Journal | past-tail and empty-journal lookups → false |
| T10 | registry-register-and-lookup | Registry | register → lookup-by-bytes → verify success |
| T11 | registry-unknown-key | Registry | lookup with un-registered bytes → :None |
| T12 | registry-multi-entry | Registry | three receipts registered; each lookup verifies |
| T13 | registry-lookup-then-verify | Registry | full round trip — V → lookup → Receipt → verify(F) → true |
| T14 | build-cache | Application | Registry as build cache: miss → compute → register → hit verifies |
| T15 | decision-journal | Application | Journal as audit trail: each decision verifies at its position; out-of-order rejects |
| T16 | dual-stored-receipt | Application | one Receipt in BOTH Journal and Registry; both views verify against the same instance |

---

## C — What this proves about utility

### The unit is the load-bearing primitive

Receipt is not a wrapper around `(bytes, form, seed-hint)` — it IS
the proof-of-computation primitive given a name and a constructor.
Every higher-level structure (journal, registry, applications)
references Receipt directly; nothing replicates the verification
logic.

### Two views, same record

T16 closes the unification: a Receipt issued ONCE can be appended
to a Journal AND registered in a Registry, with both verification
paths succeeding against the same struct instance. The Journal and
Registry are *views* — the difference is the access pattern
(by-position vs by-content), not the unit they hold.

This matters because it means future views (e.g., a graph of
receipts where edges are derivation relationships, or a sliding-
window cache that evicts old receipts) can be added without
disturbing what's here. Each new view is a new container; the
receipt stays the same.

### No new substrate arcs

Proof 004 shipped six arcs (061-066). Proof 005 ships zero. The
substrate's proof-of-computation primitive composes into utility
without growing the substrate further. This is the test that the
substrate work was at the right level of abstraction — utility
fell out of consumption, not out of further substrate iteration.

### The applications are real shapes

T14 (build cache) and T15 (decision journal) are not toy demos —
they ARE the access patterns that real consumers would use:

- **Build cache** — index by V (the encoded inputs); lookup-or-
  compute access pattern; every cache hit is verifiable so cache
  poisoning is impossible by construction. The Registry IS this.
- **Decision journal** — append-only ordered record; each entry
  verifiable independently; position is part of the audit (you
  can't reorder history). The Journal IS this.

Any future consumer (the trading lab's treasury, an external audit
log, a distributed lattice's sync protocol) reaches for the same
two shapes and gets verifiability for free.

---

## D — Numbers

- **16 tests passing**, 0 failing
- **Total runtime**: 55ms across all 16 (T1-T16) on a release build
- **Per-test runtime**: 2-3ms each (in-process, no hermetic forks)
- **Zero substrate arcs shipped** — all consumer code
- **Zero regressions** in any wat-rs or holon-lab-trading test suite
- **One file**: 489 lines (helpers + 16 deftests + section markers)

---

## E — The thread

- Proof 001 — the machine runs (Q1 2026)
- Proof 002 — thinker baseline (single-window arithmetic)
- Proof 003 — thinker significance (multi-window sampling)
- Proof 004 — directed evaluation (the substrate proves computation)
- **Proof 005 — receipts (this file) — the substrate's utility lands**

Proof 004 demonstrated a *property*. Proof 005 demonstrates that
the property *composes into utility* without further substrate work.
The pair forms a closure: substrate has property → property has
useful shape → consumer builds shape → shape works.

---

## F — What this enables next

After proof 005 ships:

- **Treasury audit-log** — the trading lab's treasury can pre-commit
  decisions as Receipts in a Journal, reveal forms at settlement,
  prove decisions were committed before outcomes were observed.
  Tamper-evident decision-making by construction.
- **Distributed Registry** — multiple wat-vm instances on the same
  seed can synchronize Registries by exchanging Receipts as bytes.
  Content-addressed lookup across the network. Each entry is
  independently verifiable.
- **Receipt-typed channels** — kernel queue/topic primitives could
  carry Receipts directly; consumers verify on receive; only
  receipt-validated messages enter downstream state.
- **Higher-order receipts** — a Receipt of a form that contains
  receipts (proof of a Journal's contents at time T). Recursive
  verifiability. Out of scope for v1; substrate already supports it.

---

## G — The session

The proof shipped in a single working session 2026-04-26, the same
session that shipped proof 004. The pair represents:

- **Eight scratch beats** for proof 004 at
  `scratch/2026/04/002-directed-evaluation/`
- **Six substrate arcs** (061-066) for proof 004 at
  `wat-rs/docs/arc/2026/04/`
- **Book chapter 64** — proof 004's narrative synthesis
- **Proof 004** — the substrate property shipped
- **Proof 005 (this)** — the first utility built on the property
- **Experiment 010** — the empirical demonstration

The substrate-and-consumer cycle worked at two scales: substrate
arcs supported substrate property (proofs 001-004); substrate
property supported consumer utility (proof 005). The substrate
stops growing for now; consumers build on what's there.

PERSEVERARE.
