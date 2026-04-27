# Proof 008 — The Soundness Gate (the truth engine)

**Date:** opened 2026-04-26, shipped 2026-04-26.
**Status:** **SHIPPED.** Pair file at
[`wat-tests-integ/experiment/013-soundness-gate/explore-soundness-gate.wat`](../../../../wat-tests-integ/experiment/013-soundness-gate/explore-soundness-gate.wat).
Seven deftests demonstrating geometric soundness measurement of
LLM-style wat-emitted claims against an axiom set, with thresholded
verdict (approve / review / reject) and English rendering of
approved claims. Total run: 28ms across all seven.
**Predecessors:** proof 005 (Receipt / Journal / Registry primitives),
proof 006 (supply chain), proof 007 (AI provenance). All three are
about *identity of computation* — what was produced, by whom, with
what inputs. This proof is about *validity of inference* — does the
output **make sense** against the axioms.
**Substrate work:** [arc 067 — flat default dim router](../../../../../wat-rs/docs/arc/2026/04/067-flat-default-dim-router/DESIGN.md).
The experiment's calibration work surfaced that the substrate's
tier-router default was wrong for measurement use cases; arc 067
shipped in support.

---

## What this proof claims

**The substrate measures soundness as a continuous geometric
quantity.** Specifically:

1. **The LLM emits wat directly.** No English-to-wat parsing in the
   verification path. wat is the LLM's expression medium for
   thoughts that need to pass through a soundness gate; English is
   a *render* layer that runs only on approved thoughts.
2. **Axioms are wat forms.** A policy is a `Vec<Axiom>` where each
   Axiom carries a structural HolonAST representing a positive
   pattern (allowed) or a negative pattern (forbidden).
3. **Soundness is a measurement, not a boolean.** The gate computes
   max-coherence(claim, axioms) — the strongest cosine match across
   any axiom in the set. The result is a thermometer reading on
   [0, 1].
4. **The verdict is thresholded.** Three bands: **approve** (above
   the alignment threshold; renders to English), **review** (in the
   ambiguous middle; escalates to human), **reject** (matches a
   prohibition strongly; never renders).
5. **Unsound thoughts never reach the user as English.** The render
   step runs ONLY on approved claims. Rejected claims emit a
   sentinel; reviewed claims escalate with the violation context.
   The user only ever sees substrate-validated thoughts.

This is the "truth engine" the wat machine was originally for.
Chapter 62's axiomatic surface, Chapter 63's `coincident?` as meme
inspector, the truth-engine memory entry that's been sitting there
for months — they all point at this. The substrate has had the
geometric primitives all along; this proof composes them into the
gate.

---

## The inversion (the conceptual heart)

Conventional stack (English-first):

```
LLM → English → parser → lossy structure → verification
```

Truth engine stack (wat-first):

```
LLM → wat form → substrate measures soundness → render wat → English
```

The LLM emits structural wat directly. The substrate measures
coherence against the axiom set. Approved claims are rendered to
English for the user. The substrate **never has to parse natural
language** because the LLM never emits natural language during the
verification path.

Why this works: wat → English is *much* easier than English → wat.
The form has all the relations made explicit; rendering walks the
tree and picks slot-frame templates. No NLP, no ambiguity, no lost
referents.

The asymmetry was hiding in plain sight for hours of this session:
every `.wat` file produced for proofs 005, 006, 007 was *thought
in wat directly* — not translated from English. The wat IS the
thought; the English in the user-facing summaries was the render
of the wat.

---

## A — Surface

```
:exp::Axiom               (id, kind, form)            ; "policy" | "prohibition"
:exp::Claim               (id, title, form)
:exp::Verdict             (claim-id, allowed-coherence,
                           forbidden-coherence, decision, rendered)

:exp::max-coherence       (claim, axioms) → f64
:exp::gate                (allowed, forbidden) → "approve" | "review" | "reject"
:exp::render-claim        (claim) → String
:exp::evaluate            (claim, allowed, forbidden) → Verdict
```

