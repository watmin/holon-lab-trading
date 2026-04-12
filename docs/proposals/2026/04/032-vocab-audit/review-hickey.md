# Review of Proposal 032 — Rich Hickey

*Does the proposal correctly address every finding from my review?
Did it miss anything? Did it make incorrect choices? Is the target state honest?*

---

## Verdict First

The proposal addresses the most important encoding bugs and several
dead atoms. It does NOT address the duplication epidemic, which is
the most important finding in the review. It defers the architectural
duplications and then also defers many of the collinear atom
redundancies without explaining why. The target state is smaller and
more honest on encoding correctness, but it leaves the composition
geometry broken.

A vocabulary with correct encoding types but doubled atom weights is
still a corrupted geometry. The proposal corrects the type of the
corruption without eliminating it.

---

## What the Proposal Gets Right

### Encoding type fixes: addressed

RSI normalized by /100 in both oscillators.rs and exit/timing.rs.
This was finding #3 (RSI Encoding Bug). Correct.

### Scale fixes for SMA atoms: addressed

close-sma50 to 0.15, close-sma200 to 0.3. This was the finding in
momentum.rs. Correct.

### DFA-alpha centering: addressed

The proposal centers dfa-alpha as `(dfa-alpha - 0.5)` with scale 0.5.
Finding #5 (DFA-Alpha Centering Bug). Correct.

### Variance-ratio centering: addressed

Centered at 1.0. Correct. The review identified variance-ratio as
having a Log encoding — the proposal changes it to Linear centered.
This is a meaningful encoding type change. It is the right call:
variance-ratio around 1.0 is a signed deviation, not an unbounded
positive ratio.

### Fractal-dim centering: addressed

The proposal centers at 1.5 with scale 0.5. This is more principled
than the review's observation (which noted FD=1.5 is Brownian and
should be the geometric center). Correct.

### Gap removal: addressed

Finding #7 (Gap: Useless for Continuous 24/7 Markets). The proposal
removes `gap` from price_action.rs. Correct.

### Session-depth removal: addressed

Finding #6 (Session-Depth: Useless After Warmup). Removed from
standard.rs. Correct.

### Fibonacci distance atoms removal: addressed

Finding #8 (Zero Information). All five fib-dist-* atoms removed.
Correct. The surviving three range-pos atoms are clean.

### Name corrections: addressed

`recalib-freshness` → `recalib-staleness`. Finding in
broker/self_assessment.rs. Correct.

`market-direction` → `market-signed-conviction`. Finding in
broker/opinions.rs. Correct.

### Selling-pressure removal: addressed

The proposal removes selling-pressure from flow.rs as linearly
dependent on buying-pressure. Correct.

### Volume-ratio removal: addressed

The proposal removes volume-ratio from flow.rs as "redundant with
buying-pressure." I flagged it as a different kind of redundancy
(it's the OBV acceleration as a ratio, which is related but not
identical to buying-pressure), but removing it tightens the module.
This is a reasonable call.

### Body-ratio-pa removal: addressed

Removed from price_action.rs as identical to body-ratio in flow.rs.
Finding in price_action.rs. Correct.

### Kelt-lower-dist removal: addressed

Removed as symmetric with kelt-upper-dist relative to kelt-pos. This
was my observation about the collinearity of the two distance atoms
given kelt-pos. Correct.

### Squeeze encoding fix: addressed

squeeze from Linear to Log. The review identified squeeze as a ratio
and Linear as potentially wrong. Correct.

### Stoch-cross-delta removal: addressed

The proposal removes stoch-cross-delta as "derivative of stoch-kd-spread
— linearly dependent on the spread." This was my finding in stochastic.rs.
Correct.

### Consecutive-up/down: encoding changed

The proposal shows these as Linear with /10 normalization rather than
Log with (1 + count). I said Log was correct for count data — "a run of
4 vs 1 is geometrically different from 8 vs 4." The proposal disagrees
silently and normalizes with /10. This is defensible for small counts
(capped at 10) but loses the ratio sensitivity. The proposal should
explain this choice, not just make it. I will not call it wrong, but
I note the geometric tradeoff is real.

### Tf-5m-1h-align removal: addressed

Removed from timeframe.rs. The review flagged it as massively over-scaled
(scale 0.1 for a signal that lives in ±0.005). The proposal removes it
entirely rather than fixing the scale. Acceptable — removing a broken
atom is cleaner than rescaling it.

---

## What the Proposal Misses or Incorrectly Resolves

### Finding missed: dist-from-midpoint collinearity

The review identified dist-from-midpoint as the average of dist-from-high
and dist-from-low — two degrees of freedom for three atoms. The proposal
retains all three in standard.rs without explanation. The target state
shows dist-from-midpoint still present. This is an unaddressed redundancy.

If the midpoint is kept, drop one of the other two. If the pair is kept,
drop the midpoint. Pick one.

### Finding missed: stoch-d collinearity

