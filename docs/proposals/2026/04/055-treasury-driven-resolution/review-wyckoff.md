# Review: Wyckoff

Verdict: APPROVED

## The broker proposes, the treasury validates

This is how a clearinghouse works. The floor trader reads the tape, makes
the decision, submits the order. The clearing firm checks margin, checks
the account, checks the arithmetic. The clearing firm does not know why
you bought. It knows whether you can pay.

The separation is correct. The broker thinks. The treasury counts. The
moment the treasury starts thinking about WHY a broker wants to exit,
you have coupled the bank to the strategy. Every bank that tried this
went broke backing its own opinions instead of enforcing its own rules.

The four-gate exit is the right structure. The first three gates are
mechanical filters -- phase, direction, arithmetic. They establish
whether exit is POSSIBLE. The fourth gate is the position observer's
experience -- whether exit is WISE. This mirrors how a tape reader
works: the conditions say you CAN sell, but the tape says not yet.
The experienced trader overrides the obvious signal. Gate 4 is that
experience, learned from every trigger the paper passed through.

## Wyckoff phases

The valley/peak trigger maps to accumulation/distribution evaluation
points. Wyckoff's method: you evaluate at the tests. You do not
evaluate during the markup or markdown -- those are transitions. The
proposal's "transition = hold, valley/peak = evaluate" is structurally
identical. The phase labeler is doing what I did by hand with pencil
marks on ticker tape. The machine does it every candle. Good.

The retroactive labeling of triggers is the key insight. A paper that
held through trigger T and later exited Grace at T+3 teaches the
machine that T was a HOLD. A paper that held through T and hit the
deadline teaches that T was an EXIT you missed. This is how you build
a tape reader's intuition -- not from the current tick, but from what
happened AFTER the current tick. The label arrives late. The learning
compounds.

## The headless treasury

Truly headless. The treasury knows who, what, when, how much. It does
not know why. It does not receive market observer predictions, phase
states, anxiety atoms, or vocabulary. It receives ExitProposal with
a paper_id and a price. It validates arithmetic. It records outcomes.

This is the only architecture that scales to multiple proposers. If the
treasury understood strategy, it would need to understand EVERY strategy.
The headless treasury understands one thing: did the arithmetic work?
The ledger is the proof. The survival rate is the gate. The proposer's
thoughts are the proposer's business.

The ProposerRecord struct is clean. Papers submitted, papers survived,
total Grace residue. Derived: survival rate, mean residue. The
predicate is a function of these measurements. Same predicate for
everyone. The small proposer and the whale play the same game. This
is correct -- the edge is in the thinking, not the capital.

## Deadline enforcement every candle

Every paper. Every candle. This is the carrying cost made visible. In
my day, the carrying cost was the interest on your margin loan and the
opportunity cost of tied-up capital. Here it is a hard deadline derived
from ATR. Volatile market, shorter deadline. Calm market, longer
deadline. The market sets the clock, not the trader.

The formula `base_deadline * (median_atr / current_atr)` is sound. High
volatility compresses the window -- prove it fast because the tape moves
fast. Low volatility extends it -- the tape is slow, patience is
warranted. One parameter (base_deadline) discovered through simulation.
The ATR adjusts to regime. This is not a magic number. It is the
treasury's expression of patience calibrated to conditions.

Step 1 of the per-candle flow runs autonomously -- the ONLY autonomous
treasury action. Everything else is reactive. This is correct. The
deadline is the one thing the treasury enforces without being asked.
The clock ticks whether the broker proposes or not.

## Paper as proof

This is reading the tape before you trade size. Every serious tape
reader I knew paper-traded first. Not as simulation -- as PROOF. The
paper runs on real prices with real deadlines. The interest (now
deadline) erodes unprofitable papers naturally. No one kills them.
The math kills them.

The proposer who survives on paper has demonstrated they can read the
tape. The gate opens. Real capital flows. The proposer who cannot
survive on paper never touches real money. This is the only honest
gate: measured outcomes on real data, not promises or backtests.

## One concern

054 specified interest as a per-candle cost that erodes the position.
055 replaces interest with a hard deadline. The deadline IS the time
pressure, but it is binary -- you are alive or you are dead. Interest
was continuous pressure that the anxiety atoms could encode as a
gradient. The deadline gives you `candles-remaining` and
`time-pressure` as anxiety, which is adequate, but the smooth cost
curve of interest had information the binary deadline does not.

This is a design choice, not a flaw. The deadline is simpler to
implement and reason about. The anxiety atoms still encode urgency.
The position observer still learns from the shape of that urgency.
But note: the deadline forgives a bad position that recovers just
before expiry. Interest would have punished it the entire time.

The proposal handles this correctly -- the residue math (gate 3)
still requires positive residue after fees. A position that drifted
badly and recovered barely above fees will exit with minimal residue.
The economics still punish weak positions through small rewards
rather than continuous cost.

Approved. The architecture is sound. Build it.
