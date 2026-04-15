# Review: Van Tharp

Verdict: CONDITIONAL

## The reference amount question

$100 or $10,000 — the proposal says "the amount doesn't matter, only
the percentages." This is correct in principle but sloppy in practice.
At $100, a 0.35% entry fee is $0.35. At $10,000 it is $35. Both
produce the same percentage residue. But $100 introduces a numerical
precision problem: a 1% residue is $1.00, and your fee arithmetic
operates at the cents level. Floating-point noise at that scale can
flip a Grace to a Violence on the margin.

Pick one. $10,000. Use it everywhere. The percentage proof is valid
at any reference amount, but you want the arithmetic to be clean.
The paper is not capital — it is a measurement instrument. Calibrate
the instrument once.

## Proposer record and expectancy

The `ProposerRecord` captures `papers_survived`, `papers_failed`, and
`total_grace_residue`. From these you derive survival rate and mean
residue. This is half of expectancy.

Expectancy = (win_rate * avg_win) - (loss_rate * avg_loss).

You have win_rate (survival_rate) and avg_win (mean_residue). You do
NOT have avg_loss. In the deadline model, every Violence is a total
loss of the reference amount — the deadline expired, the claim is
revoked, the principal is gone. If that is the invariant — every
Violence loses 100% of the reference — then avg_loss is always
`reference_amount` and you can derive full expectancy from what you
have. The proposal should state this explicitly. If Violence can
return partial value (the asset is reclaimed but some value remains),
then avg_loss varies and the record must track `total_violence_loss`.

Recommendation: add `total_violence_residue: f64` to the record. Even
if it is always zero today, the struct should carry the field. When
the contract hits Solana and someone proposes partial reclaim, you
will need it. Cost: one f64. Benefit: complete expectancy forever.

## Deadline as trust

ATR-proportional deadlines are statistically sound. Volatility-adjusted
time horizons are standard practice. The formula
`base_deadline * (median_atr / current_atr)` normalizes holding period
to regime — high vol compresses, low vol extends. This is correct.

The concern: median ATR over what window? The proposal says "at entry
time" but does not specify the lookback. A 20-candle ATR and a
200-candle ATR produce very different deadlines. The median must be
a long-term anchor (hundreds of candles minimum) or the deadline
itself becomes regime-dependent in a circular way. Specify the
lookback. Pin it.

The "proven winners earn longer deadlines" mechanism (favor) is
mentioned but not formalized. How much longer? Additive candles?
Multiplicative factor on base_deadline? This needs a formula or it
becomes a tuning knob someone will abuse.

## Two-claim-state model

Deposited vs in-trade is the right partition. Every dollar is in
exactly one state. No double-counting. The withdrawal queue that
fills from returning principal is correct — you never break an
active position to satisfy a withdrawal.

Position sizing concern: the proposal does not specify how much of
the deposited balance a broker can put in-trade simultaneously. If
a broker can commit 100% of deposits to active papers, a string of
Violences wipes the account. There is no mention of maximum
concurrent exposure per broker or maximum fraction of deposits
at risk. In the lab this does not matter (no withdrawals, everything
reinvests). On Solana it is critical.

Recommendation: the treasury should enforce a maximum in-trade
fraction per proposer. Even a simple rule — no more than N% of
deposited balance in active trades — prevents ruin. The survival
rate gate is necessary but not sufficient; it gates entry quality,
not exposure quantity.

## Residue split incentives

50/50 split between proposer and treasury pool. The proposer earns
half, the pool grows by half. Passive depositors benefit from pool
growth. This aligns incentives correctly: everyone wants Grace.

One subtlety the proposal handles well: the proposer's half credits
to their deposited balance, not paid out. This means the proposer's
future sizing grows with success — compound returns on good thoughts.
This is the right reward structure. It is Kelly-like: winners get
bigger, losers get smaller, organically.

The split ratio (50/50) is a parameter. The proposal does not discuss
whether this should be fixed or adjustable. For the lab: fix it.
For Solana: the treasury could adjust the split as a second control
lever alongside the interest rate. But that is future scope.

## What is missing

1. Maximum concurrent papers per broker. Without a cap, a broker
   can flood the treasury with papers during every active phase.
   The paper cost is zero in the lab. On-chain it costs gas. In
   the lab, cap it or the record becomes noisy.

2. The Violence resolution returns nothing to the broker. The
   proposal says "the asset stays in the treasury" but does not
   say whether the remaining value (the position may still have
   value, just not enough to cover fees + principal) stays in
   the pool or is attributed anywhere. Clarify.

3. No mention of position sizing for real trades. Papers are fixed
   reference amounts. Real trades borrow "amount" — but how is
   that amount determined? Kelly from the proposer record?
   Proportional to deposited balance? Fixed? This is the core
   position sizing question and it is unanswered.

## Summary

The architecture is sound. The headless treasury judging outcomes
not strategy is the right separation. The deadline as natural stop
loss through carrying cost is elegant and avoids the distance
inflation problem from Proposal 053. The two-claim-state model is
clean.

The gaps are in sizing: how much per real trade, how many concurrent
papers, and what happens to residual value on Violence. These are
not design flaws — they are unspecified parameters that must be
pinned before implementation.

Conditional on: (1) fix reference amount to $10,000, (2) add
`total_violence_residue` to ProposerRecord, (3) specify ATR lookback
for deadline calculation, (4) define real trade sizing rule, (5) cap
concurrent papers per broker in the lab.
