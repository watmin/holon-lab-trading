# Resolution: Proposal 054 — Interest-Bearing Positions

**Status:** APPROVED — unanimous after two rounds.

Five designers. Two rounds. Zero rejections. The game is found.

## The game

The treasury is the bank. The broker borrows. The interest never
stops. Every candle. Every position. The twist compounds. You
outrun it or you don't.

Entry: the phase labeler detects structure (3+ higher lows, 3+
lower highs). The broker enters during the active condition.
The broker borrows from the treasury. The clock starts.

Hold: the interest accrues every candle. The broker holds. The
position grows or bleeds. The anxiety is the thought.

Exit (Grace): phase trigger (valley for longs, peak for shorts)
AND market observer predicts against your direction AND residue
covers interest + exit fee. All three true → exit. Recover
principal. Pay interest. Keep the residue. Permanent.

Exit (Violence): interest exceeds position value. EVERY CANDLE
this is checked. Not at triggers. Every candle. The interest
never sleeps. The treasury reclaims the position. The broker
loses its claim. The asset stays in the treasury. The broker
is punished through its record.

## The headless treasury

The treasury has no mind. It is a program with a ledger. It
does not know why the broker entered. It does not know the
vocabulary, the predictions, the confidence, the strategy. It
knows: who borrowed what, when, how much interest has accrued,
and whether the position produced Grace or Violence.

The treasury is intentionally ignorant of the proposer's thoughts.
Outcomes are public. Strategy is private. The proposer who reveals
nothing and produces Grace is funded. The proposer who publishes
everything and produces Violence is denied.

## Earning favor

Each proposer maps to a struct. The struct contains measurable
data derived from the ledger: papers submitted, papers survived,
mean Grace residue. The treasury applies a uniform predicate.
Same threshold for everyone. Fund or deny.

No record → no real capital. The proposer must pay to build the
record through paper submissions. Paper costs: gas on Solana,
computation in the lab. The proposer invests in proving themselves
before the treasury risks its funds.

If you borrow our money to gamble, you gamble well. And you
prove yourself through paper submissions first. The enterprise
demands good players.

## What was decided

**Unanimous across all five:**
- Interest as the only stop loss. No price triggers. No distances.
- ATR-proportional rate. Breathes with the market.
- Discrete reckoner on position observer. Exit or hold. Not distances.
- Phase-based entry. 3+ higher lows / lower highs.
- Three-condition exit. Phase trigger + market direction + residue math.
- Paper survival as the gate to real capital.
- Headless treasury. Blind to strategy. Judges outcomes.
- Both sides simultaneously. Longs and shorts can coexist.
- Violence checked every candle. The interest never stops.
- Automatic reclaim. No grace period. No appeals.

**Resolved from debate:**
- Favor system replaced with proposer record (struct + predicate).
  Hickey's condition met. No identity-based preferences. No
  asymmetric decay. No rehabilitation protocol. The trailing
  window forgets automatically.
- Correlated samples (Van Tharp) addressed at the measurement
  level inside the struct. Papers from the same phase window
  count as one cluster. Not an architectural change.
- Expectancy (Van Tharp) captured by survival rate + mean Grace
  residue. Two numbers. The struct carries both. The predicate
  reads both.

## What this replaces

- Distance-based triggers → phase transitions + market prediction
- Continuous reckoner (distance prediction) → discrete reckoner (exit or hold)
- Simulation sweep → interest is the teacher
- Paper stacking (8,000 never resolving) → interest kills dead papers every candle
- Stop loss as price level → interest as time cost
- Separate proof curve / EV gate → paper survival IS the proof

## What this keeps

- Phase labeler (2.0 ATR smoothing)
- Market observer (direction prediction)
- Position observer (new job: exit advisor, discrete)
- Broker as accountability unit
- Accumulation model (deploy, recover principal, keep residue)
- ThoughtAST (anxiety atoms are just more facts)
- The pipes (same CSP, same 30+ threads)

## The voices

| Voice | Verdict | Key Contribution |
|-------|---------|------------------|
| Seykota | APPROVED | Interest selects for runners. ATR-proportional. |
| Van Tharp | APPROVED | Correlated samples. Struct must carry expectancy. |
| Wyckoff | APPROVED | Violence every candle. Treasury must not think. |
| Hickey | APPROVED | Strip the favor mechanism. Measurement suffices. |
| Beckman | APPROVED | Algebraically closed. Pure fold from ledger to gate. |

## Implementation notes

- Wyckoff's warning: Violence must be evaluated EVERY CANDLE,
  not just at phase triggers. A position can die between triggers.
  The interest check runs in the paper tick loop, not in the
  exit evaluation.

- The interest rate: ATR-proportional, set by the treasury's
  configuration. One rate for everyone. Breathes with volatility.
  The ONE parameter.

- The proposer struct: implementation detail. For the lab:
  survival rate + mean residue over a trailing window with
  minimum paper count. For Solana: can be more exotic later.

- The position observer's reckoner: changes from Continuous to
  Discrete. Two labels: Exit, Hold. The anxiety atoms bundle
  with market thoughts. The reckoner learns which shapes of
  anxiety at which triggers precede Grace exits.

It hurts to lose. It pays to win.

**PERSEVERARE.**
