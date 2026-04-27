# Proof 006 — Supply Chain (a competent demonstration)

**Date:** opened 2026-04-26, shipped 2026-04-26.
**Status:** **SHIPPED.** Pair file at
[`wat-tests-integ/experiment/011-supply-chain/explore-supply-chain.wat`](../../../../wat-tests-integ/experiment/011-supply-chain/explore-supply-chain.wat).
Seven deftests (T1–T7), each mapped to a real, named attack class
production security teams fight today. Total run: 29ms across all
seven.
**Predecessors:** proof 004 (proof-of-computation as cryptographic
property), proof 005 (Receipt / Journal / Registry as generic
utility). This proof composes utility into a domain.
**No new substrate arcs.** Pure consumer of what proofs 001–005
left in place. The substrate primitive lands as security utility.

---

## What this proof claims

The supply chain is a real, expensive, ongoing security battle.
SolarWinds (Dec 2020), Codecov (April 2021), event-stream (Nov 2018),
ua-parser-js (Oct 2021), `colors`/`faker` (Jan 2022), 3CX (March 2023),
xz-utils (March 2024) — each was a different shape of the same
problem. This proof demonstrates the substrate's Receipt primitive
catches each of those shapes, with the test list mapped to named
attack classes:

| # | Test | Attack class | What we detect |
|---|------|--------------|----------------|
| T1 | happy-path | (control) | Honest publish + consumer verify |
| T2 | registry-tampering | **CWE-345** (insufficient verification of data authenticity) | Adversary swaps a published manifest in the registry post-publish |
| T3 | dependency-confusion | **CWE-1357** (reliance on insufficiently trustworthy component) | Typosquat / lookalike-name attack — content-addressing makes V-pinned consumers immune |
| T4 | backdoor-injection | **CWE-506** (embedded malicious code) — *SolarWinds class* | Compromised build pipeline ships an artifact whose manifest doesn't match the publisher's intended source |
| T5 | silent-version-drift | (lockfile bypass) | Adversarial registry returns a different version's manifest in response to a V-pinned request |
| T6 | reproducible-builds | (industry initiative) | Two independent builders, same inputs, byte-equal V — reproducibility cryptographically anchored, not belief-based |
| T7 | release-order-audit | (transparency log) | Journal preserves chronological order; cross-version swaps detected at audit time |

Each deftest passes. Each test exercises the substrate's
proof-of-computation property in a distinct application shape.

---

## A — The threat model

### In scope

The substrate's Receipt primitive provides:

1. **Manifest-binding tamper detection.** A publisher's Receipt
   commits to a specific manifest form. Any post-publish swap of
   the manifest (in the registry, in transit, on the consumer's
   disk before verification) breaks the binding — verification
   against the swapped manifest fails.

2. **Content-addressed lookup.** Packages indexed by V (the
   substrate-anchored content fingerprint), not by name+version.
   Consumers who pin by V cannot be redirected to a typosquat or
   lookalike — different content always produces different V.

3. **Reproducibility.** V is a deterministic function of
   `(form, seed)`. Same form + same seed → same V, byte-for-byte.
   Independent builders converge cryptographically.

4. **Transparency log.** A Journal of Receipts is an ordered audit
   trail; out-of-order swaps are detected at audit; the position
   is part of the published statement.

### Out of scope

The substrate is a *primitive*, not a system. Real deployment
requires composition with:

- **Key rotation.** The seed is config-time; production needs key
  management above the substrate (HSM, KMS, etc.).
- **Revocation.** No mechanism marks a Receipt invalid post-issue.
  An external revocation service composes with the substrate.
- **Time-stamping.** Receipts prove "I knew this when I revealed it",
  not "at 14:32 UTC". An external timestamp authority anchors the
  temporal claim.
- **Network-level attacks.** We assume bytes can be fetched. How
  the bytes get there (TLS, BGP, certificate transparency) is
  orthogonal.
- **Side-channel resistance.** Standard cryptographic primitives
  apply at the transport / storage layer.

