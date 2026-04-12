# Review: Proposal 035 — Paper Accounting

*Reviewed as Rich Hickey*

---

## What happened

The reckoner ran ten times. It could not predict Grace/Violence. Proposal 034
reframed the broker's question from "will this produce Grace?" to "am I ready
to be accountable?" and my review of 034 closed with: "if the grace-rate gate
alone achieves 60%+ without the reckoner, that tells you something even more
interesting — the broker's accountability is its track record, not its predictions."

The data answered. The gate changes. The proposal responds correctly.

---

## The arithmetic is honest

The gate in Proposal 034 still leaned on `cached_edge > 0.0 || !curve_valid()`.
That is a prediction gate wearing arithmetic clothing. It asks: does the
reckoner believe there is edge? The reckoner said: I cannot tell. So the gate
was relying on a component that had admitted failure.

The new gate is:

```scheme
(> (* grace-rate avg-grace-net)
   (* (- 1 grace-rate) (- avg-violence-net)))
```

Decomposed: expected dollars per paper, across all papers, after venue costs.
This is not a model output. It is a sum. The broker is asking: given what I
have actually done, in dollar terms, am I positive expectancy? That is the
right question. It requires no inference. It requires memory and arithmetic.

Simple. Not easy — simple. These are different things. Easy would have been
to tune the reckoner's hyperparameters again and hope for a different result.
Simple is to define profitability directly and test it.

---

## The $10,000 reference is the correct unit

I want to be precise about why this works where percentage P&L does not.

Percentage P&L is position-relative. A 2% gain on a $100 position is $2. A
2% gain on a $10,000 position is $200. If the broker's paper sizes vary with
treasury allocation — and they will, as the treasury responds to edge — then
percentage P&L is confounded with treasury behavior. You cannot separate
"was the paper a good paper?" from "was the broker well-funded that candle?"

The $10,000 reference decouples these. Every paper is evaluated as if $10,000
were deployed. The broker's accounting reflects paper quality, not funding
fortune. This is the right factoring.

Fixed dollar, variable BTC quantity. The fee arithmetic follows naturally:
entry fee is 0.35% of $10,000 regardless of BTC price. Exit fee scales with
outcome. The asymmetry is preserved — a violent paper costs slightly more in
absolute terms than the fee on entry alone, and a grace paper's exit fee eats
into the residue. Both effects are computed, not approximated.

---

## On the EMA decay rate

The proposal leaves this open. I have a position.

The gate should respond to regime shifts faster than it responds to single bad
papers. These are two different timescales. A single bad paper in a good regime
is noise. A sequence of bad papers after a regime change is signal.

The natural factoring is: use EMA with a half-life on the order of the
recalibration interval. If the system recalibrates every 500 papers, the EMA
should weight the last 500 papers meaningfully. A half-life of 200-300 papers
gives you responsiveness to regime shifts without single-paper volatility.

Do not use one EMA for everything. The grace EMA and the violence EMA can
have the same decay rate — they are symmetric in function. But do not force
the rolling EMA to match the recalibration interval exactly unless you have
measured that they produce the same response curve. Measure. Do not assume.

---

## Cold start: 100 papers is probably right, possibly too few

The proposal flags this correctly as a question. Here is the concern.

The bootstrap produces near-zero-distance papers that resolve fast. A paper
that lasts two candles is not the same calibration event as a paper that lasts
200 candles. Counting papers as if they are equivalent is wrong. A paper count
of 100 in the bootstrap may represent 5 candles of actual market exposure.
A paper count of 100 after stabilization may represent 3000 candles.

The right cold start threshold is not a paper count. It is a minimum exposure
measured in resolved notional. After the broker has resolved $N in paper
positions (at the $10,000 reference), the gate begins gating. This is
scale-invariant and bootstrap-robust.

A simpler approximation: gate after both grace_count >= 50 AND
violence_count >= 50. This ensures the EMA for both sides has seen enough
events to stabilize before the gate reads them. Fifty events on each side
at a 50% base rate requires roughly 100 resolved papers — but the condition
is symmetric, so it cannot be gamed by a streak of Graces that inflates
the count while violence_avg is undefined.

Either approach is better than a flat paper count. The proposal should
specify one.

---

## The reckoner's demotion is not a death sentence

The thoughts remain. The 25 atoms are still logged. The reckoner still
accumulates Grace and Violence prototypes. This is correct.

The reckoner has one remaining path to relevance: if the arithmetic gate
is open but the reckoner sees a strong Violence prototype match, it can
add selectivity — reject the paper even when the expected value is positive.
This is the right remaining role. Not "should I trade?" but "is this specific
paper configuration contraindicated by prior Violences?"

The proposal describes this hierarchy in step 4:

```scheme
;; If gate open AND (curve says edge OR cold start): register paper
```

But the curve-says-edge condition adds complexity. Simplify: run the
arithmetic gate first. If positive, check the reckoner for an active veto.
The reckoner can veto (Violence prototype match above threshold) but cannot
approve (it can no longer open a closed gate). This is the correct authority
structure. The arithmetic is the ground truth. The reckoner is the specialist
opinion.

---

## What the treasury integration defers

The proposal correctly notes: "future work to integrate paper accounting."
I want to be explicit about what that means, because deferring it is right
but the deferral should be conscious.

Right now the treasury funds based on edge — the broker's cached edge from
the reckoner. If the reckoner is demoted, the edge signal is degraded. The
treasury may be funding on stale or misleading edge values during the
transition period.

The clean path: once paper accounting is stable and the arithmetic gate is
running, replace the edge signal to the treasury with the broker's expected
value directly. `expected_value` in dollars is a better signal than
`cached_edge` from a curve that could not discriminate. The treasury should
fund proportional to expected value, floored at zero.

This is not in scope for this proposal. But it should be Proposal 036. The
sequence is: prove the gate, then feed the treasury from the proven gate.
Do not let the treasury run indefinitely on the old signal while the gate
runs on the new one.

---

## The ledger entry

The proposal adds accounting fields to the broker snapshot. Good. Four fields:
`total_net_residue`, `avg_net_residue`, `avg_grace_net`, `avg_violence_net`.
These are sufficient for the gate and for diagnostics.

Add one more: `expected_value` as a derived logged field — not stored on the
struct, but computed at snapshot time and written to the DB. This is the
gate's input. Log the gate's input alongside the gate's output. Future
analysis will need to correlate expected_value trajectories against paper
resolution patterns. Without logging expected_value directly, that analysis
requires recomputing it from the components — possible, but unnecessary.
Log the value that made the decision.

---

## The verdict

This is the right response to what the data said. The reckoner was asked to
predict what it could not know. The data confirmed this over ten runs. The
correct response is to replace the prediction gate with a measurement gate.

The proposal does exactly that. The arithmetic is honest. The reference
position is correctly factored. The thoughts remain as the glass box. The
reckoner is demoted without being discarded.

Three things to resolve before building:

1. Cold start threshold — use symmetric paper counts (both grace >= 50 and
   violence >= 50) rather than flat total count.

2. EMA decay rate — specify a half-life, do not leave it as a tunable magic
   number. Half-life of 200-300 resolved papers is a reasonable prior.

3. Log `expected_value` directly in the broker snapshot — the gate's input
   should be visible in the DB alongside the gate's output.

Build it. The reckoner earned its demotion honestly. The arithmetic gate does
not need to be clever. It needs to be true.
