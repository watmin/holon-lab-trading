# Review: Hickey / Verdict: APPROVED

Proposal 049 is one of the clearest proposals in this series. A classifier.
Three words. One per candle. No prediction, no learning, no trading.
That's the right shape.

Questions 5 and 6 deserve precise answers because they determine where
complexity lands.

---

## 5. Where does the labeler live?

On the indicator bank. Full stop.

Look at what the indicator bank actually is. It's not a "bank of indicators."
It's a synchronous state machine that takes a RawCandle and produces a Candle.
`tick` is called once per candle. It advances 30+ streaming computations
and assembles a flat value struct. No channels. No threads. No messages.
A function call.

The labeler is the same kind of thing. It takes close and volume. It
maintains internal state (running extreme, current phase, tracking
direction). It produces a label. One call per candle. The label goes
on the Candle struct alongside RSI, ATR, and everything else.

The pivot tracker program from 047 is a different animal — it was a
program with its own loop, its own channel, its own lifecycle. That's
the wrong home for a pure computation. You don't need a program to
classify the present moment. You need a function that mutates an
accumulator and returns a value. That's what `step-rsi!` does. That's
what `step-phase!` should do.

The per-broker option (option 3) is wrong because the labeler's input
is closes — the same closes for every observer. There's nothing
broker-specific about "where is price relative to its recent structure?"
One labeler per post. On the bank. On the Candle.

**What goes on the Candle:** the current phase label (:valley, :peak,
:transition), the direction (for transitions), the duration of the
current phase, and the phase's range. That's four or five f64s plus
an enum. The same shape as every other indicator field.

The phase *history* (the sequence of confirmed phases) is richer. But
it doesn't go on the Candle. The Candle is a snapshot — "what is true
right now." The history is state that lives inside the bank, like the
ring buffers live inside the bank. Downstream consumers see the current
phase. If a vocabulary module needs the sequence (valley-to-valley
trend, peak-to-peak compression), it computes that from the bank's
internal state, the same way `compute-hurst` reads from `close-buf-48`.

---

## 6. Is the labeler's state richer than a streaming indicator?

It's richer than RSI. It's not richer than the indicator bank itself.

RSI has two accumulators (avg gain, avg loss) and a count. Three f64s
and a usize. Completely stateless in the sense that you never ask RSI
"what happened three phases ago."

The labeler has:
- A tracking direction (:high or :low) — one enum
- A running extreme (price and candle number) — two values
- The current phase record (label, direction, start, stats) — a struct
- A history of confirmed phases — a bounded Vec or ring buffer

That's a state machine with memory. RSI is a recurrence relation.
They're different in kind.

But this is not an argument against putting it on the bank. Look at
what's already there:

- `IchimokuState` — five ring buffers (9, 26, 52 period highs and lows),
  senkou spans projected 26 periods forward. That's a state machine too.
- `StochState` — high/low ring buffers plus a smoothed %D.
- The divergence detector — two ring buffers plus PELT peak detection
  across RSI and price.
- DFA — a 100-period buffer that gets detrended and segmented every tick.

The indicator bank already contains state machines more complex than
the phase labeler. The labeler's confirmed-phase history is a ring buffer
of structs — more structured than a ring buffer of f64s, but not
categorically different. The bank already manages heterogeneous state.
One more struct doesn't change its nature.

The key question is: does the labeler need to communicate with anything
other than its inputs (close, volume, ATR) and its output (the Candle)?
No. It reads price. It emits a label. Same contract as every other
indicator. The state is private. The output is a value on the Candle.

If the labeler needed to send messages, receive commands, or coordinate
with other components — that would make it a program. It doesn't. It's
a computation. A stateful one, but so is Ichimoku.

---

## The simplicity argument

Three options were proposed. The simplest is the one that adds no new
concepts. The indicator bank already exists. The Candle struct already
exists. The `tick` function already calls 30 step functions. Adding a
31st step function and a few fields to the Candle is the path that
introduces zero new architecture.

A standalone component or a program introduces a new thing to name, a
new thing to wire, a new lifecycle to manage. For what? A function that
reads close and returns an enum.

Put it on the bank. Call it in `tick`. Put the label on the Candle.
Done.
