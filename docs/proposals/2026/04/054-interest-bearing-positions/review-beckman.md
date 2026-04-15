# Review: Beckman

Verdict: APPROVED

## General impression

This is the cleanest proposal I have read from this project. The core
insight — replace continuous distance prediction with discrete exit
predication gated by an economic cost function — is algebraically sound
and operationally simpler. The interest rate is a single scalar that
induces a natural partial order on trades by survival time. That is
elegant. Let me take the questions in order.

## Answers to the ten questions

### 1. The lending rate

Fixed is wrong. ATR-proportional is wrong. The rate should be
*discovered* — but not from a parameter sweep. The rate is the treasury's
single degree of freedom. Start with a rate derived from the median
phase duration (53 candles) such that a zero-move position dies in
exactly one phase. That gives the treasury a principled initial
condition. Then let the survival distribution shift the rate: if too
many papers survive, the rate is too low (insufficient selection
pressure). If too few survive, the rate is too high (you are killing
signal along with noise). The rate is a feedback loop, not a constant.
This composes: the rate is a function from ledger statistics to a
scalar — a perfectly good morphism.

### 2. Entry frequency

One per candle is too many. Not because of computation — because of
information content. Consecutive candles within a phase carry nearly
identical structure. The first entry captures the phase; subsequent
entries are redundant bets on the same observation. One entry per phase
window is the right granularity. The interest naturally discourages
over-entry (each entry starts its own clock), so even if you allow one
per candle, the survivors will be sparse. But why generate waste the
treasury must track? Let the broker self-gate. The anxiety atoms
provide the mechanism: if the bundle of a new entry looks too similar
to the bundle of an existing open position (cosine > threshold), the
broker should decline. This is the algebra doing the gating — not an
arbitrary frequency limit.

### 3. The reckoner's new question

Discrete is correct. "Exit or hold at this trigger" is a well-posed
binary classification problem. "How much longer should I hold" is a
regression problem over a distribution you have already shown the
continuous reckoner cannot learn (Proposal 053). The state machine is
clean: {Holding, Evaluating} where transitions to Evaluating happen
only at peaks/valleys. In Evaluating, the three-condition predicate
fires. This is a Moore machine — output depends only on state, not on
the transition. The reckoner's job is to learn the predicate, not to
predict a duration.

### 4. Treasury reclaim

Automatic. No grace period. When interest exceeds position value, the
claim is revoked. The reason is algebraic: the position's residue has
crossed zero. Negative residue is not a state in your model — there is
no concept of the broker owing more than the position is worth. The
transition is a zero-crossing, which is a well-defined event. Giving
the broker "one more transition" introduces a partial state where the
broker holds a negative-value claim. That breaks the invariant that
the treasury is always whole. Kill it at zero. Clean.

### 5. The residue threshold

The reckoner should learn this. The exit fee (0.35%) is arithmetic —
that is a hard floor and must be enforced. But "substantial" is a
learned concept. A position that exits with 0.01% residue after
interest and fees is Grace by the letter of the law but operationally
pointless. The reckoner will learn this from the distribution of
outcomes: positions that exit with tiny residue will not improve the
broker's survival statistics meaningfully. The reckoner's discrete
prediction should encode this — the anxiety atom `unrealized-residue`
carries exactly this information. No threshold parameter. Let the
algebra speak.

### 6. Both sides simultaneously

Yes. This is correct and it composes. A long from a prior buy window
and a short from the current sell window are independent positions with
independent interest clocks. The treasury lends to both because they
are different claims on different assets. The phase labeler's symmetry
(2,891 buy vs 2,843 sell) provides the statistical balance. Restricting
to one direction at a time would be an artificial constraint that
breaks the pair-agnostic model. The treasury holds both sides of the
pair — it can lend both sides simultaneously. The positions are
independent monoid elements in the ledger; they compose by
concatenation, not by cancellation.

### 7. The interest as thought

The four anxiety atoms are well-chosen. I would add one:

```scheme
(Linear "interest-rate-vs-residue-velocity" 1.7 1.0)
```

The ratio of the interest accrual rate to the rate of change of
unrealized residue. This is the derivative that tells the broker
whether it is winning or losing the race. The current atoms are all
levels (snapshots). This one is a rate (trajectory). The reckoner
needs both to learn the exit predicate well. Levels tell you where
you are. Rates tell you where you are going. The phase labeler
already provides structural trajectory; this adds economic trajectory.

### 8. The denomination

Per-candle twist is the right granularity because the candle is the
system's clock tick. The rate should breathe with volatility — but
not ATR directly. ATR is a level. The rate should track the *change*
in ATR: when volatility is expanding, the rate rises (positions in
expanding volatility that are not moving WITH the expansion are
losing). When volatility is contracting, the rate falls (positions
in contracting volatility need more time to realize gains). This
keeps the rate as a function of observable market state — a proper
morphism from the market's volatility regime to the treasury's
lending cost. Composable.

### 9. Rebalancing risk

The phase labeler's symmetry is necessary but not sufficient. In
trending regimes, you will get long streaks of one direction. The
treasury should track its exposure ratio (USDC/WBTC) and apply a
spread to the interest rate when exposure is skewed. Lend the
over-represented asset cheaper, the under-represented asset dearer.
This is a price signal, not a hard limit. It preserves composability
— the rate remains a single scalar per position, just computed from
a richer input (base rate + exposure adjustment). Hard directional
limits would break the broker's autonomy and introduce coupling
between independent positions.

### 10. Paper erosion as the only gate

Sufficient. The survival rate against interest IS the EV gate — it
just measures EV differently. A broker with 70% survival and positive
mean residue is profitable by definition (the interest already
accounts for time cost). Adding a separate EV calculation would be
redundant — you would be computing the same quantity twice in
different notation. The survival rate is the cleaner formulation
because it is a single number (a probability) rather than a
distribution statistic. Probabilities compose; distribution moments
do not (in general). The paper trail is the proof. The survival rate
is the gate. One number. One threshold. Clean.

## Algebraic assessment

The paper-with-interest is a well-defined state machine with three
states: {Active, Grace, Violence}. Transitions are deterministic
given the three-condition predicate and the zero-crossing check.
The ledger is a free monoid over position records — append-only,
composable by concatenation. The treasury's total-value invariant
is preserved across all transitions. The interest rate is a
single scalar that parameterizes the selection pressure. The
transition from continuous to discrete reckoner is algebraically
sound: you are moving from regression over a poorly-defined
continuous target to classification over a well-defined binary
target with the same input algebra.

The favor system (variable interest rate) introduces state, but it
is *visible* state — recorded in the ledger, computable from the
ledger, deterministic given the ledger. It is not hidden. It is a
fold over the broker's history. Folds compose.

Build it.