This is the same scope discipline real cryptographic primitives
carry. AES doesn't claim to do key management; this substrate
doesn't claim to do consensus.

---

## B — Domain types (single file, single experiment)

```
:exp::Receipt          unit primitive (from proof 005)
:exp::Release          (name, version, manifest-form, receipt)
:exp::PackageRegistry  HashMap<hex(V), Release> — content-addressed
:exp::ReleaseJournal   Vec<Release> — ordered audit trail
```

Verbs:

```
:exp::release          (name, version, manifest, seed) → Release
:exp::publish          (registry, release) → registry'
:exp::fetch            (registry, V_bytes) → Option<Release>
:exp::record           (journal, release) → journal'
:exp::install-verify   (release, expected-manifest) → bool
```

Each verb names exactly the operation a real package manager
performs. `publish` what `npm publish` does (anchored cryptographically);
`install-verify` is what `npm install` should do but doesn't (verify
a fetched package's Receipt against the lockfile-pinned manifest).

---

## C — The seven tests, narrated for security review

### T1 — Happy path
The npm install that doesn't get attacked. Maintainer publishes
`pkg-foo@1.0.0`; Registry stores under V; consumer fetches by V
(the lockfile's content key) and verifies the Receipt against
their expected manifest. ✓

### T2 — Registry tampering (CWE-345)
*Real-world parallel: malicious mirror servers; compromised
package registries; CDN tampering.*

The adversary has write access to the registry. They replace
`pkg-foo`'s manifest field with a backdoored version, leaving the
original Receipt untouched (hoping the unchanged Receipt still
vouches for the new content).

The Receipt's `bytes` field encodes the **original** manifest's
form. Consumer's `install-verify` against the swapped manifest
fails because the substrate re-encodes the swapped manifest under
the same seed and gets a different V. The bytes don't lie about
what they were issued against.

✓ Adversary cannot rewrite history without invalidating the
binding.

### T3 — Dependency confusion / typosquat (CWE-1357)
*Real-world parallel: `evel` for `eval`, `pyt0n-requests`, npm
`event-stream`'s flatmap-stream injection, the 2021 npm
namespace-squatting wave.*

Attacker publishes a confusingly-named package. Both legit and
typosquat end up in the registry. The substrate's content-
addressing splits them at the V level — different manifest content
produces different V_bytes, no key collision.

A consumer who pins by V (the substrate-anchored content key)
fetches the legit Release; the typosquat is invisible to V-keyed
lookups for the legit V. Lookalike Unicode in the human-readable
name doesn't propagate to the substrate's content fingerprint.

✓ Content-addressing makes V-pinned consumers immune.

### T4 — Backdoor injection / SolarWinds class (CWE-506)
*Real-world parallel: SolarWinds ORION SUNBURST (2020); xz-utils
backdoor (2024); event-stream's flatmap-stream (2018).*

The maintainer's intended manifest is M_legit (visible in the
public source repository). The attacker compromises the build
pipeline; the pipeline ships an artifact whose actual manifest is
M_backdoored (with malicious dep injected) and issues the Receipt
against M_backdoored.

The consumer holds an out-of-band-trusted version of the manifest
(reproduced from source review, attested by the publisher's
public key, etc.). Verifying the published Receipt against M_legit
fails — the Receipt's bytes encode M_backdoored, not M_legit.

✓ Catches the supply-chain compromise IF the consumer holds a
trusted manifest from another channel. The substrate gives the
verification primitive; the publisher attestation layer composes
above.

### T5 — Silent version drift
*Real-world parallel: `npm install` without `--frozen-lockfile`;
auto-bumps in CI; minor-version typo letting a major upgrade slip.*

Consumer pinned to 1.0.0 by V in their lockfile. An adversarial
(or misconfigured) registry returns 1.0.1's Release in response.
Consumer verifies: 1.0.1's Receipt against 1.0.0's expected manifest.
Verification fails — the V in the lockfile is 1.0.0's V; the
Release's Receipt bytes are 1.0.1's V; the geometric primitive
detects the mismatch.

✓ V-pinning is enforceable at the verification step. Silent drift
cannot pass.