The review: "if you know stoch-k and stoch-kd-spread, you know
stoch-d." The proposal removes stoch-cross-delta but retains stoch-d
alongside both stoch-k and stoch-kd-spread. Three atoms, two degrees of
freedom. The review recommendation was to drop stoch-d. The proposal
keeps it. This contradicts the stated principle: "if two atoms are
linearly dependent, one dies."

### Finding missed: market-conviction collinearity

The review: "|market-direction| == market-conviction by construction."
Signed conviction and absolute conviction are not independent — the
absolute value of one equals the other. The proposal retains both
market-signed-conviction and market-conviction in broker/opinions.rs.
Two atoms, one degree of freedom. The review recommendation: drop
market-conviction, keep the signed form. The proposal does not address
this.

### Finding missed: dist-from-sma200 / close-sma200 duplication

The review identified that standard.rs's dist-from-sma200 computes
`(price - sma200) / price`, which is identical to momentum.rs's
close-sma200. The proposal removes session-depth from standard.rs but
retains dist-from-sma200. Looking at the proposal's target for standard.rs:

```
(Log "dist-from-sma200" (max (abs dist-from-sma200) 0.001))  ; OK
```

Wait — this is now Log, not Linear. The original was Linear. And
momentum's close-sma200 remains Linear. If the two modules now use
different encoding types for the same underlying quantity, they are
no longer identical atoms — they are different geometric representations
of the same number. That is an encoding inconsistency, not a fix.

Either: (a) both modules encode the same quantity the same way, in
which case one is redundant and should be removed, or (b) the two
modules intentionally encode the same number differently for different
purposes, which requires explanation.

The proposal neither removes the duplication nor explains the
encoding divergence.

### Finding missed: upper-wick / lower-wick collinearity

The review: "upper-wick + lower-wick + body-ratio-pa = 1.0 within a
candle." The proposal removes body-ratio-pa (correct). But upper-wick
and lower-wick remain, and body-ratio is still in flow.rs. The sum
constraint: body-ratio (flow) + upper-wick + lower-wick = 1.0. Three
atoms, two degrees of freedom. The proposal has not eliminated the
linear dependence, only changed which atom is the "other" in the
triple.

One of the three must go. Options: (a) drop upper-wick (keep
lower-wick and body-ratio), (b) drop lower-wick (keep upper-wick and
body-ratio), (c) drop body-ratio from flow.rs and keep both wicks.
The proposal keeps all three.

### Finding deferred without resolution path: the duplication epidemic

The proposal acknowledges the duplication epidemic in section
"Duplication resolution" and then defers it to a future architectural
change. This deferral is described as:

> "This is a larger architectural change. Deferred. The immediate
> fixes are the encoding bugs and dead atoms."

I accept that some things must be deferred. But the proposal's own
summary table shows "Exit atoms: Before 28, After 28, Delta 0." The
exit modules receive zero treatment beyond RSI normalization and the
regime centering fixes. The confirmed duplications in the composed
broker vector are untouched:

| Atom | Status in Proposal |
|------|--------------------|
| `atr-ratio` (momentum + exit/volatility) | Not addressed |
| `bb-width` (keltner + exit/volatility) | Not addressed |
| `squeeze` (keltner + exit/volatility) | Not addressed |
| `adx` (persistence + exit/structure) | Not addressed |
| `hour` (shared/time + exit/time) | Not addressed |
| `day-of-week` (shared/time + exit/time) | Not addressed |
| All 8 regime atoms | Deferred |
| 5 timing atoms (rsi,stoch-k,stoch-kd-spread,macd-hist,cci) | Deferred |

The proposal's target state table says "-14 delta on market atoms" and
"0 delta on exit atoms." A target state that leaves the exit vocabulary
structurally unchanged is not a target state — it is a partial cleanup
that leaves the most expensive problem in place.

The deferral is honest — this is a real architectural constraint. But
the proposal should say explicitly: "After all fixes, the Momentum
lens + Timing exit lens pairing still doubles all five timing atoms.
The composed vector is still corrupted for this specific pairing. This
is known and deferred." Silence about what the deferral leaves broken
is not honest.

### Finding incorrect: variance-ratio encoding change

The review said: "Log is correct. The variance ratio is a positive
ratio that can span a meaningful range around 1.0." The review also
identified the duplication problem (exit/regime.rs has the same atom).

The proposal changes variance-ratio to `(variance-ratio - 1.0)` with
Linear encoding. This centers it at 1.0, which is geometrically
principled (1.0 is the neutral: variance ratio of 1.0 means no
autocorrelation pattern). The review called the original encoding
"correct" — Log for a positive ratio. Which is right?

Both are defensible. Log captures multiplicative distance from 1.0
symmetrically (2.0 and 0.5 are equidistant). Linear centered at 1.0
treats additive deviations symmetrically (1.5 and 0.5 are equidistant).
For variance ratios in the range [0.5, 2.0], both give reasonable
geometry. The proposal's choice is not wrong.

However: the original atom had Log encoding, and the proposal switches
to Linear without documenting why the original was wrong. "Just
implemented" from the derived.rs comment about variance-ratio as a
ratio aligns with Log. The centering argument aligns with Linear. The
proposal should make the case explicitly.

