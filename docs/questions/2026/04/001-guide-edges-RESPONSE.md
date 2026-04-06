# Response to Question 001: Guide Edges

The builder's answers. Some fix the guide. Some are coordinates for later.

## Q1: Trade sizing
Kelly function exists from earlier work. The ignorant default state is
ignorance — start with nothing, learn sizing. Coordinate for later.

## Q2: Trade direction
The market observer predicts a reversal — a change is imminent. It is
rewarded for being right and punished for being wrong. Win/Loss is
meaningless at the observer level — that's a higher-order measurement
the reckoner handles. The guide needs fixing. The observer predicts
direction. The reckoner measures Win/Loss.

**Fix the guide.**

## Q3: Broker set cardinality
N market × M exit. Generic for more dimensions later (× A × B × C...).
For now, just M market × N exit. The guide wasn't clear enough.

**Fix the guide.**

## Q4: Broker-to-observer access
The broker IS composed of (market, exit). It HAS access to them.
The question's framing is confusing — the broker doesn't need a
"mutable bridge." It uses names to find observers on the post.
Or refs are passed in. Need to understand which.

**Needs more thought.**

## Q5: Proposal assembly
The broker proposes. The market and exit observers provide inputs.
candle → market observer → exit observer → broker. The broker is the
proposer. The proposer is also responsible for trade management —
changing the trigger conditions. The broker manages papers, proposes
trades, and manages active trade triggers.

**Fix the guide.**

## Q6: Active trade stop updates
Phase 3 of the 4-step loop:
1. RESOLVE — address triggers, settle
2. COMPUTE+DISPATCH — candle → market → exit → proposals
3. PROCESS — use fresh market data to query the broker for active
   trade trigger updates. The market data questions the broker NOW.
4. COLLECT+FUND — treasury funds or rejects

**Fix the guide.**

## Q7: Distance units
The scalar return value from the exit observer's reckoner defines the
trigger condition. It is applied to the price to make a condition
statement — the trigger. WHAT the scalar is and HOW it's applied to
price — these coordinates are not known yet. Something exists in
wat-archived or Rust that attempts this.

**Coordinate for later.**

## Q8: Cold-start behavior
The reckoner does not participate when it knows it doesn't know enough.
Gate action on ignorance. The structure reveals this — an empty reckoner
returns default, the experience() is 0.0, the funding() is 0.0.
No special bootstrap logic. The architecture IS the bootstrap.

**Fix the guide.**

## Q9: Paper trade distance source
Paper trades and active trades are treated equally. Both use whatever
the reckoner knows at the time. Start in ignorance (crutch values).
Learn grace vs violence. The reckoner chooses. Papers are the fast
learning stream — they feed the reckoner, the reckoner gets better,
papers get better distances. The loop.

**Fix the guide.**

## Q10: Cache parallelism
The ThoughtEncoder is declared immutable and shared, but it contains a
mutable LRU cache. Under par_iter this is a problem. An algorithm exists
but the coordinates are not known. Need to think on this.

**Coordinate for later.**

## Q11: Risk architecture
Risk does not exist yet. It is believed to exist at a future state. Its
purpose is to protect the treasury. The treasury will consult prior to
opening a trade. For now, risk says yes to all — or it does not exist
and has no consultation. Building the machine reveals its nature.

**Coordinate for later.**

## Q12: Exit generalist scope
Exit generalist is not special. It IS an exit observer. The generalist
is just another lens — we said this for market observers, and it applies
equally to exit observers. Phrasing problem in the guide.

**Fix the guide.**
