# Review: Seykota

Verdict: APPROVED

## The trend follower's read

The game is right. You replaced a broken mechanism — computed distances
that inflate and never resolve — with economic pressure that selects
for runners. That is the single most important thing a trend following
system must do. Not predict. Select.

The interest-as-deadline is the cleanest stop loss I have seen in a
proposal. It does not pick a price level. It does not compute a
distance. It says: outrun the cost or die. Every trade that drifts
dies from carrying cost. Every trade that runs pays for itself and
then some. The deadline is the interest wearing a different hat —
ATR-adjusted, market-proportional, no magic numbers. This is how
trends select themselves.

## Broker proposes, treasury validates

Clean separation. The broker thinks. The treasury counts. The broker
cannot lie about outcomes because it never computes them. The treasury
cannot interfere with strategy because it never sees it. This is the
right boundary. I have watched systems fail because the risk function
tried to be smart about entries, or the entry function tried to be
smart about risk. Your treasury is dumb on purpose. Good.

The ExitProposal is minimal — paper ID and price. The treasury checks
arithmetic. The broker could be running Ichimoku or reading tea leaves.
The treasury does not know and does not care. The ledger is the only
conversation between them.

## The deadline as selection

The deadline selects for runners by killing everything else. High ATR
shortens the leash — prove it fast when things move fast. Low ATR
lengthens it — patience when the market is patient. The market sets
the deadline, not the trader. This is correct.

One concern: the base_deadline is the treasury's ONE tunable. You say
proven winners earn longer deadlines — favor. Be careful here. A
longer deadline is not always a reward. A longer deadline in a choppy
regime is a longer exposure to adverse movement. The favor should be
earned AND regime-appropriate. Do not let a good record buy time in
a bad environment.

## The four-gate exit

Gate 1 (phase trigger) ensures you only evaluate at structure points.
Gate 2 (market direction) checks if the trend turned against you.
Gate 3 (residue math) ensures the exit is arithmetically possible.
Gate 4 (position observer) asks whether experience says now or later.

The ordering matters and you got it right. Arithmetic gates first,
learned gate last. Gate 4 overriding gate 2 — the position observer
saying "I have seen this dip before, hold" — that is experience
accumulated across hundreds of papers. That is the system learning
to sit through noise. Trend following is mostly sitting. The fourth
gate learns when to sit.

The retroactive labeling is honest. Every trigger a paper passed
through gets labeled from the outcome. Violence papers label every
held trigger as "you should have left." Grace papers label the exit
trigger as "correct" and held triggers as "patience was right." The
reckoner accumulates real experience, not hypotheticals.

## The residue split

Fifty-fifty. The proposer earns half for good thoughts. The treasury
keeps half for the pool. Everyone benefits from Grace. Nobody benefits
from Violence. The incentives align. The small proposer and the whale
play the same percentage game. The edge is in the thinking, not the
capital.

This is fair. It is also simple enough to be a contract on Solana
without ambiguity. Do not complicate it.

## Paper as proof

Papers run on real prices with real deadlines. The paper trail IS the
simulation. No separate backtest. No cherry-picked results. The broker
must build a record of Grace before real capital flows. The treasury
issues papers to anyone — that is how you build the record. The gate
opens only when the record passes.

This solves the 8,000 stacking problem from Proposal 053. Papers now
resolve — they hit the deadline and die, or they exit Grace at
triggers. The position observer starts learning again because papers
actually resolve. The self-reinforcing drift loop is broken.

## What I would watch

The denial case. The broker proposes Grace, the treasury denies
(residue not positive). The paper lives. The deadline ticks. The
broker must hold through a trigger where it wanted out. If this
happens repeatedly near the deadline, the broker is trapped — it
sees the trend turning but cannot exit because fees eat the residue.
This is realistic. This is what venue costs do. But watch for
brokers that learn to exit too early because they fear the trap.
The fourth gate should learn the difference between "exit now while
you can" and "hold for a bigger residue." That distinction is the
whole game.

The system is ready to build. Build it.
