# Review: Wyckoff / Verdict: APPROVED

## The tape reader as a program

Yes. This is correct. I have been waiting for someone to say it
plainly.

In 045 I said the post should own pivot detection — one tape
reader, not M redundant copies. The concern was factoring: the
conviction stream comes from a single market observer, the pivot
classification is deterministic given that stream, therefore one
tracker per market observer. No duplication. That was the right
instinct. But 045 left the question of WHERE that single tracker
lives half-answered. 046 tried to answer it and placed the
tracker on the main thread. That was wrong, and this proposal
explains exactly why.

The main thread is the wire. The ticker tape runs through it,
but the tape reader does not sit inside the telegraph machine.
The tape reader sits at his own desk, receives the stream,
maintains his own state, and answers questions when asked. That
is what a program is. The telegraph operator routes messages.
The tape reader reads them.

## Question 1: Query frequency

22 queries per candle — 2 exit observers times 11 market
pairings — is the right frequency. An exit observer needs the
pivot state AT THE MOMENT IT DECIDES. Not before. Not a stale
snapshot from the previous candle pushed to it by the main
thread. The exit observer says "what does the tape look like
for market observer 7 RIGHT NOW?" and gets an immediate answer.

This is how a tape reader works. You do not read the tape once
in the morning and carry a summary. You read it when you need
to act. The exit observer acts per-candle, per-slot. Therefore
it queries per-candle, per-slot.

22 queries returning bounded snapshots (20 records, ~2KB each)
is nothing. The cost is a channel round-trip. The value is
FRESH data at the moment of decision. This is the right
tradeoff.

## Question 2: Tick ordering

The ordering is guaranteed by the topology and I will explain
why it does not matter even if it were not.

The main thread collects all 11 market chains BEFORE sending
them to exit observers. The market observers send their ticks
as fire-and-forget AFTER encoding — which happens before the
main thread collects the chain. By the time the main thread
has collected all 11 chains and is ready to fan out to exit
slots, the ticks have been sent. The tracker drains ticks
before servicing queries. The exit observer queries after
receiving the chain from the main thread. Therefore: ticks
arrive before queries. The natural pipeline ordering enforces
this without explicit synchronization.

But even if a tick arrived LATE — say market observer 7's tick
for candle N arrives after the exit observer queries for candle
N — the damage is bounded. The exit observer sees the pivot
state as of candle N-1. One candle of staleness. The next
candle corrects it. In tape reading, a one-tick delay does not
change the structure. The pivot is a PERIOD — it lasts many
candles. Missing the first candle of a new pivot by one tick
is irrelevant to the series interpretation.

Do not add synchronization barriers to solve a problem that
does not exist.

## What this gets right

The drain-writes-before-reads discipline. This is the tape
reader's discipline: process all incoming prints before
answering any question. You do not answer "what is the trend?"
while prints are still arriving. You process the full batch,
THEN you speak. The cache does this. The tracker does this.
It is the same pattern because it is the same problem — a
single authority maintaining state from a concurrent stream.

The bounded memory of 20 periods. A tape reader does not
remember every trade from January. He remembers the recent
structure — the last several swings, the current phase. 20
periods (roughly 10 pivots and 10 gaps) is the right depth
for structural context without drowning in history.

The fire-and-forget writes from market observers. The market
observer's job is to predict direction. It should not wait for
the tracker to acknowledge receipt. It sends the tick and moves
on. The tracker processes it when it can. This is the natural
relationship between the specialist on the floor (producing
price action) and the tape reader in his office (interpreting
it).

## One observation

The `conviction-sum` field on `current-period` exists only for
pivots, not gaps. This is correct — conviction during a gap is
noise by definition. But I note that the TRANSITION from gap
to pivot carries information. The conviction at the first
candle of a new pivot — how far above the threshold it jumped
— tells you something about the force of the new move. A pivot
that begins at the 82nd percentile is different from one that
begins at the 99th. The tracker records the running sum and
count, from which you get the average. Good. But the ENTRY
conviction — the first tick of a new pivot period — might be
worth recording separately. The opening print of a new campaign
tells you what kind of campaign it will be.

This is not a blocking concern. It is an observation for a
future proposal.
