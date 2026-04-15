# Review: Beckman

Verdict: CONDITIONAL

## The Paper as state machine

Paper has two terminal states (Grace, Violence) and one non-terminal state
(active). The transitions are: active -> Grace (broker proposes, treasury
validates arithmetic), active -> Violence (deadline expires). The `resolved`
boolean plus `Option<Outcome>` encodes this. It works, but you have a
representational redundancy: `resolved == true` iff `outcome.is_some()`.
One field suffices. An enum `PaperState { Active, Grace(f64), Violence }`
would make the state machine honest in the type. As written, you can
construct `resolved: true, outcome: None` -- an impossible state that the
type permits. Minor, but state machines should close.

## The ledger as monoid

The treasury's ledger composes correctly under the monoidal view.
`ProposerRecord` is a commutative monoid: `papers_submitted`,
`papers_survived`, `papers_failed` are counters (additive),
`total_grace_residue` is a sum. The identity is all zeros. Two records
compose by field-wise addition. This means you can partition the ledger
by time window, compute partial records, and merge them. Good. The
derived quantities (survival_rate, mean_residue) are homomorphisms from
this monoid into the rationals. The predicate over the derived quantities
is a monoid morphism into Bool under AND. Clean.

One concern: the `balances: HashMap<Asset, f64>` is also a commutative
monoid (pointwise addition), but the conservation law (total value
invariant across rebalancing) is not enforced by the type. You assert
the treasury "can't lose" -- this is an algebraic invariant that should
be a ward, not a hope. Every state transition should preserve the sum
`balances[USDC] + balances[WBTC] * price`, modulo fee extraction. If
you track fees separately, the invariant becomes exact.

## Broker-proposes / treasury-validates as adjunction

This is the strongest part of the design. The broker's proposal is a
left adjoint (free construction -- "here is what I want to do"). The
treasury's validation is the right adjoint (forgetful -- "I see only
arithmetic"). The adjunction says: a proposal is accepted iff its image
under the forgetful functor (strip strategy, keep arithmetic) satisfies
the treasury's predicate. The treasury is the right adjoint precisely
because it is headless -- it forgets everything except the residue
calculation. This is a genuine categorical separation and it composes.

The asymmetry is correct: the broker can propose for any reason, the
treasury validates one thing. The unit of the adjunction is the paper
registration (free construction from a broker intention into the
treasury's ledger). The counit is the verdict (the treasury projects
back onto the broker's world). Honest.

## Retroactive labeling as fold

Every trigger a paper passes through is buffered. When the paper
resolves, the outcome propagates backward: Grace at trigger T labels
T as Exit, earlier triggers as Hold. Violence labels all triggers as
Exit (you should have left). This is a right fold over the trigger
history with the resolution as the seed.

The fold is well-defined IF the trigger history is totally ordered
(it is -- candle indices) and IF each trigger's label depends only on
its position relative to the resolution point (it does). The fold
function: given resolution type and trigger position, emit label. This
is a pure function of (trigger_index, resolution_index, resolution_type).
No ambient state. Composes.

One subtlety: Violence labels ALL triggers as Exit. This teaches the
position observer "you should always exit." If Violence papers dominate
the training set, the observer learns to exit at every trigger. The
fold is mathematically clean but the learning signal has a bias. You
need Grace papers in sufficient quantity or the fold produces a
degenerate fixed point (always exit). The proposal acknowledges this
implicitly through the paper mechanism, but it should be stated.

## Deadline as ATR-proportional

`deadline_candles = base_deadline * (median_atr / current_atr)`.

This is an inverse proportionality. High volatility compresses the
deadline, low volatility extends it. Algebraically: the deadline
measures time in units of "expected market movement" rather than
raw candles. This is a change of basis from calendar time to
volatility-normalized time. Sound.

The ratio `median_atr / current_atr` is dimensionless, which is
correct for a scaling factor. The median provides a stable reference
point. But: median over what window? The proposal says "median ATR"
without specifying the estimation window. If the median drifts (it
will, over 652K candles), the deadline semantics drift. Pin the
window or use an exponential estimate with known half-life.

## Two-claim-state model

Deposited (available) and In-trade (reserved). The state transitions:
Deposited -> In-trade (paper issued with real capital), In-trade ->
Deposited (Grace: principal returns + residue credited; Violence:
remaining value returns). The two states partition the balance. The
sum is conserved modulo fee extraction and residue splits.

This closes. The withdrawal queue drains from Deposited only. In-trade
cannot be touched. The partition is a coproduct: every unit of capital
is in exactly one state. The Grace transition splits the return into
three: principal (-> Deposited), proposer's half of residue
(-> proposer's Deposited), treasury's half (-> pool's Deposited). All
three land in Deposited. Violence returns whatever remains to
Deposited. No capital is created or destroyed. The accounting identity
holds.

## Conditions for approval

1. Collapse `resolved` + `outcome` into a single enum. The state
   machine must not admit impossible states.

2. State the conservation invariant explicitly and ward it.
   `sum(balances) + sum(in_trade_value) + sum(fees_collected)` =
   `initial_deposit + sum(external_deposits)`. Every transition
   preserves this. Make it a test.

3. Specify the ATR median window. "Median ATR" without a window is
   not a definition.

4. Acknowledge the Violence-bias in retroactive labeling. The fold
   is clean but the learning signal skews if Violence dominates. The
   paper mechanism mitigates this -- state it explicitly so the
   designers know the dependency.

These are all tractable. The architecture is algebraically sound.
The adjunction between broker and treasury is the best structural
decision in the proposal. The monoid on ProposerRecord means you
can shard, window, and merge without losing compositionality. The
retroactive fold is clean. Fix the four items and this is approved.
