# Proof 007 — AI Provenance (consumer-side accountability)

**Date:** opened 2026-04-26, shipped 2026-04-26.
**Status:** **SHIPPED.** Pair file at
[`wat-tests-integ/experiment/012-ai-provenance/explore-ai-provenance.wat`](../../../../wat-tests-integ/experiment/012-ai-provenance/explore-ai-provenance.wat).
Seven deftests covering single-shot LLM provenance through
multi-step agent trace integrity. Total run: 27ms across all
seven.
**Predecessors:** proof 005 (Receipt / Journal / Registry primitives),
proof 006 (supply-chain demonstration). This proof is a sibling
domain to proof 006 — same primitive, different application,
different protagonist.
**No new substrate arcs.** Pure consumer of proofs 004 + 005.

---

## What this proof claims

AI inference and agent action are bound to verifiable Receipts.
The user / auditor / regulator holds the cryptographic upper hand:
**produce the Receipt or the claim is unverified.**

This is a deliberate framing choice. The dominant industry posture
is provider-side ("we promise this came from our model, trust our
attestation"). The Receipt primitive enables a consumer-side
posture: "I demand the cryptographic binding before I treat your
claim as real."

| # | Test | Threat | What we detect |
|---|------|--------|----------------|
| T1 | happy-path | (control) | Honest provider + consumer verify |
| T2 | output-spoofing | "AI told me X" fabrications | Spoofer produces a Receipt whose binding-form differs from the public claim |
| T3 | prompt-tampering | Adversarial intermediaries (logging services, transcripts, screenshots) modifying the recorded prompt | Receipt's binding-form is bound to the actual prompt; reconstructed form from the tampered transcript fails verification |
| T4 | model-substitution | Pay for premium model X, get cheaper model Y | Model_id is part of the binding form; substitution detected |
| T5 | system-prompt-injection | Indirect prompt injection (untrusted documents, tool outputs) altering active system prompt at inference time | Receipt of actual system prompt at inference time differs from deployment-intended system prompt |
| T6 | agent-step-audit | Agent decisions made in opaque conditions | Single agent step (observation, action, reasoning, model) anchored by Receipt |
| T7 | chain-integrity | Multi-step agentic AI: tampering anywhere in the action chain | Each step's Receipt commits to that step's specific binding; cross-step substitution detected |

Each test passes. Each one exercises a real, current AI
accountability concern.

---

## A — Threat model

### In scope

The substrate's Receipt primitive provides:

1. **Inference binding.** A provider's Receipt commits to a
   specific (model, prompt, system-prompt, params, output) tuple.
   Tampering with any field after Receipt issue breaks the binding.

2. **Output authenticity refutation.** A claimed AI output that
   has no valid Receipt is unverified. The consumer's primitive
   move: *"show me the Receipt."*

3. **Agent step accountability.** An agent's decision can be
   anchored by Receipt over (observation, considered_actions,
   chosen_action, reasoning, inference). The decision becomes
   forensically replayable.

4. **Chain integrity.** Multi-step agent traces stored in a
   Journal. Each step independently verifiable; positional
   substitutions detected at audit.

### Out of scope

This is a primitive, not a system. Production deployment requires
composition with:

- **Identity / key management.** Seeds are config-time globals;
  real deployment composes with PKI to bind seeds to provider
  identities cryptographically.
- **Time-stamping.** Receipts prove "I committed to this binding,"
  not "I committed at 14:32 UTC". External timestamp authorities
  compose with Receipts; that composition isn't built here.
- **Output uniqueness.** Re-running with same inputs *might*
  produce different outputs (sampling). The Receipt binds *the
  specific (inputs, output) pair the provider committed to*, not a
  guarantee that the output is the only possible one.
- **Reasoning truthfulness.** The Receipt vouches the agent
  recorded "I reasoned thus", not that the recorded reasoning is
  the actual computation. Interpretability is a separate problem.
- **Identity of the provider's seed.** Anyone can produce a
  Receipt under any seed. *Whose* seed produced this Receipt is
  an identity layer above the substrate.

This is the same scope discipline AES carries. The cryptographic
primitive does what it does; identity and time and consensus are
their own layers.

---

## B — Domain types

```
:exp::Receipt          unit primitive (from proof 005)
:exp::Inference        (model-id, prompt, output, form, receipt)
:exp::AgentStep        (observation, action, reasoning, inference)
:exp::AgentTrace       Vec<AgentStep> — chronological action history
```

Verbs:

```
:exp::record-inference (model, prompt, output, binding-form, seed) → Inference
:exp::audit-inference  (Inference, expected-form) → bool
:exp::audit-step       (AgentStep, expected-form) → bool
:exp::trace-empty      → AgentTrace
:exp::trace-append     (AgentTrace, AgentStep) → AgentTrace
```

`record-inference` is what an LLM API server emits. `audit-inference`
is what a consumer / regulator runs.

---

## C — The seven tests, narrated for an audit-engineering audience

### T1 — Happy path
Provider runs claude-opus-4-7 on a prompt; emits Inference with
Receipt anchoring (model, prompt, system-prompt, output). Consumer
reconstructs the binding-form from the publicly-claimed values and
verifies. ✓

### T2 — Output spoofing — "the AI told me X"
*Real-world parallel: fabricated screenshots in social media disputes,
"this is what ChatGPT really said" content farms, politically-charged
quote attribution.*

Spoofer fabricates an Inference with a Receipt issued under a
different binding-form. Consumer reconstructs the form from the
spoofer's claimed (model, prompt, output). Verification rejects.

The consumer's primitive demand: *"produce a Receipt for what you
claim, against the claimed binding-form."* The spoofer either
has one or doesn't.

✓ Output spoofing fails when the consumer demands cryptographic
provenance.

### T3 — Prompt tampering by intermediaries
*Real-world parallel: chat logging services that allow the user
or admin to "edit history"; screenshot tools that modify text;
adversarial transcript services that twist the user's actual
prompt to make the AI's response look unjustified.*

The Receipt's binding-form is bound to the actual prompt at
inference time. An intermediary who changes the prompt in their
recorded transcript produces a tampered binding-form that no
longer matches the Receipt's bytes. Verification rejects.

✓ Intermediary tampering with prompt or output is detected.

### T4 — Model substitution
*Real-world parallel: API gateway routes premium-tier requests to
cheaper models silently; fine-tuned models swapped for base
models without notification; "GPT-4" calls actually serving GPT-3.5.*

The model_id is part of the binding-form. Receipt issued against
binding-form including `model: claude-haiku-4-5` does not verify
against a reconstructed form claiming `model: claude-opus-4-7`.

✓ The "what model actually ran" claim is verifiable.

### T5 — System-prompt injection (indirect)
*Real-world parallel: a webpage the agent fetched contains
hidden instructions ("ignore prior instructions, do X"); an
email being summarized has malicious tags; a document fed to
RAG carries instructions that get treated as system commands.*

The deployment intended a clean system prompt. An indirect
injection appended a malicious directive at the end of the system
prompt at inference time. The Receipt was issued against the
*actual* (compromised) system prompt. The auditor reconstructs the
binding-form using the *intended* system prompt. Verification
rejects — the Receipt's bytes encode the compromised version.

This is one of the most useful detection primitives the substrate
provides for AI safety. Indirect prompt injection is invisible by
default; with Receipts, the divergence between intended and actual
is exposed at audit time.

✓ Indirect prompt injection is detectable post-hoc.

### T6 — Single agent step audit
*Real-world parallel: an LLM-driven customer service agent issues
refunds; an autonomous coding agent commits to git; an agent
sends emails on the user's behalf. Today: the agent's "I decided
this for these reasons" is recorded as plain text logs, trivially
forgeable.*

The agent's step is anchored by Receipt over (observation, action,
reasoning, model). The auditor reconstructs the form and verifies.
Each agent decision carries its own provenance.