### T6 — Reproducible builds
*Real-world parallel: Debian Reproducible Builds project; Bazel's
hermetic builds; the multi-decade industry effort to make builds
deterministic.*

Two independent builders — different machines, different networks,
same manifest, same seed. Each issues their own Receipt. The
Receipts' bytes are byte-equal.

This is reproducibility cryptographically anchored: the V is a
deterministic function of `(form, seed)` only. If two builders
disagree, the substrate immediately says so — no claim of
reproducibility goes unverified.

✓ Reproducibility is a substrate-level invariant.

### T7 — Release order audit
*Real-world parallel: Sigstore's Rekor transparency log; npm's
public publish history; certificate transparency logs.*

The maintainer's Journal records releases in chronological order.
Auditor walks the Journal: `entry-at(0)` is 1.0.0, `entry-at(2)` is
1.1.0; each entry's Receipt verifies against its own claimed
manifest. A cross-version swap (asserting `entry-at(0)` should
verify against 1.1.0's manifest) is rejected — the position-binding
is part of the audit.

✓ The Journal IS a transparency log, locally. No external service
required for the cryptographic part.

---

## D — Numbers

- **7 tests passing**, 0 failing
- **Total runtime**: 29ms across all 7
- **Per-test**: 2-3ms each (in-process)
- **Zero substrate arcs shipped** in support
- **Single file**: 412 lines (helpers + 7 deftests + threat model)
- **No regressions** in any wat-rs or holon-lab-trading test suite

---

## E — The thread

- Proof 001 — the machine runs (Q1 2026)
- Proof 002 — thinker baseline
- Proof 003 — thinker significance
- Proof 004 — directed evaluation (the substrate proves computation)
- Proof 005 — receipts (generic utility on top of proof 004)
- **Proof 006 — supply chain (this file) — utility lands as security**

Proof 005 demonstrated the *shape*. Proof 006 demonstrates the
*application* — picks a domain everyone has heard of, names the
attacks everyone has heard of, and shows the primitive catches
each one.

---

## F — What this enables next

After proof 006 ships:

- **AI output provenance** — the next domain. A Receipt of
  `(prompt, model-version, system-state)` lets a consumer verify
  "this LLM response came from THIS model with THIS context."
  Hallucination disputes, prompt injection forensics, regulatory
  compliance for AI-generated content. The legal/compliance world
  is screaming for this in 2026.
- **Receipt-typed channels** — kernel queue/topic primitives
  carrying Receipts directly; only receipt-validated messages
  enter downstream state. CSP + cryptographic verification in one
  pipeline.
- **Distributed registries** — multiple wat-vm instances on the
  same seed exchange Receipts as bytes; content-addressed lookup
  works across the network without consensus.
- **Treasury audit-log** — the trading lab's treasury pre-commits
  decisions as Receipts in a Journal; reveals manifests at
  settlement; proves decisions predated outcomes. (Deferred — lab
  domain, post-substrate-stabilization.)

---

## G — Honest about what's NOT built

The supply chain is a SYSTEMS problem. This proof addresses one
piece — the cryptographic primitive that makes manifest-binding
verifiable. Real deployment needs everything else too:

- **Publisher attestation layer** — out-of-band verification that
  the maintainer's seed actually corresponds to the maintainer
  (their public key, their signed manifest, their identity-proven
  cryptographic credentials).
- **Distribution network** — getting bytes to consumers. CDNs,
  mirroring, redundancy, censorship resistance.
- **Lockfile generation tools** — capturing V's at install time
  into a format the package manager understands.
- **CI integration** — running `install-verify` in build pipelines;
  failing builds when verification fails.
- **Revocation infrastructure** — when a published Receipt was
  issued in error or under compromised credentials.
- **User experience** — making this all not feel like cryptographic
  hairshirt-wearing.

The substrate provides the verifiable primitive. The system above
it is design + product + operations work, not substrate work. We
have the foundation. We have not built the building.

That's the right scope discipline. Each layer does what it does;
none claims more than it delivers.

PERSEVERARE.
