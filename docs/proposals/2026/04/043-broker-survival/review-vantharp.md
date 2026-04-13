# Review: Van Tharp
Verdict: CONDITIONAL

## The Core Issue: You Are Executing Your Systems Before You Have Enough Data to Evaluate Them

The proposal correctly identifies the three problems. But I want to reframe
them through the lens of expectancy and sample size, because the root cause
is deeper than the gate logic.

## On Sample Size

You have 22 brokers. The cold start threshold is 50 Grace and 50 Violence
before the gate becomes EV-dependent. That is 100 trades minimum before you
make a go/no-go decision on a system.

100 trades is the **absolute floor** for evaluating a trading system. I would
not trust an expectancy calculation under 200. I would not declare a system
dead under 500. Your gate declares systems dead at 100 — some of your brokers
died with fewer resolved trades than that, because the cold start only
requires 50 of each *type*, not 50 of each from a statistically stable
period.

The first problem is not the gate. The first problem is that you are making
permanent decisions from insufficient samples.

## Answering the Five Questions

### Question 1: Should the broker gate ever permanently close?

**No. Never permanently.**

A system in drawdown is not a broken system. You cannot distinguish the two
without a statistically significant sample — and "statistically significant"
means hundreds of trades in the *current regime*, not hundreds of trades
total across regime changes.

The gate should have three states, not two:

1. **Proving** (cold start): Always open. Accumulating sample. No capital at
   risk. This is your current cold start, but it should be longer — 200
   trades minimum, not 100.

2. **Active** (proven positive EV): Open. Capital allocated proportionally
   to edge (Kelly or fractional Kelly).

3. **Suspended** (EV negative after proving period): Papers still registered.
   Learning still happens. Capital allocation is **zero**. The broker is not
   dead — it is on the bench. It can return to Active when EV recovers over
   a minimum re-evaluation window (e.g., next 50 trades).

The distinction between Suspended and Dead is the entire point. A trader in
drawdown reduces position size to zero. They do not stop watching the market.
They do not stop tracking their system. They stop risking capital until
the edge reappears — or until the sample is large enough to declare the
system truly broken (500+ trades of negative expectancy in the current
regime).

### Question 2: Should papers be decoupled from the gate?

**Yes. This is the single most important change in the proposal.**

Papers are free. They cost nothing. They are your sample. Cutting off
papers is cutting off your ability to evaluate the system. It is the
equivalent of a trader who stops tracking a system the moment it has a
losing streak — and therefore never knows whether the system recovered.

Every broker should register papers on every candle, regardless of EV.
The gate controls **capital allocation**, not **observation**. This is
the difference between position sizing and system evaluation. You are
conflating the two.

The paper trail IS your R-multiple distribution. Without it, you have
no distribution. Without a distribution, you have no expectancy. Without
expectancy, you have no basis for any decision.

### Question 3: The journey EMA alpha — should it adapt?

**The EMA is the wrong tool for this job.**

An EMA with a fixed alpha has a fixed effective window. Alpha=0.01 gives
you an effective window of ~200 observations. When you pump 103,000
observations through it, the EMA converges to the population mean of
*all* observations — which is not what you want. You want the threshold
to reflect *current* performance, not cumulative history.

Two options, either of which would work:

**Option A: Rolling percentile.** Instead of an EMA, keep the last N
error ratios (N=200 or N=500) and set the threshold at the 50th percentile.
This is regime-adaptive by construction — the window moves with time, old
observations fall off, and the threshold reflects current conditions. It
does not collapse under volume because N is fixed.

**Option B: Adaptive alpha.** Set alpha = 1/min(count, max_window). This
gives you fast adaptation early (alpha=1 for first observation, 0.5 for
second, etc.) and convergence to a fixed window after max_window observations.
But this still has the EMA's fundamental weakness: it never forgets old
data, just weights it less.