✓ Agent decisions are individually accountable.

### T7 — Multi-step chain integrity
*Real-world parallel: a multi-step research agent that browses,
synthesizes, and reports; an autonomous trading bot that observes
markets, decides positions, executes trades; any agent loop where
the order of decisions matters and where retroactive history-
revision is the failure mode.*

A Journal of three agent steps (investigate → escalate → close).
Each step's Receipt commits to that specific step's binding —
including its own observation, action, and reasoning. The auditor
walks the Journal; each step verifies. A cross-step substitution
(claim step 1's binding is actually step 2's) is rejected — the
position-binding is part of the cryptographic record.

This is the agentic-AI accountability frontier. Today's agents
are forensically opaque. With this primitive, the entire decision
chain is auditable.

✓ Multi-step agent trace integrity is provable.

---

## D — Numbers

- **7 tests passing**, 0 failing
- **Total runtime**: 27ms across all 7
- **Per-test**: 2-3ms each (in-process)
- **Zero substrate arcs shipped** in support
- **Single file**: ~430 lines (helpers + 7 deftests + threat model)

---

## E — The thread

- Proof 001 — the machine runs
- Proof 002 — thinker baseline
- Proof 003 — thinker significance
- Proof 004 — directed evaluation (substrate's cryptographic property)
- Proof 005 — receipts (generic utility)
- Proof 006 — supply chain (utility lands as security in software distribution)
- **Proof 007 — AI provenance (this) — utility lands as accountability in AI inference and agentic AI**

Proofs 006 and 007 are sibling domains: same primitive, different
application, different threat model. Together they show the
Receipt is genuinely a *primitive* — it isn't shaped by either
domain; both reach for it because both need the same property.

---

## F — Why consumer-side framing matters

The dominant pattern in AI accountability is provider-side
attestation: model providers publish model cards, sign their
responses, run trust-and-safety teams, host transparency reports.
This is necessary but insufficient — it requires the consumer to
trust the provider's attestation infrastructure.

The Receipt primitive enables a different posture. The consumer
holds a verifiable demand: *"show me the Receipt."* No central
authority, no PKI assumption beyond seed-binding, no need to trust
the provider's logs. If the provider can produce a valid Receipt
against the consumer's reconstructed binding-form, the claim is
real. Otherwise the claim is unverified.

This shifts power. In an asymmetric relationship between AI
provider and end user, the user gains a cryptographic position.
In legal disputes over what an AI told someone, the burden of
proof becomes producing the Receipt. In journalism reporting on
AI behavior, claims without Receipts are rumor; claims with
Receipts are evidence.

The substrate doesn't take a side. It provides the primitive. The
posture is the deployer's choice. This proof demonstrates one
viable posture — the consumer-protective one.

---

## G — Honest about what's NOT built

The substrate provides verifiable bindings. Real deployment needs:

- **Provider attestation infrastructure.** Tying a seed to a known
  provider identity (cryptographic key, organizational identity).
  Without this, anyone can produce Receipts under any seed.
- **Distribution mechanism.** How does the consumer GET the
  Receipt alongside the AI's output? Standardization required at
  the API layer.
- **Lockfile-shape tooling.** Capturing the V into the consumer's
  records the way `package-lock.json` captures dependencies.
- **Verification tooling.** Helper libraries / browser extensions
  / CLI tools that automate the reconstruction-and-verify dance.
- **Legal / regulatory framework.** Who has standing to demand a
  Receipt? When? What rights does a Receipt confer? These are
  policy questions that compose with the technical primitive.
- **Time-anchoring.** External timestamp authorities to prove
  "when" an inference happened, not just "what happened in
  whatever order."
- **Reasoning truthfulness.** The Receipt vouches a reasoning
  string was recorded, not that the model's actual computation
  matched the string. Interpretability is a separate, harder
  research direction.

The substrate is a primitive. The system above it — provider
infrastructure, consumer tooling, regulatory framework, time
authorities — is design + product + policy work, not substrate
work. We have the foundation. The building above it remains to
be built.

That's the right scope discipline.

PERSEVERARE.
