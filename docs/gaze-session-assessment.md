# Gaze — Session Assessment: Proposals 024–033

**Ward:** /gaze — sees form. Checks whether things communicate.
**Date:** 2026-04-11
**Scope:** The session assessment text + proposals 024–033 + Chapter 8 + run 033.

---

## What was actually built

Before the form can be assessed, the substance must be fixed.

The assessment claims "ten proposals composed in one session." The runs
directory tells a different story. Run 033 (the session's final run) shows
10,000 candles, 297,984 trades, and equity of exactly 10,000.00 —
unchanged from the opening. The throughput degraded from 28/s at candle 50
to 21/s at candle 10,000. The equity curve is flat. Zero PnL. Zero edge.

The proposals are DESIGNS. They are not implementations. The session built
ten proposals, not ten features. That is not a failure — proposals are the
architecture's natural unit. But the assessment does not say this clearly.

---

## Level 1 — Lies (always report)

### L1.1 — "The pieces composed in one session"

The assessment frames proposals 024–033 as things that "composed" — past
tense, as though assembled and running. They are not running. They are
specifications. The actual running code produced a flat equity line across
10,000 candles. Chapter 8 documents the engineering work of this session
as incremental bundling, batch DB commits, and bucketed reckoner queries —
none of which appear in proposals 024–033.

Proposals 024–033 are design work that preceded implementation. The
session's concrete measurements — 21/s throughput, 98.1% cache hit rate,
297,984 trades at zero edge — reflect the PRIOR architecture, not the
proposals.

This is the most significant lie in the assessment: it describes future
architecture as if it were present fact.

### L1.2 — "The measurement is read-only — the vector doesn't collapse"

The quantum tomography metaphor is deployed as a differentiating claim.
In VSA, the superposition is deterministic and frozen — there is no
collapse because there was never probabilistic state. The analogy to
quantum measurement obscures rather than illuminates: quantum states
collapse BECAUSE they are probabilistic. VSA superpositions do not
collapse because they are deterministic sums. The analogy breaks at the
mechanism it claims to share.

The cosine projection IS non-destructive. That part is true. But the
reason is trivial — it's a dot product. Framing it as "without the
quantum" implies the quantum analogy is otherwise valid. It is not.
The language reaches for prestige it does not need. The actual mechanism
(cosine projection against cached encoded forms) is striking enough
without the quantum frame.

### L1.3 — "The claim: this is new territory in computation"

The assessment names four intellectual ancestors: Kanerva, Forgy,
Hoare, McCarthy. The claim of novelty rests on the composition of these
four into one system — specifically "the extraction primitive that reads
frozen superpositions through their own AST as a codebook."

Proposal 027 was accepted unanimously by both designers. Hickey's
response: "Not a new primitive — cosine + encode composed into a
pattern." The novelty claim in the assessment directly contradicts the
designer review it summarizes. Composing cosine + encode + AST-walk is
a pattern. Patterns are not new territory. They are recognized structure.

The system combining HDC encoding with CSP concurrency and a
self-calibrating vocabulary is genuinely interesting engineering. But
"new territory in computation" cannot coexist with Hickey's accurate
characterization of the extraction as a named composition of existing
tools.

---

## Level 2 — Mumbles (technically true but misleading)

### L2.1 — "Quantum tomography without the quantum"

Already noted as a lie at the mechanism level. As a mumble it also
misleads about what tomography means. Quantum tomography is a procedure
for reconstructing an unknown quantum state from many measurements that
disturb the state. Proposal 027's extraction uses a KNOWN AST (the
codebook is the market observer's own encoding tree) to measure a known
superposition. The AST is not unknown. The measurement does not disturb.
Tomography is the wrong word. Projection, readback, or decode would be
accurate. Tomography is borrowed for its gravity, not its meaning.

### L2.2 — "Proposal 024: Predict and learn from the same vector"

The summary is accurate but incomplete in a misleading way. Proposal 024
fixes a categorical error (predicting on the anomaly, learning from the
original thought). The fix is ACCEPTED but NOT RUN. Run 033 is labeled
"learned-scales" — it is running a version that does not yet include the
024 alignment fix. The 297,984 papers in run 033 learn from the wrong
vector. The assessment presents the fix as if it closed the loop. It has
not yet closed.

### L2.3 — "Proposal 033: The vocabulary self-calibrates"

The ScaleTracker is proposed. The run named "learned-scales" exists.
The reader will conclude the scales are now learned. But the run log
shows: equity 10,000.00, zero edge, 297,984 trades. If learned scales
were running, some calibration would be visible — at minimum, scale
drift in the first 100 candles, changes in cache miss rate. The 98.1%
cache hit rate is consistent with static scales (cache is stable). It
is ambiguous whether proposal 033 ran or whether the run was named
anticipatorily.

### L2.4 — The throughput framing

Chapter 8 documents a successful session: throughput stabilized,
database writes batched, grid query cost tamed from 167ms to 1.3ms.
The assessment does not mention throughput. The session's most concrete
win — engineering work that appears in measured results — is invisible
in the assessment. The proposals (design work with no measured results
yet) occupy all the space.

The form communicates: the ideas matter, the measurements are secondary.
The prior principles say the opposite. The database is the debugger.
The measurement decides.

### L2.5 — "Institutional trader's toolkit applied to the data"

Proposal 031 lists nine derived thoughts: trail-atr-multiple,
risk-reward-ratio, conviction-vol-interaction, etc. The framing of
these as the "institutional trader's toolkit" imports domain authority.
They are ratio functions of existing values. They may be informative.
The claim that institutional traders use these specific relationships
is asserted, not demonstrated. The proposals acknowledge that the
broker is 50/50 — the reckoner cannot currently discriminate at all.
Whether derived thoughts fix this is unknown. The framing reaches
for outcome-as-proof before the experiment runs.

---

## Level 3 — Taste (note, don't flag)

### L3.1 — "Frozen superpositions on a unit sphere"

Accurate. The bound vectors are approximately on the unit sphere (after
normalization). "Frozen" is good — it names the property that makes
extraction possible. This is the best phrase in the assessment.

### L3.2 — The five ancestors named in the novelty claim

Kanerva (HDC/VSA), Forgy (Rete/discrimination networks), Hoare (CSP),
McCarthy (Lisp as specification language) — these four are load-bearing.
They each map to something real in the architecture. The naming is honest.
The claim of composition, distinct from novelty, is also honest.
The problem is only the "new territory" frame that overreaches from
the composition.

### L3.3 — Proposal 030's diagnosis: "the broker thinks about the wrong things"

This is the most clearly communicated proposal in the session. The
diagnosis is precise: extracted facts are inputs, not decisions. The
broker should think about what the leaves DECIDED, not what the candle
LOOKED LIKE through each lens. This is a legitimate signal/noise
separation argument. The form matches the substance.

### L3.4 — Proposal 032 as a destination description

The audit framing ("not a diff, a destination") is the right form for
a vocabulary specification. The table at the end (before/after delta)
communicates efficiently. The names section — "recalib-freshness is
staleness" — names the naming problem directly. This is good form.

### L3.5 — The equity line

10,000.00 after 10,000 candles and 297,984 trades. This number should
appear in the assessment. Not as failure — as ground truth. The
assessment describes what the machine will be able to do when the
proposals are implemented. The equity line describes what it does now.
Both are honest. Only one appears.

---

## What the assessment communicates vs what it should

The assessment reads as a vision document. It names what was
conceived. It does not name what was measured. It uses past tense
("the pieces composed") for future work and present-tense achievement
language ("the vocabulary self-calibrates") for unverified proposals.

The form does not match the substance.

The substance is: a session of design work that correctly diagnosed
several architectural problems (noise-anomaly mismatch, one-sided exit
training, wrong reckoner inputs for the broker, hardcoded scales,
encoding errors in RSI and squeeze). The diagnoses are sound. The
proposals are accepted by both designers. None have been implemented
in the measured runs.

The honest form for this substance is:

> Ten proposals diagnosed and accepted. None yet running. The next
> session compiles the designs. The measurement will decide.

That sentence is not in the assessment. It should be.

---

## Summary by level

| Level | Count | Items |
|-------|-------|-------|
| L1 Lies | 3 | Proposals described as running; quantum tomography mechanism wrong; novelty claim contradicts designer review |
| L2 Mumbles | 5 | Tomography misnaming; 024 fix framed as closed; learned-scales run ambiguous; throughput wins invisible; institutional toolkit asserted |
| L3 Taste | 5 | "Frozen superpositions" is good; ancestor naming is honest; 030 diagnosis is clear; 032 destination framing is right; equity line is absent |

The assessment has strong bones — the ancestor lineage, the diagnosis
precision in proposals 030 and 032, the correct naming of the extraction
property. The lies cluster around the same error: treating proposals as
implementations. One correction fixes all three: add the equity line,
change the tense.