### Finding not addressed: divergence conditional emission

The review raised the divergence conditional emission problem: when
atoms are sometimes absent, the noise subspace can't learn a stable
direction for "divergence present." The proposal says "No changes.
Conditional emission is correct." This is a judgment call that
overrules the review finding. The proposal should explain why it
disagrees, not just assert correctness.

If the team has evidence that conditional emission works (the reckoner
converges), that evidence should be cited. If it's a principled
architectural choice (absent = "not applicable" is semantically
different from present-at-zero), that principle should be stated.
"Correct" without reasoning is not a finding resolution.

### Finding not addressed: missing atoms

The review identified several signals that should exist but don't:
funding rate, spread/liquidity, candle direction flag (up/down
categorical), volume deviation from session average. The proposal
does not address these. This is an acceptable omission for a "clean
up what exists" proposal, but it should be acknowledged. The section
on "what we are NOT changing" would improve honesty here.

### Finding not addressed: obv-slope naming

The review flagged: "obv-slope" doesn't specify the 12-period window.
"obv-slope-12" would be honest. The proposal retains the opaque name.

### Finding not addressed: tf-1h-ret encoding question

The review asked about tf-1h-trend normalization — whether tf_1h_body
is raw price difference or normalized. The proposal retains the atom
without addressing the opacity. The target state shows it OK without
verifying what the candle struct contains.

### Finding not addressed: autocorrelation lag ambiguity

The review noted: "autocorrelation at lag 1" vs "mean autocorrelation
across lags" carry different information and the name doesn't say. The
proposal shows persistence.rs as "No changes." The opacity remains.

---

## The Proposal's Own Principle Violations

Principle 1 states: "If two atoms are linearly dependent, one dies."

The proposal then retains:
- stoch-k + stoch-d + stoch-kd-spread (three atoms, two dof)
- market-signed-conviction + market-conviction (two atoms, one dof)
- upper-wick + lower-wick + body-ratio from flow (three atoms, two dof)
- dist-from-high + dist-from-low + dist-from-midpoint (three atoms, two dof)

Principle 1 is stated and then violated four times in the target state.
Either the principle is wrong (and should say "if two atoms are
linearly dependent AND neither adds qualitative information, one dies")
or the target state is incomplete.

I lean toward the principle being too strong as stated, and the
violations being defensible in some cases (stoch-k/d — absolute zone
information). But the proposal should defend its exceptions against
the principle it declared, not silently break it.

---

## What the Target State Gets Right That the Review Missed

The proposal's regime centering (fractal-dim, variance-ratio, dfa-alpha)
is more thorough than what I named explicitly. The proposal also
catches the squeeze type change (Linear → Log) as a ratio fix. These
are both correct improvements.

The explicit removal of exit/regime's centering bugs (same three fixes)
is good — the proposal applies the same corrections symmetrically to
both market and exit regime modules. The review mentioned the regime
duplication but didn't fully enumerate that the centering bugs exist
in both copies.

The broker/derived.rs observation ("just implemented, already reviewed")
is honest — the proposal doesn't overclaim.

---

## Summary Judgment

The proposal is a genuine improvement over the current state. Encoding
bugs are fixed. Several dead atoms are removed. Names are corrected.
The vocabulary gets smaller and more honest on encoding type and scale.

But the proposal does not achieve what it claims as a target. It claims
to describe "what the vocabulary should look like after all fixes." It
does not. It describes what the vocabulary looks like after encoding
fixes and some atom removal, with the most expensive structural problems
deferred and several collinearity violations of its own stated principle
left in place.

A more honest title: "Proposal 032 — Encoding Correctness Pass."

The duplication epidemic is an architectural problem that requires
a lens/composition redesign. The proposal acknowledges this and
defers it. That is honest. But deferral should come with an explicit
accounting of what the deferral leaves broken. The target state is
not a destination — it is a waypoint with known problems still active.

The following must be resolved before this is truly a target state:

1. Decide on stoch-d: keep or drop? One must die.
2. Decide on dist-from-midpoint: keep or drop one of the three?
3. Decide on market-conviction: it equals |market-signed-conviction|. Drop it.
4. Decide on dist-from-sma200 vs close-sma200: same formula, pick one owner.
5. Decide on the third wick/body atom: upper-wick + lower-wick + body-ratio = 1.0.
6. Explain divergence conditional emission: why is absence semantically correct?
7. Add explicit acknowledgment of which broker lens pairings remain corrupted.

Items 1-5 are encoding principle violations. Item 6 is a reasoning gap.
Item 7 is honesty about what the deferral leaves active.

The encoding fixes are real and should be implemented regardless. The
dead atoms should be removed. The names should be corrected. This is
useful work. It is not a complete target state.

---

*Reviewed against: `docs/vocab-review-hickey.md`*
*Proposal: `docs/proposals/2026/04/032-vocab-audit/PROPOSAL.md`*
