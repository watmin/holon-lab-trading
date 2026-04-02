# Review: Rich Hickey

Verdict: CONDITIONAL

## What is right here

The proposal correctly identifies that the 50/50 seed split creates a
semantic lie. You say "I have $10k" but you trade with $5k. The seed WBTC
sits in a balance map, inert, while the enterprise carefully manages
$75 lots. This is not a capital efficiency problem. It is a *truth*
problem. The data structure says one thing, the behavior says another.

The insight that a position is an allocation change, not an isolated lot,
is the right reframing. When you say Buy, you mean "increase exposure to
this asset." When the treasury holds WBTC and you say Buy, the correct
action is *nothing* -- you already hold it. The lot model forces a
ceremony (swap out, swap back in) that exists to satisfy the mechanism,
not to express the intent. Removing that ceremony is simplification, not
optimization.

The desk-as-value design is clean. A desk receives candles, produces
recommendations, knows nothing about the treasury. The treasury receives
recommendations, checks its holdings, executes if it can. No desk-to-desk
coordination. No routing layer. Two independent things that compose
through data, not through calling each other. This is the right shape.

The "no routing" rule is particularly good. If you don't hold BTC, you
can't act on a (SOL, BTC) signal. The treasury's holdings *are* the
routing table. You don't need a routing mechanism because the constraint
is already expressed by the data. The portfolio grows its surface area by
accumulating assets. That's a property that emerges from the values, not
from a feature you build.

## What concerns me

### 1. `allocatable` is tied to base_asset -- that's a place, not a policy

Look at your current treasury:

```rust
pub fn allocatable(&self) -> f64 {
    let total_base = self.total(&self.base_asset);
    let max_deploy = total_base * self.max_utilization;
    let deployed_base = self.deployed(&self.base_asset);
    ...
}
```

This computes "how much USDC can I spend." In a multi-asset world,
the question is "how much of asset X can I deploy toward pair Y."
The function hard-codes a *which* into a *how much*. The concept you
need is: given the treasury's total value, what fraction may be
deployed to any single pair? That's a policy over the portfolio, not
a query against one asset.

The proposal gestures at this ("treasury computes target allocation")
but doesn't specify the value that replaces `allocatable`. What is
the data? A map from asset to maximum deployable fraction? A single
`max_per_desk` fraction of total portfolio value? This needs to be a
value you can look at, not a method that reaches into state.

### 2. You have complected "what I hold" with "what I'm willing to trade"

The proposal says "the seed is not special. All available balance is
tradeable." But right now your treasury has `balances` (available) and
`deployed` (locked). A Sell signal that sells from `balances` means
you're selling assets that no position manages. After the sell, who
tracks the resulting USDC? Is it a position? Is it just balance?

The current model is clean in one respect: `claim` moves
available-to-deployed, `release` moves deployed-to-available, and
positions own everything in `deployed`. If a Sell signal can sell from
`balances` directly, you have capital moving without a position owning
it, or you need positions to claim from any asset -- not just the
quote asset.

The proposal should state clearly: **a Sell creates a position that
claims from the quote asset's available balance, just as a Buy claims
from the base asset's available balance.** Both directions use the
same claim/release/swap lifecycle. The only change is which asset is
the source. If this is what you mean, say it explicitly. If you mean
something else, I'd like to see what.

### 3. The position struct carries base_deployed and quote_held -- these are directional names baked into a supposedly generic structure

`ManagedPosition` has `base_deployed` (USDC spent) and `quote_held`
(WBTC received). For a Long, these make sense. For a Short, you're
already awkwardly setting `quote_held: 0.0` and computing P&L from
`entry_price` deltas rather than from held assets.

In a multi-asset world where any asset can be source or target, these
field names are lies. A position should know: which asset did I sell
(`source_asset`, `source_amount`), which asset did I receive
(`target_asset`, `target_amount`), and what was the exchange rate. The
lifecycle (stop, take-profit, trailing) operates on the exchange rate.
This is the same structure regardless of direction or pair.

Renaming fields is not cosmetic. When the field name doesn't match
the semantic, you will write bugs. You already have a `match direction`
in `return_pct` that computes two completely different formulas. That
branch exists because the struct can't express what actually happened.

### 4. The "no cross-asset manager" claim needs interrogation

You say "each desk produces signals independently" and "no additional
arbitration needed." This is true for uncorrelated assets. But BTC and
ETH are highly correlated. If the BTC desk says Buy and the ETH desk
says Buy simultaneously, the treasury doubles its crypto exposure.
The risk branches measure per-desk health, but who measures total
portfolio concentration?

You don't need a cross-asset *manager* (that would be a mechanism).
But you may need a cross-asset *value*: the portfolio's current
exposure by asset class, computed from treasury balances, available
for any gate to read. The risk branch could read it. The treasury's
execution gate could check it. No new mechanism -- just a derived
value that's visible.

The proposal should acknowledge this. Not solve it -- acknowledge it.
"Correlation risk is real; the treasury's per-pair risk gates don't
cover it; we will address it when N > 1 by deriving a concentration
value." That's honest. "No additional arbitration needed" is not.

### 5. Phasing: the proposal asks a question it already answered

Question 3 asks whether to fix single-pair first or design both
together. The answer is in the proposal itself: the single-pair fix
(make all balance tradeable, fix Sell sizing) is a *subset* of the
multi-asset design. You don't need to choose. Implement the position
model correctly for one pair -- source/target instead of base/quote,
claim from either side, symmetric lifecycle -- and multi-asset falls
out by adding desks.

But do not ship the multi-asset treasury before the single-pair
position model is correct. The position struct is where the
complexity hides. Get that right on one pair. Then adding pairs is
configuration, not architecture.

## Answers to questions

**Q1: Position as allocation change vs isolated lot?**

Keep the lot model. A position tracks a specific swap: I sold X of
asset A and received Y of asset B at rate R. The position manages
that specific Y with stops and targets. The *treasury's interpretation*
of that position is an allocation change. But the position itself is
concrete -- it holds specific assets. Don't make positions abstract
percentages. Percentages drift with price. A lot is a value. A
percentage is a place.

**Q2: Sell from holdings?**

Yes, sell from the treasury's available balance. The seed distinction
must die. But the Sell must create a position that claims the sold
amount, so the lifecycle is symmetric with Buy. Don't have free-floating
capital movements that bypass the position model.

**Q3: Phasing?**

Fix the position model first (source/target, symmetric claim). Then
add desks. The position fix is the hard part. Multi-asset is the easy
part.

## The condition

Approved when the proposal specifies:

1. The position struct in terms of source/target assets and amounts,
   not base/quote. Show the struct. Show that both directions use the
   same fields the same way. No `match direction` in P&L computation.

2. The allocation gate: what value replaces `allocatable` in a world
   where any asset can be the source? A function from (treasury, asset,
   policy) to deployable amount.

3. Acknowledgment of concentration risk across correlated desks, even
   if the solution is deferred.

These are not large changes. They are clarifications that prevent the
implementation from inheriting the current model's directional bias.
The architecture in this proposal is sound. The data model needs one
more pass.
