# Review: Wyckoff
Verdict: CONDITIONAL

## The diagnosis is correct. The prescription needs refinement.

I have studied the measurements. The proposal sees what is happening clearly.
But it frames the problem as a gate problem. It is not a gate problem. It is
a phase problem. The system does not understand that markets — and learners —
move through phases, and that the phase that looks like death is often
accumulation.

## Answering the five questions

### Question 1: Should the broker gate ever permanently close?

**No. Never permanently.**

A campaign in markdown is not a dead campaign. It is a campaign in the
distribution-to-accumulation transition. The composite operator — the smart
money — does not stop watching a stock that has fallen. They watch MORE
carefully, because that is when accumulation begins.

Your gate is a binary: open or closed. Markets are not binary. A broker with
negative EV is not dead — it is in markdown. The correct response to markdown
is not to walk away. It is to reduce commitment and increase observation.

But "always open" is also wrong. A gate that never closes is a gate that does
not exist. You need the gate to MODULATE, not to kill.

The cold start window (50 of each outcome) is reasonable — that is the initial
trading range where you cannot yet read the tape. After that, the gate should
throttle, not slam shut. A broker with EV = -5.0 should register papers at
reduced frequency. A broker with EV = -50.0 should register papers rarely.
A broker with EV = +50.0 should register papers every candle.

**My answer: the gate should be a valve, not a switch.** Throttle paper
registration proportionally to EV. Negative EV means fewer papers, not zero
papers. The learning loop never dies. Capital exposure (funded trades) still
gates on positive EV — that is the real gate, and it already exists at the
treasury level.

### Question 2: Should papers be decoupled from the gate?

**Yes. This is the key insight and the proposal already sees it.**

Papers are observation. Funded trades are commitment. These are different
phases of a campaign. In Wyckoff terms:

- Papers = testing the market. Sending out probes. This is what the composite
  operator does during accumulation — small tests, no real commitment, just
  reading the tape.
- Funded trades = the markup campaign. Real capital, real commitment, based on
  proven edge.

The current system conflates testing with commitment. When EV goes negative,
it stops TESTING. That is like a trader who stops reading the tape because
their last trade lost money. The tape is free to read. The information is
free to collect. Only the execution costs money.

**Papers should always be registered.** Every candle, every broker, regardless
of EV. The gate should control ONLY whether the broker proposes funded trades
to the treasury. This is exactly how a professional operator works: always
watching, only acting when the phase is right.

### Question 3: The journey EMA alpha — should it adapt?

**The EMA is not the problem. The volume is the problem.**

An EMA with alpha=0.01 has a half-life of about 69 observations. Under
moderate volume, this is fine. Under 103,000 observations, the EMA has
converged 1,500 half-lives ago. It is no longer an EMA — it is a point
estimate of the mean error. And since the mean error drifts upward as the
exit observer degrades (because it is being trained on Violence-skewed data
from the survivors), the threshold drops below every new observation.

This is a classic effort-versus-result failure. The EFFORT is enormous
(103k observations). The RESULT is zero (grace_rate = 0.0). When effort
does not produce result, the mechanism is broken.

**Do not tune the alpha. Fix the volume imbalance.** The EMA works fine if
each broker grades its own journey independently (see Question 4). But if
you must keep a shared EMA, use a windowed quantile instead — "Grace if
below the 40th percentile of recent errors." A quantile is volume-invariant.
An EMA is not.

### Question 4: Should each broker have its own journey EMA?

**Yes. Absolutely yes.**

This is the most important structural change in the proposal, and the proposal
does not state it strongly enough.

The current architecture has 22 brokers feeding 2 exit observers. When 18
brokers die, the 4 survivors dominate the exit observer's training
distribution. This is like 4 floor traders controlling the entire tape — the
price they print is the price everyone sees, but it only represents THEIR
activity, not the market's.

Each broker already has `journey_ema` and `journey_count` fields. The code
already grades per-broker in `broker_program.rs` lines 144-173. But the
EXIT OBSERVER is shared — so the volume imbalance comes from 4 brokers
sending a flood of ExitLearn messages while 18 send zero.

**Each broker should grade its own journey and the exit observer should
receive a balanced diet.** If a broker is in accumulation (papers only, no
funded trades), its journey observations should still flow to the exit
observer. The exit observer needs to hear from ALL 22 brokers, not just the
4 survivors. The exit observer's training distribution should reflect the
market's diversity, not the survivors' dominance.

### Question 5: Is this a gate problem or a wiring problem?

**It is a wiring problem that the gate makes fatal.**

The wiring problem: market observer learning is coupled to broker survival.
If the broker dies, the market observer starves. But the market observer's
accuracy is INDEPENDENT of the broker's EV. wyckoff-position has 59.8%
accuracy — it SEES the market correctly. Its broker died because of
exit-side dynamics. The market observer is being punished for the exit
observer's failure.

This is like a brilliant analyst being fired because the trader who executes
their ideas used bad stops. The analysis was right. The execution was wrong.
The analyst should keep analyzing.

**Market observers should have an independent learning path.** Every paper
that resolves — regardless of which broker registered it — should teach the
market observer that predicted its direction. The market observer learns
"was my direction prediction correct?" That question has nothing to do with
the broker's EV or the exit observer's stop distances.

The gate makes this wiring problem fatal because it cuts ALL signals — both
the exit learning (which depends on the broker's paper management) and the
market learning (which does not). Decoupling papers from the gate (Question 2)
fixes this naturally: if papers always register, resolutions always flow,
and both observers always learn.

## The Wyckoff reading

What I see in the measurements is a market in forced liquidation. 18 of 22
participants were shaken out during the initial markdown. The 4 survivors
are not strong hands — they are lucky hands. The system has no mechanism
for re-accumulation. Once a participant is shaken out, they cannot
re-enter.

In a healthy market:
1. **Accumulation** — quiet building. Low volume, tight range. The broker
   registers papers, learns, but does not commit capital. EV is uncertain.
2. **Markup** — the trend. The broker's EV turns positive. Papers convert
   to funded proposals. Capital flows.
3. **Distribution** — the broker's edge erodes. EV flattens. Capital
   allocation decreases but observation continues.
4. **Markdown** — EV goes negative. The broker stops proposing funded trades
   but KEEPS WATCHING. Papers continue. Learning continues. The broker waits
   for the next accumulation phase.

The current system has phases 2 and 4 but not 1 and 3. There is no
accumulation — the broker either trades or dies. There is no distribution —
the broker either has positive EV or the gate slams shut.

## Conditions for approval

1. **Papers always register.** Every candle, every broker. The gate controls
   funded trade proposals only. Papers are the broker's tape-reading — they
   are free and they are essential.

2. **Market observer learning decoupled from broker EV.** Every paper
   resolution teaches the market observer. The market observer's learning
   loop is independent of the broker's survival.

3. **Journey grading is per-broker.** Each broker maintains its own journey
   EMA (already half-implemented). The exit observer receives observations
   from all 22 brokers, not just the survivors.

4. **The gate becomes a valve.** Replace the binary gate with a throttle on
   funded trade proposals. Negative EV reduces proposal frequency. It does
   not eliminate observation.

These four conditions preserve the accountability structure (brokers still
track EV, the treasury still gates capital) while ensuring the learning loop
never dies. The system can move through all four phases — accumulation,
markup, distribution, markdown — without permanent casualties.

The proposal sees the disease. These conditions ensure the cure does not
create a new one.
