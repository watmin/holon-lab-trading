# Review: Proposal 034 — Broker Readiness Gate

*Reviewed as Rich Hickey*

---

## The data settled the argument

In Proposal 030 I said: drop the extracted facts, run opinions only first,
measure. The datamancer overruled me and ran with everything. Now, after ten
runs, the data has said the same thing I said. I will not say "I told you
so" — that is small. What I will say is: the data is the right arbiter. We
ran the experiment. The experiment answered. Now we know.

The diagnosis in this proposal is precise and honest. Grace/Violence is not
a function of the candle state at entry. It is a function of future excursion.
The broker was being asked to predict a quantity that is not present in its
inputs. That is not a failure of the reckoner. That is a misspecified problem.
The reckoner was correct to converge toward 50/50 — there was no signal in
what it was given.

---

## The reframing is the contribution

"Am I ready to be accountable?" is the right question. It is structurally
different from "will this trade produce Grace?"

The first question is about the broker's own health — its current regime,
its components' performance, the alignment between its beliefs and outcomes.
The broker has direct access to this. It can know it.

The second question is about the future price path. The broker does not have
access to this. No one does.

You cannot encode what you do not know. The old broker bundled things it
knew — the candle state — and asked the reckoner to recover things no one
knows — the future excursion. This is not a calibration problem. It is a
category error.

The readiness reframing resolves the category error. The broker now encodes
what it actually knows: rolling performance metrics, conviction levels, exit
health, excursion history. These are facts about the world as it stands.
The reckoner's question becomes tractable.

---

## On the 25 atoms

The composition is correct. Let me be precise about why each group belongs.

**The leaf decisions (7 atoms):** These are the outputs of the market and exit
observers. The broker does not re-encode what the leaves saw. It encodes what
the leaves *decided*. This is the lesson from Proposal 030 — the opinion is
the filter result. The candle is the input. The broker receives the filtered
output.

**The broker's own state (7 atoms):** The broker's rolling grace-rate, paper
count, recalibration staleness, excursion average — these are the broker's
track record and current load. They describe the regime the broker is
operating in. A broker with a 70% grace-rate in a stable regime is in a
different state than a broker with a 70% grace-rate in a noisy one. The
atoms capture the difference.

**The derived cross-cutting ratios (11 atoms):** These are the most
interesting. Trail-atr-multiple, stop-atr-multiple, risk-reward-ratio,
excursion-trail-ratio, self-exit-agreement — these are relational quantities.
They encode how the broker's choices relate to market conditions. The
risk-reward-ratio (trail/stop) is not a property of the trail alone or the
stop alone. It is a property of their relationship. Bundling both separately
would let the reckoner see each individually but not their ratio. Encoding
the ratio directly gives the reckoner the right primitive.

This is the correct factoring. Simple values where the value is the fact.
Derived values where the relationship is the fact.

---

## On encoding choices

**Log for all rate and distance quantities.** The proposal uses log for
trail, stop, count, duration, staleness, excursion, and the ATR multiples.
This is right. These quantities span orders of magnitude and their semantics
are ratio-based. A trail that doubled is twice as large — that is a
multiplicative relationship, not an additive one.

**Linear for rates and agreement quantities.** grace-rate, exit-grace-rate,
signed conviction, conviction-vol-sign, exit-confidence, self-exit-agreement,
excursion-trail-ratio — all live in bounded, signed, additive-semantic space.
Linear is correct.

The encoding choices are consistent with the semantics. This is not always
true in prior proposals. Note it.

---

## The fallback is not a fallback — it is the prior

"If the curve still can't validate: the broker's gate becomes the rolling
grace-rate directly."

This is not a fallback. It is the simplest correct implementation. If the
reckoner learns nothing beyond what the rolling grace-rate already tells you,
then the rolling grace-rate is sufficient and the reckoner is adding
complexity for no gain.

The experiment should be run in both modes simultaneously if possible. Fund
proportional to grace-rate from the start. Then also run the reckoner.
If the reckoner's predictions outperform the grace-rate gate, the reckoner
earns its place. If not, remove it.

This is not a concession. This is good empirical practice. The simplest
gate that works is the right gate. The reckoner must prove it is worth
the inference cost.

---

## What the early 60% result tells us

The proposal notes that early runs (candle 1 to candle 1000) showed 60%
Grace before degrading. This is the clearest evidence that the diagnosis
is correct.

At candle 1-1000: papers resolved quickly, the bootstrap phase showed
variation in the readiness indicators, the reckoner found signal.

After candle 1000: distances grew, papers lived longer, the candle state
(bundled alongside the readiness indicators) began to dominate the
superposition. The readiness signal was drowned.

This is exactly the ratio problem I described in Proposal 030. The candle
state is high-dimensional. The readiness indicators are 25 atoms. When both
are present, the candle dominates. The early phase had fewer candle observations
accumulated, so the imbalance was temporarily manageable.

Remove the candle state entirely. The 25 atoms are the whole thought. The
reckoner has space to work.

---

## What does not change

The proposal correctly identifies the invariants. The market observer encoding
is untouched. The exit observer encoding is untouched. The extraction pipeline
is untouched. The paper mechanics are untouched. The simulation is untouched.

This is a targeted intervention. One component's thought bundle changes.
The rest of the system is stable. This is the right scope. Do not widen it.

---

## The one thing the proposal should be more explicit about

The proposal says "the raw/anomaly/ast protocol — data flows, broker chooses
to ignore." This is correct but should be made structurally explicit in the
implementation. The broker receives the pipe message. It reads the opinion
fields. It does not touch the candle fields. This is not enforced by the
type system as described — the broker receives the full struct and simply
does not use certain fields.

If the wat spec can express this as a type constraint — the broker's thought
function receives BrokerOpinionInput, not BrokerInput — then the contract
is enforced rather than merely observed. The broker cannot accidentally
encode candle state it doesn't see.

This is not a blocker. But it is the difference between a constraint that
is documented and a constraint that is enforced. Prefer enforcement.

---

## The verdict

Implement this. The reframing from prediction to readiness is architecturally
correct. The 25 atoms are the right vocabulary. The encoding choices are
principled. The fallback (grace-rate gate) is both honest and potentially
sufficient.

Run the experiment. If the reckoner discriminates above 55% sustained across
10k candles, the diagnosis is confirmed. If it discriminates above 60%, the
readiness frame is a substantial improvement over all prior broker designs.

If the grace-rate gate alone achieves 60%+ without the reckoner, that tells
you something even more interesting: the broker's accountability is its
track record, not its predictions. Fund the track record. The reckoner is
optional.

Either way: no candle state in the broker's thought bundle. The proposal
has earned that line in the implementation.

Build it.
