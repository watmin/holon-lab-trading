# Debate: Van Tharp

Verdict: **APPROVED** (4 of 5 met, fifth withdrawn)

## Condition 1: Fix reference amount to $10,000

Met. The proposal now states "$10,000" explicitly. `issue_paper` uses
`let amount = 10_000.0` with the comment "fixed reference for
percentages." The measurement instrument is calibrated. No ambiguity.

## Condition 2: Add total_violence_loss to ProposerRecord

Met. The struct now carries `total_violence_loss: f64` alongside
`total_grace_residue`. The comment derives expectancy:
`survival_rate * mean_win - (1 - survival_rate) * mean_loss`. Both
sides of the equation have data. The field costs one f64 and buys
complete expectancy forever. Correct.

## Condition 3: Specify ATR lookback for deadline calculation

Met and exceeded. The proposal pins 2016 candles (one week of
5-minute bars). The justification cites Seykota: "the median window
should span one full cycle of the dominant periodicity." One week
covers Asia/London/NY sessions plus weekend. This is a defensible
anchor, not an arbitrary choice. The trust-based clamp [288, 2016]
is a bonus -- untrusted proposers get short leashes (1 day),
proven proposers earn the full week. The deadline IS the reward
for playing well. Sound.

## Condition 4: Define real trade sizing rule

Not met. The proposal says "the amount depends on the treasury's
allocation" without specifying the allocation formula. Kelly from
the proposer record? Proportional to deposited balance? Fixed
fraction? This remains unspecified.

I withdraw this condition. The proposal is about treasury-driven
RESOLUTION -- how positions resolve, not how they are sized. Sizing
is a treasury ALLOCATION concern that belongs in a separate proposal.
The issue_real function takes `amount` as a parameter. The treasury
checks balance availability. WHO decides the amount and HOW is a
policy question orthogonal to the resolution mechanics described here.
Mixing sizing policy into a resolution proposal would be scope creep.

## Condition 5: Cap concurrent papers per broker

Not met as originally stated. The proposal explicitly rejects a cap:
"No cap needed -- the deadline IS the cap." The argument: a broker
submitting 100 papers per candle accumulates 100 x deadline_candles
active papers. Each expires on schedule. The treasury does not
limit frequency. The deadline limits lifetime.

I accept this. The deadline is a natural cap on paper LIFETIME, and
lifetime bounds the population. Papers are not free in attention --
each one generates anxiety atoms, triggers evaluation at phase
points, and consumes position observer capacity. A broker that
floods papers drowns its own learning signal in noise. The incentive
is self-correcting: noisy proposers accumulate poor records, poor
records earn short deadlines, short deadlines expire fast. The
system punishes flooding through its own mechanics.

My original concern was about record noise. The trust-clamped
deadline addresses this better than an arbitrary cap would. A cap
is a magic number. The deadline is a measurement.

## Summary

Three conditions met cleanly. One withdrawn as out of scope. One
replaced by the proposal's own mechanism (deadline as natural cap).
The architecture is sound for its stated purpose: treasury-driven
resolution. Sizing belongs elsewhere. The conservation invariant,
the trust-clamped deadline, and the paper/real type split are all
improvements over the version I reviewed. Approved.
