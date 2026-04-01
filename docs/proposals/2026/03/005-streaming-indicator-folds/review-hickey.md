# Review: Rich Hickey

Verdict: CONDITIONAL

## What the proposal gets right

The diagnosis is precise. `(field raw-candle rsi (wilder-rsi close 14))` declares
a property of a candle. RSI is not a property of a candle. It is the output of a
*process* that has consumed every candle before this one. The current spec lies
about what these things are, and when your specification lies, your program
inherits the lie. Dissolving the 52-field struct and the 17 phantoms is the right
move. You should do it.

The two-concern split is also correct in its observation: indicator state and the
raw candle window are different things. One is derived signal, the other is raw
material. They have different lifetimes, different memory profiles, different
consumers.

## Where I have concerns

### Closures are complecting two things

A closure is a function bundled with its environment. You are using closures here
as *objects* -- things with identity, state, and behavior. That is what they
become when you close over mutable state. `make-wilder` returns something that
you must feed in order, that remembers what you fed it, that gives different
answers depending on its history. That is an object. You have reinvented objects
using closures, and in doing so you have complected the computation (Wilder
smoothing) with the state management (maintaining `prev` and `count`).

This matters because:

1. You cannot inspect the state. What is the current value of `prev` inside a
   Wilder closure? You cannot ask. You cannot serialize it. You cannot checkpoint
   it. You cannot compare two indicator banks for equality. The state is trapped
   inside the closure.

2. You cannot replay from a checkpoint. If you want to resume from candle 400,000,
   you must replay from candle 0. Every closure must be fed every candle again.
   The state is opaque.

3. You cannot test the state transitions independently of the computation. The
   Wilder smoothing formula and the Wilder state machine are one inseparable
   thing. You test them together or not at all.

What you actually want is a value -- a plain data structure -- that represents
the state of each indicator, plus a pure function that takes (state, input) and
returns (new-state, output). This is the fold pattern you already use for the
enterprise: `(state, event) -> state`. Indicator computation is the same shape.

```scheme
;; State is data. Computation is a pure function. They are separate concerns.
(struct wilder-state count accum prev)

(define (wilder-step period state value)
  (let ((count (+ (:count state) 1)))
    (if (<= count period)
        (let ((accum (+ (:accum state) value)))
          (values (wilder-state count accum (if (= count period) (/ accum period) (:prev state)))
                  (/ accum count)))
        (let ((new (/ (+ (* (:prev state) (- period 1)) value) period)))
          (values (wilder-state count (:accum state) new)
                  new)))))
```

Now the state is a value. You can print it, compare it, serialize it, checkpoint
it, restore it. The computation is a pure function. You can test it with
constructed states. You can reason about it in isolation. No mutation.

### The indicator bank question answers itself

The proposal asks: flat list or named struct? Neither. The indicator bank should
be a *value* -- a struct whose fields are the indicator states. Not the closures.
Not the outputs. The states.

```scheme
(struct indicator-bank
  sma20-state sma50-state sma200-state
  rsi-state
  macd-ema12-state macd-ema26-state macd-signal-state
  ;; ... one state per indicator
  )
```

This is a product type. It has names. It has structure. You can declare it in
wat. You can type-check access to it. You can serialize the entire bank as one
value. The question "flat list or named struct" only arises because closures
hide state -- when state is data, it obviously belongs in a struct.

### Mutation inside closures is not acceptable

The proposal asks whether `set!` inside closures is acceptable for a
specification language. No. It is not. Not because mutation is always wrong, but
because *hidden* mutation is always wrong. `set!` inside a closure mutates state
that no caller can see, verify, or reason about. The wat language provides
`set!` as a compilation target for `&mut self` in Rust -- that is explicit,
bounded, visible mutation on a value the caller owns. Closing over `set!` turns
visible mutation into invisible mutation. The caller of a Wilder closure has no
idea that calling it changes state. The function signature is `(value) -> Float`.
That is a lie. The true signature is `(&mut self, value) -> Float`, but the
closure hides the `&mut self`.

If you use the fold pattern, mutation becomes unnecessary. Each step takes a
state value and returns a new state value. The Rust compiler can optimize this
into in-place mutation where appropriate. You get the performance of mutation
with the semantics of values.

### Shared vs per-observer candle window

Per-observer. This is not even a close call. The proposal notes that different
observers have different retention policies. That is sufficient. But the deeper
reason is: shared mutable state is the root of all evil in concurrent systems.
Even if you are single-threaded today, a shared window is a place -- a thing
with identity that changes over time. Per-observer windows are values -- each
observer has its own, manages its own, cannot corrupt another's.

The memory argument for sharing is a premature optimization. You have six
observers. Six ring buffers of OHLCV floats. At 200 candles deep (the maximum
SMA period), that is 6 x 200 x 6 floats = 7,200 f64s = 57 KB. You were
holding 652k x 52 fields in memory before. This is not the place to save.

### The two-concern split holds, but the boundary is wrong

The proposal says: indicator state is one concern, candle window is another.
True. But look at what `make-sma` does -- it maintains a deque of values. That
is a window. Look at what the candle window does -- it maintains a ring buffer
of candles. That is also a window. The difference is not in the mechanism, it is
in the level of abstraction: indicator state is derived from scalar series,
candle windows store structured records.

The real split is:

1. **Scalar stream processors** -- things that consume one number at a time and
   produce one number. SMA, EMA, Wilder, RSI, MACD. These need only their own
   state (a struct) and one input value per step.

2. **Spatial pattern recognizers** -- things that need to see multiple raw candles
   simultaneously. Ichimoku, Fibonacci, PELT, divergence. These need a window
   of raw candles.

The first group does not need a window at all. `make-sma` maintaining its own
deque is the closure version reinventing what should be state in the fold. A
Wilder smoother needs two floats, not a window. An EMA needs one float, not a
window. Only SMA and Bollinger need a buffer, and even there, it is a fixed-size
ring buffer that is part of the state struct, not a separate concern.

## Conditions for approval

1. **Replace closures with fold steps.** Each indicator is a pair: a state struct
   (a value) and a pure step function `(state, input) -> (state, output)`. No
   closures. No hidden mutation. State is data, computation is function. They are
   separate.

2. **The indicator bank is a struct of states, not a list of closures.** Named
   fields. Declared in wat. Serializable, checkpointable, inspectable.

3. **Per-observer candle windows.** No sharing. Values, not places.

4. **No `set!` in indicator computation.** The step functions are pure. Mutation,
   if needed, happens in Rust as an optimization of the value semantics, not in
   the specification.

5. **Keep the two-concern split, but name it correctly.** Scalar stream processors
   (fold state + step function) vs. spatial pattern recognizers (raw candle window).
   The first group should not maintain windows internally -- their state structs
   carry exactly what they need.

The proposal has the right instinct. The 52-field lie needs to die. The streaming
model is correct. But closures-with-mutation is the wrong mechanism. You have
already discovered the right mechanism -- it is the fold at the heart of your
enterprise. `(state, event) -> state`. Use it here too. The indicator engine is
just another fold inside the fold.

Simple made easy.