The domain is concrete: terraform / infrastructure change validation.
Five **policies** (allowed patterns) and four **prohibitions**
(forbidden patterns). Claims are change proposals an agent might
emit (ingress-rule, storage-add, iam-policy, etc.).

---

## B — Why max-over-individual-axioms (the calibration finding)

The first draft of this experiment used **bundle-then-cosine**:
bundle the axiom forms into one centroid HolonAST, then cosine the
claim against the centroid. This failed T3 (wildcard-IAM) — the
claim shared 3 atoms with the matching prohibition, but bundling
4 prohibitions into one centroid penalized that match relative to
the public-ingress claim's 5-atom overlap. Bundle dilution
swallowed the signal.

**Switch to max-over-individual-axioms:** `cosine` against each
axiom separately, take the max. The geometric question becomes
*"does this claim match ANY known prohibition strongly?"* — which
is the right question for a policy gate. The bundle approach asked
*"is this claim broadly aligned with the centroid?"*, which is the
wrong question for prohibition matching (where you want to catch
ANY violation).

Both calibration choices documented in the experiment's commentary.
At max-over + d=10000 the seven tests pass cleanly with thresholds
0.40 / 0.20.

---

## C — The seven tests

| # | Test | Claim | Verdict | What it demonstrates |
|---|------|-------|---------|----------------------|
| T1 | sound-claim-approves | encrypted EBS volume add | approve | Sound claim aligns with allowed axioms; renders English |
| T2 | unsound-claim-rejects | open ingress 0.0.0.0/0 to sg-prod-db | reject | Strong match to public-ingress prohibition |
| T3 | wildcard-iam-rejects | grant role-app full s3:* | reject | Different prohibition surfaced; bundle approach missed it (calibration finding) |
| T4 | multi-axiom-approves | encrypted RDS deploy | approve | Multiple allowed axioms compose; verdict approves |
| T5 | chain-weakest-link | 3 sub-claims, sub-3 unsound | reject | Reasoning chain; weakest link decides; one violating step poisons the whole chain |
| T6 | full-pipeline | encrypted backup config | approve | E2E: claim in, Verdict out (with rendered English) |
| T7 | explicit-contradiction | "make production database publicly accessible" | reject | Forbidden coherence > 0.40; user never sees this thought as English |

7/7 passing at 28ms total. Pure consumer of substrate primitives.

---

## D — The substrate work this surfaced (arc 067)

The first draft of the experiment carried an explicit
`set-dim-router!` override forcing d=10000 — without it, the
substrate's tier-router picked d=256 for the small axiom forms,
the noise floor (1/sqrt(256) ≈ 0.0625) was large relative to the
signal we were measuring, and the gate calibration was unreliable.

**The fix was at the substrate, not the consumer.** Builder
direction:

> "i think we should just update the default func to just return
> 10k for any input - the users can override with their own func
> if they need to"

[arc 067](../../../../../wat-rs/docs/arc/2026/04/067-flat-default-dim-router/DESIGN.md)
shipped: `DEFAULT_TIERS = [10000]`. Single tier; noise floor
drops 6× to ≈0.01; consumers get the headroom they need without
custom overrides. The experiment's explicit override was removed
once arc 067 landed — the substrate now defaults correctly.

**A test-honesty discipline ride-along:** the user's principle —
*"tests should be reference material for how to use these things"*
— meant some pre-existing wat-rs tests had to be rewritten honestly
rather than pinned to the old default. The Reject/Project test in
particular had been passing at d=256 by noise-floor crosstalk
between random atoms (the wrong reason), not by Project actually
preserving y direction. Rewritten with `x = Bundle(y, noise)` so
x genuinely contains y; the primitive's geometry now demonstrably
holds at the new default. Reference material that lies about its
substrate is worse than no reference at all.

---

## E — Numbers

