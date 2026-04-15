# Resolution: Proposal 055 — Treasury-Driven Resolution

**Status:** APPROVED — unanimous after debate.

Five designers. Two rounds. Zero rejections. Build it.

## The game

The treasury is the bank. The broker borrows. The deadline is
the clock. The broker thinks. The treasury counts. The market
decides.

## What was decided

### The structs

**PositionState** — one enum, not bool + Option:
- `Active` — open, clock ticking
- `Grace { residue: f64 }` — exited profitably
- `Violence` — deadline hit, reclaimed

**PaperPosition** — fixed $10,000 reference. Proof of thoughts.
No capital moves. Always issued. The cost is computation (lab)
or gas (Solana).

**RealPosition** — actual capital. Requires proven record.
Treasury moves balances. Distinct type, distinct issuance.

**ProposerRecord** — papers_submitted, papers_survived,
papers_failed, total_grace_residue, total_violence_loss.
Expectancy derivable at query time. The gate reads this.

### The separation

The broker proposes. The treasury validates arithmetic.

The treasury does NOT know: the phase, the market prediction,
the position observer's opinion, the vocabulary, the strategy.
The treasury knows: who borrowed what, when, the deadline, and
whether the math works at exit time.

The treasury's only autonomous action: deadline enforcement
every candle. Everything else is reactive — validate when asked.

### The four gates

At trigger points (valleys for longs, peaks for shorts):

1. **Phase trigger** — are we at an evaluation point? (prerequisite)
2. **Market direction** — does the market predict against me? (prerequisite)
3. **Residue math** — can I exit profitably after fees? (prerequisite)
4. **Position observer** — should I? Exit or Hold. (the decision)

Gates 1-3 are arithmetic. Gate 4 is learned. Gate 4 can override
gate 2 — experience trumps simple conditions.

### The two labels

Position observer: discrete reckoner. Exit or Hold.

Retroactive labeling — when a paper resolves, every trigger it
passed through gets labeled:
- Exited Grace at trigger T → T labeled Exit
- Held through T, later Grace → T labeled Hold
- Held through T, hit deadline → T labeled Exit (should have left)

### The deadline

ATR-proportional. Median ATR over one week (2016 candles).
`deadline = base * (median_atr / current_atr)`.

Clamped by trust:
- Untrusted: max 288 candles (1 day)
- Fully trusted: up to 2016 candles (1 week)

The proposer's record determines where in [288, 2016] they land.
The trust IS the deadline. The deadline IS the reward.

### The residue split

Half to the proposer. Half to the pool.

The proposer's half: credited to their deposit balance. The
honest reward for good thoughts.

The pool's half: all depositors benefit proportionally. Passive
yield from the treasury's growth.

50/50 is a parameter, not a law. The principle: proposers must
be rewarded, depositors must benefit. The split is the alignment.

### Two claim states

**Deposited** — available. Earns passive yield. Withdrawable
via queue (contract concern, not lab).

**In trade** — reserved to active real positions. Locked until
resolution. Papers never reserve capital.

### The conservation invariant

```
sum(deposited) + sum(in-trade at current prices)
= sum(all deposits) - sum(all fees) + sum(all residue)
```

Testable every candle. The treasury cannot create or destroy
value. Fees are the only real cost (venue, not treasury).
The invariant IS the ward.

### Proof of Grace

Depositors are stakers. Proposers are validators. Grace residue
is the yield. Not proof of stake. Not proof of work. Proof of
Grace. The yield comes from measured trading outcomes — actual
assets moved profitably.

Nobody benefits from Violence.

## What this replaces

- Distance-based triggers → phase triggers + four gates
- Continuous reckoner (distances) → discrete reckoner (Exit/Hold)
- Simulation sweep → deadline is the teacher
- Paper stacking (8,000 never resolving) → deadline kills dead papers
- Stop loss as price level → deadline as time cost
- Broker-driven resolution → treasury-driven (deadline) + broker-proposed (Grace)

## What this keeps

- Phase labeler (2.0 ATR, one week history)
- Market observer (direction prediction)
- Position observer (new job: fourth gate, Exit/Hold)
- Broker as accountability unit
- Accumulation model
- ThoughtAST (anxiety atoms)
- The pipes (same CSP, same threads)

## The voices

| Voice | Verdict | Key Contribution |
|-------|---------|------------------|
| Seykota | APPROVED | Selection over prediction. Build it. |
| Van Tharp | APPROVED | Expectancy in the record. $10K reference. |
| Wyckoff | APPROVED | Headless treasury truly headless. |
| Hickey | APPROVED | Enum state. Paper/real split. Deadline named. |
| Beckman | APPROVED | Conservation invariant. Algebraically closed. |

It hurts to lose. It pays to win.

Nobody benefits from Violence.

**PERSEVERARE.**
