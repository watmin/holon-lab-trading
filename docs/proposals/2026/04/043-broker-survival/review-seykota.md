# Review: Seykota
Verdict: CONDITIONAL

## The diagnosis is correct. The prescription is incomplete.

You have built a system that kills its students before they can graduate.
That is the core finding, and the data proves it. 18 of 22 brokers dead.
The best observer silenced. The survivors selected by luck, not skill.
This is a system that punishes learning.

I have seen this pattern in every trend-following shop that confuses
a drawdown with a broken system. A trader in drawdown is not a dead
trader. A system with negative expectancy over 50 trades is not necessarily
a bad system -- it may be a good system in a bad regime. You do not fire
a trader after their first losing streak. You reduce their size.

Let me answer the five questions.

## Question 1: Should the gate ever permanently close?

No. Never permanently. But also not "always open."

The gate should breathe. A trend follower who hits their drawdown limit
does not quit trading. They reduce position size. They trade smaller.
They stay in the game. The worst thing you can do is leave the table,
because the table is where you learn.

The cold-start threshold (50 of each outcome) is reasonable -- you need
enough data to form an opinion. But after warm-up, the gate should
modulate, not kill. Think of it as position sizing for paper trades.
Negative EV means "trade fewer papers," not "trade zero papers."

A concrete mechanism: when EV is negative, register papers at a reduced
rate -- say one per N candles instead of every candle. This keeps the
learning loop alive while reducing noise. The rate could be proportional
to how negative the EV is. Deep negative, fewer papers. Slightly negative,
nearly full rate. The point is continuity -- never zero.

## Question 2: Should papers be decoupled from the gate?

Yes. This is the key insight in the proposal and I agree completely.

Papers cost nothing. They are hypothetical trades. The entire purpose of
paper trading is to learn without risk. Gating papers behind EV is like
refusing to practice because you lost your last game.

The gate should control **funded proposals to treasury**, not paper
registration. Every broker registers papers every candle, regardless of
EV. The broker tracks its own EV from paper outcomes. When EV is positive
and proven, the broker proposes funded trades. When EV is negative, the
broker still learns but does not propose.

This is how every professional trading desk works. The junior trader
runs paper books for months before getting capital. The paper book
does not close because the junior is unproven. The paper book IS how
they become proven.

Decoupling papers from the gate solves Problems 1 and 2 simultaneously.
All 22 brokers learn continuously. The market observers all receive
learning signals. The exit observers all receive training data. Capital
is still protected because only proven brokers propose funded trades.

## Question 3: Should the journey EMA alpha adapt?

The EMA is the wrong tool for this job.

An EMA with fixed alpha has a fixed effective window. Alpha=0.01 means
an effective window of ~200 observations. Under 1,000 total observations,
that is 20% of history -- reasonable. Under 100,000 observations, that
is 0.2% of history -- the EMA has converged to a point estimate and
lost all sensitivity to regime change.

But the problem is not the alpha. The problem is using a single global
statistic to label a non-stationary distribution. The market changes.
What was Grace yesterday is Violence today. A fixed threshold cannot
track this.

Two options, both better than adapting alpha:

**Option A: Per-broker journey EMA.** You already moved the EMA onto
the broker (I can see `journey_ema` and `journey_count` on the Broker
struct). This is the right instinct. Each broker's journey grading
reflects its own distribution, not the blended distribution of all
22 brokers. The 4 survivors cannot drown the 18 learners. This is
already partially implemented -- follow through.

**Option B: Percentile-based threshold.** Instead of an EMA, maintain
a rolling window of the last N error ratios and use the median (or
some percentile) as the threshold. This is robust to volume and
naturally adapts to distribution shifts. A window of 200-500
observations is sufficient.

I lean toward Option A because it respects the structure you already
have. Each broker is an independent accountability unit. Its journey
grading should be independent too.

## Question 4: Should each broker have its own journey EMA?

Yes. I answered this above, but let me reinforce why.

The 4 surviving brokers produce 73,000 observations. The 18 dead
brokers produce 0. When all 22 feed the same 2 exit observers, the
survivors' distribution IS the training distribution. The dead brokers
have no voice. This is not democracy -- it is tyranny of the survivors.

Per-broker journey grading means each broker grades its own papers
against its own history. A broker that sees mostly Violence develops
a Violence-calibrated threshold. A broker that sees mostly Grace
develops a Grace-calibrated threshold. Each learns from its own
experience, not from the blended experience of strangers.

The struct already has `journey_ema` and `journey_count` per broker.
Use them.

## Question 5: Is this a gate problem or a wiring problem?

It is both, and they compound.

The gate kills the broker. The wiring means the broker's death kills
the observers it feeds. Two independent failures, each sufficient
to cause the starvation cascade, and together they are lethal.

Fix the gate (Question 2: decouple papers from funding proposals)
and the wiring problem largely solves itself. If every broker
registers papers, every broker generates resolutions, every broker
teaches its observers. The observers no longer starve because the
learning signal is always flowing.

But there is a subtlety. The market observer currently learns ONLY
through broker resolutions. This couples market learning to trade
outcomes. A market observer that predicts direction well but is
paired with a bad exit observer will appear to predict poorly --
because the trade failed, not the prediction.

Consider this: the market observer should learn from direction
accuracy, not trade profitability. The market observer predicted
Up and the price went up -- that is Grace for the market observer,
regardless of whether the exit observer set a stop too tight and
got stopped out. The broker learns from trade outcomes. The market
observer learns from directional accuracy. These are different
things and should have different learning signals.

This is the deeper wiring fix. It is not in the proposal, but it
should be.

## Conditions for approval

1. **Papers always register.** Every broker, every candle, regardless
   of EV. The gate controls funded proposals only. This is non-negotiable.
   A learner that cannot practice cannot learn.

2. **Per-broker journey grading.** The struct already supports it.
   Each broker grades its own papers against its own EMA. No shared
   global threshold.

3. **Market observer learning decoupled from trade outcome.** The
   market observer learns from directional accuracy (did price move
   in the predicted direction?), not from whether the trade was
   profitable. This is a deeper change but it fixes the wiring
   problem at its root.

Implement these three and the system self-corrects. All 22 brokers
learn continuously. The best market observer stays in the game. The
exit observers receive balanced training data. Capital is still
protected because only proven brokers propose funded trades.

## A note on complexity

The proposal identifies three problems clearly and asks five precise
questions. Good. But beware the temptation to add mechanisms. Adaptive
alphas. Reopening logic. Rehabilitation periods. Each mechanism is a
parameter. Each parameter is a decision you are making instead of
letting the market make it.

The simplest fix is: papers are free, so never stop papering. That
one change solves 80% of the cascade. The per-broker journey grading
solves another 15%. The market observer decoupling solves the last 5%.

Three changes. No new parameters. No new mechanisms. The system
already has the structure -- the broker struct, the journey fields,
the gate function. You are not building new machinery. You are
removing the lock from the practice court.

The trend is your friend. Let your learners follow it.