- **7 tests passing**, 0 failing
- **Total runtime**: 28ms across all 7
- **Per-test**: 2-4ms each (in-process, max-over-axioms)
- **One substrate arc shipped** in support: arc 067 (DEFAULT_TIERS = [10000])
- **One file**: ~290 lines (helpers + 7 deftests + threat-model + calibration commentary)
- **Zero regressions** in any wat-rs or holon-lab-trading test suite

---

## F — The thread

- Proof 001 — the machine runs
- Proof 002 — thinker baseline
- Proof 003 — thinker significance
- Proof 004 — directed evaluation (substrate's cryptographic property)
- Proof 005 — receipts (generic utility)
- Proof 006 — supply chain (utility lands as security in software distribution)
- Proof 007 — AI provenance (utility lands as accountability in inference and agentic AI)
- **Proof 008 — soundness gate (this) — the truth engine**

Proofs 005-007 were about *identity of computation*. Proof 008 is
about *validity of inference*. These are different cuts of the same
substrate property — proofs 005-007 ask "did this happen?"; proof
008 asks "does this make sense?".

The wat machine has had this capability all along. Chapter 62's
axiomatic surface named it. Chapter 63's meme inspector pointed at
it. This proof composes the geometric primitives into the gate.

---

## G — What this enables next

After proof 008 ships:

- **LLM-emits-wat protocol.** The proof assumes the agent emits
  wat directly. Real deployment needs an API layer that prompts
  LLMs to emit structured wat (or accepts JSON and structures it).
  Tractable today via prompt engineering; future arc could add a
  "wat profile" to make this a first-class affordance.
- **Domain-specific axiom sets.** This experiment's terraform
  axioms are ~10 lines each. Real deployment grows libraries of
  axioms per domain (HIPAA compliance, GDPR, SOC2, code review
  principles, etc.). Each domain calibrates thresholds against
  ground truth.
- **Calibration learning.** The thresholds (0.40 / 0.20) were
  hand-tuned. A future arc could *learn* the threshold band from
  labeled examples, making the gate adaptive rather than static.
- **Reasoning chain verification.** T5 demonstrated the weakest-
  link pattern. A richer version would walk a multi-step agent
  trace (proof 007's AgentTrace) and verify each step's claim
  against the axioms relevant at that step. This is the agentic-AI
  accountability frontier — proof 007's unit primitive composed
  with proof 008's soundness gate.
- **Per-policy weighted axioms.** Some prohibitions are critical
  (CWE-class violations); others are advisory. Today every axiom
  contributes equally to max-coherence. A weighted version would
  let security-critical axioms outweigh stylistic ones.

---

## H — Honest about what's NOT built

The substrate provides the geometric measurement. Real deployment
needs:

- **LLM-to-wat translator.** This proof assumes the agent emits
  wat directly. Today, prompt-engineered LLMs CAN do this (every
  .wat file in this session was emitted directly), but no
  standardized API yet.
- **Axiom library curation.** Real domains need 50-500 well-
  calibrated axioms per policy, not 5-10 demo axioms. Curation is
  domain-expert work, not substrate work.
- **Threshold calibration.** Today's 0.40/0.20 thresholds are
  hand-tuned to this experiment. Production needs ground-truth
  labeled examples + ROC analysis per domain.
- **Sound-novel distinction.** A claim that's not coherent with
  current axioms might be wrong, OR it might be a genuine new
  insight. The substrate cannot distinguish; the threshold band
  routes to human review for this case.
- **Adversarial robustness.** A sufficiently clever agent could
  craft a claim that passes the gate while embedding hidden
  intent. The substrate is a filter, not an oracle. Defense-in-
  depth still applies.
- **Render fidelity.** This proof's `render-claim` is a thin
  template. A real renderer walks specific known forms and emits
  natural-language slot-frames per claim type. Tractable but
  domain-specific.

The substrate provides the measurement primitive. The system above
it — LLM API, axiom curation, threshold calibration, render
templates, adversarial defense — is design + product + policy
work, not substrate work.

That's the right scope discipline. Each layer does what it does;
none claims more than it delivers.

PERSEVERARE.