I recommend Option A. The rolling percentile is more honest. It tells you
"this is what the middle of the distribution looks like right now" without
carrying ghosts of 100,000 old observations.

### Question 4: Should each broker have its own journey EMA?

**Yes, but not for the reason you think.**

The volume imbalance is a symptom. The disease is that you have 22 systems
feeding into 2 graders. Each system has a different base rate, a different
R-multiple distribution, a different regime sensitivity. Grading them all
on the same curve is like grading a day trader and a swing trader on the
same P&L scale.

Each broker should maintain its own journey grading. The exit observer
receives labels from the broker that sent the observation. This means the
exit observer learns *per-context* quality, not *global average* quality.

But there is a subtlety: each broker's journey grader will have a small
sample. With 22 brokers, each gets 1/22 of the observations. This is
fine for the rolling percentile approach (Option A above) — you just
need each broker to accumulate its own window of N=200 error ratios
before the grading becomes meaningful. During accumulation, grade
everything as learning data (no Grace/Violence split — just train on
the raw error).

### Question 5: Is this a gate problem or a wiring problem?

**Both, but the gate is the urgent fix.**

The wiring problem is that a market observer's learning depends entirely
on broker survival. This creates a fragile dependency: one bad exit pairing
kills a good market observer. Your best observer (59.8% accuracy) is
silenced by a wiring accident.

But the wiring problem is solved by Question 2. If papers never stop,
the market observer always gets learn signals. The wiring only kills
learning when the wire goes dead — and the wire goes dead because the
gate kills papers. Fix the gate, fix the wire.

The deeper wiring question — should market observers have an independent
learning path? — is worth considering but not urgent. If papers are
always registered, every broker always produces resolutions, and every
observer always learns. The coupling is fine as long as the coupling
never goes silent.

What IS worth considering: should the *best* market observer's signal
be weighted more heavily even if its broker has negative EV? The broker's
EV is a joint measure of market prediction AND exit quality. A broker
with negative EV might have an excellent market observer paired with a
terrible exit observer. The market observer's accuracy should be evaluated
independently — which it is, if papers keep flowing.

## The Statistical Requirements for Declaring a System Dead

Since you asked me to think about this:

1. **Minimum 500 resolved trades** in the current regime before any
   permanent action.
2. **Expectancy must be negative over the full 500-trade window**, not
   just the trailing EMA.
3. **The R-multiple distribution must show no positive tail** — if the
   system occasionally produces large winners but frequently produces
   small losers, it may have positive expectancy despite a low win rate.
   Your Grace/Violence binary obscures this. Consider tracking R-multiples
   (profit/initial risk) rather than just win/loss.
4. **Regime change detection**: a system that worked in trending markets
   and fails in ranging markets is not broken — it is regime-dependent.
   Before declaring it dead, check whether the market regime changed.

You are nowhere near these thresholds. 18 of 22 brokers died before
reaching 200 total trades. That is not evaluation — that is premature
execution.

## Conditions for Approval

1. **Papers must be decoupled from the gate.** Every broker registers
   papers every candle, regardless of EV. The gate controls capital
   allocation only. This is non-negotiable.

2. **The gate must have a Suspended state**, not just Open/Closed.
   Suspended means zero capital, continued observation, path back to
   Active.

3. **The journey EMA must be replaced** with a bounded-window mechanism
   (rolling percentile or equivalent). Fixed-alpha EMA under high volume
   is a known failure mode, not a tuning problem.

4. **Journey grading must be per-broker**, not per-exit-observer. The
   grading context must match the accountability unit.

5. **Cold start threshold must increase** from 100 trades (50+50) to
   at least 200 trades total before EV-gating activates. 500 would be
   better.

If these five conditions are met, the proposal addresses a real and
critical problem. The diagnosis is correct. The measurements are honest.
The questions are the right questions.

The system is not broken. It is being evaluated too early and executed
too permanently. Fix the evaluation, and the system will teach itself
what it needs to learn.
