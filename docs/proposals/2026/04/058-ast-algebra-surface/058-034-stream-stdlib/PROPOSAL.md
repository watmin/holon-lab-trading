# 058-034: `:wat::std::stream` — CSP Pipeline Stdlib

**Scope:** algebra stdlib (runtime combinators over kernel primitives)
**Class:** STDLIB — **INSCRIPTION 2026-04-20**
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-031-defmacro (variadic), 058-030-types
(typealias expansion, reduce), 058-033-try (error propagation in
Result-returning stages), FOUNDATION's kernel primitives
(spawn / send / recv / select / drop / join / HandlePool)

---

## INSCRIPTION

Code led, spec follows — the *inscription* pattern. This
proposal records what wat-rs shipped on 2026-04-20 under
`wat/std/stream.wat` plus the four supporting changes that
landed around it. Code and prose are reflections; this document
brings the prose into parity with the shipped code. If the two
disagree, the code wins; the doc catches up.

wat-rs arc reference: `docs/arc/2026/04/004-lazy-sequences-and-pipelines/`
(DESIGN.md + BACKLOG.md + INSCRIPTION.md). Every design decision
and rejected candidate lives there; this proposal is the
summary for the 058 audit trail.

---

## The surface

Seven wat-level forms plus one typealias, all under
`:wat::std::stream::*`:

### Typealiases

```scheme
(:wat::core::typealias
  :wat::std::stream::Stream<T>
  :(rust::crossbeam_channel::Receiver<T>,wat::kernel::ProgramHandle<()>))

(:wat::core::typealias
  :wat::std::stream::Producer<T>
  :fn(rust::crossbeam_channel::Sender<T>)->())
```

- **`Stream<T>`** — a live channel + the handle to the producer
  feeding it. Same shape as `Console` / `Cache` stdlib programs
  return: `(HandlePool, driver-handle)`. The typealias becomes
  interchangeable with its tuple expansion via `reduce`
  (058-030's 2026-04-20 amendment).
- **`Producer<T>`** — the function shape `spawn-producer`
  accepts: takes the Sender end of a bounded queue, writes
  values, returns when done.

### Source constructors

```scheme
(:wat::std::stream::spawn-producer<T>
  (producer :wat::std::stream::Producer<T>)
  -> :wat::std::stream::Stream<T>)
```

Spawns a producer function on a new thread, wires a
`bounded(1)` queue, returns the Stream. The producer writes
values to the sender until done; the drop cascade on its
exit lets downstream consumers see EOS cleanly.

### Intermediate combinators (Stream → Stream)

```scheme
(:wat::std::stream::map<T,U>
  (upstream :wat::std::stream::Stream<T>)
  (f :fn(T)->U)
  -> :wat::std::stream::Stream<U>)

(:wat::std::stream::filter<T>
  (upstream :wat::std::stream::Stream<T>)
  (pred :fn(T)->bool)
  -> :wat::std::stream::Stream<T>)

(:wat::std::stream::chunks<T>
  (upstream :wat::std::stream::Stream<T>)
  (size :i64)
  -> :wat::std::stream::Stream<Vec<T>>)
```

Each combinator spawns ONE worker program and wires a
`bounded(1)` queue. The worker is tail-recursive on `match recv
→ Some/None`: on `Some`, do the work + `send` downstream (with
`:Option<()>` match to exit cleanly if the consumer dropped); on
`:None`, exit. TCO (arc 003) is what lets these workers run
indefinitely.

**`chunks` is the canonical stateful-stage pattern.** State
(the accumulating `Vec<T>`) threads through the worker as a
parameter — no mutation; the recursion carries it. On
upstream `:None` (end-of-stream), flushes the partial
accumulator if non-empty. Every future stateful stage
(window, dedup, throttle, time-window) follows this pattern.

### Terminal combinators

```scheme
(:wat::std::stream::for-each<T>
  (stream :wat::std::stream::Stream<T>)
  (handler :fn(T)->())
  -> :())

(:wat::std::stream::collect<T>
  (stream :wat::std::stream::Stream<T>)
  -> :Vec<T>)

(:wat::std::stream::fold<T,Acc>
  (stream :wat::std::stream::Stream<T>)
  (init :Acc)
  (f :fn(Acc,T)->Acc)
  -> :Acc)
```

Terminal combinators drive the pipeline from the calling
thread — no new worker spawned. They recv to end-of-stream,
join the stream's handle, and return the aggregate (or `:()`
for `for-each`). `collect` is `fold init=[] f=conj`; `fold` is
the general aggregator.

---

## Composition via `let*` — the idiomatic shape

wat-rs ships seven combinators; it does NOT ship a `pipeline`
one-liner composer. The rejection is in the arc 004 BACKLOG,
but the summary: `let*` already IS the pipeline, and a
`(pipeline src (map :f) (chunks 50) sink)` macro that
eliminated the per-stage type annotations would trade wat's
typed-binding discipline (058-030) for conciseness — wat has
consistently picked honesty.

The idiomatic shape:

```scheme
(:wat::core::let*
  (((source   :wat::std::stream::Stream<i64>)
    (:wat::std::stream::spawn-producer :my::app::source))
   ((enriched :wat::std::stream::Stream<EnrichedT>)
    (:wat::std::stream::map source :my::app::enrich))
   ((batched  :wat::std::stream::Stream<Vec<EnrichedT>>)
    (:wat::std::stream::chunks enriched 50))
   ((aggreg   :wat::std::stream::Stream<AggregT>)
    (:wat::std::stream::map batched :my::app::aggregate))
   ((_ :()) (:wat::std::stream::for-each aggreg :my::app::handle-result)))
  ())
```

Each binding carries a **name** (stage reachable by semantic
role), a **type** (what's flowing at that point, for both
reader and checker), and a **RHS** (the stage constructor).
The `source → enriched → batched → aggreg → for-each` chain is
explicit, typed, and composes concurrent stages in the order a
human reads.

---

## Shipped supporting changes (2026-04-20 session)

Four supporting changes in wat-rs shipped alongside the stream
stdlib. Each deserves its own amendment in its home proposal
(see "Downstream inscriptions" at the end); inlined here for
traceability:

### 1. `:wat::kernel::send` returns `:Option<()>` — symmetric with `recv`

Kernel channel endpoints now report disconnect through one
shape: `recv` returned `:Option<T>` already; `send` now
returns `:Option<()>` instead of raising
`ChannelDisconnected`. `(Some ())` on a successful send; `:None`
when the receiver has been dropped.

Forcing function: every stream stage's internal worker calls
`send` on its downstream endpoint. With the old raising
behavior, a consumer dropping would crash the stage's thread.
With `:Option<()>` symmetry, the stage matches on the send
result and exits cleanly — the drop cascade works without
panics anywhere in the chain.

Earlier drafts of arc 004's design proposed a separate
`:wat::kernel::send-or-stop` primitive. Rejected in favor of
making `send` itself Option-returning. One primitive, one rule,
no asymmetry between endpoints.

wat-rs commit `df3ca03`.

### 2. `:wat::kernel::spawn` accepts lambda values

Spawn's first argument now may be either a keyword-path literal
(classic named-define path) OR any expression evaluating to a
`:wat::core::lambda` value. Both produce the same `Arc<Function>`
under the hood; the trampoline inside `apply_function` handles
both (closed_env for lambdas, fresh root for defines).

Forcing function: `spawn-producer` accepts a
`:fn(Sender<T>)->()` value — callers pass lambdas (typical) or
named-define paths (also allowed). Without this, stream
combinators would have needed a generic-worker-takes-lambda-as-arg
workaround to route caller-supplied functions across the spawn
boundary.

Spec tension: FOUNDATION's "Programs are userland" conformance
contract stated "a spawnable program is a function named by
keyword path in the static symbol table." Relaxed to "any
`Arc<Function>` value" — named defines AND lambda values both
qualify. Same conformance rules otherwise (returns its final
state, observes the drop cascade, no self-pipes, etc.).

wat-rs commit `5fbdb87`.

### 3. TCO — named defines and lambdas

Tail-call optimization in the wat-vm evaluator. Stage 1 covered
named defines via `sym.functions`. Stage 2 added three detection
paths for lambda-valued tail calls: keyword head resolving to a
named function, bare-symbol head resolving to a lambda value in
env, inline-lambda-literal head `((lambda ...) args)`.

Forcing function: every stream combinator's internal worker is
tail-recursive on `recv → Some/None`. Without TCO, a stage
processing K messages burns K Rust stack frames. With TCO, each
stage runs indefinitely in constant stack — what the CSP
pattern demands.

wat-rs commits `32e918b` (Stage 1) + `9089867` (Stage 2).
Complete inscription at `wat-rs/docs/arc/2026/04/003-tail-call-optimization/INSCRIPTION.md`.

### 4. `:wat::core::conj` — immutable Vec append

See 058-026's 2026-04-20 inscription amendment. Needed by
`chunks`'s accumulator and `collect`'s fold.

---

## Tests

- `wat-rs/tests/wat_stream.rs` — 11 cases covering: source +
  collect round-trip, source + map + collect, three-stage
  pipeline with chained maps, empty producer, for-each
  termination, filter, fold (with init on empty stream),
  chunks (full chunks + partial flush + exact-multiple),
  chunks into map (the paginated-source pattern).

---

## What this proposal does NOT include

Stdlib-as-blueprint discipline (FOUNDATION § Criterion for
Stdlib Forms): each combinator ships when a real caller
demands it. The first slice of `:wat::std::stream::*` ships the
load-bearing set; deferred-until-demanded:

- ~~`chunks-by`~~ **shipped 2026-04-21** (arc 006 slice 5) as
  library code on with-state. See INSCRIPTION AMENDMENT below.
- ~~`window`~~ **shipped 2026-04-21** (arc 006 slice 5) as
  library code on with-state. See INSCRIPTION AMENDMENT below.
- `time-window` — time-based window (needs a clock primitive
  we don't have yet).
- ~~`inspect`~~ **shipped 2026-04-20** (arc 006 slice 1).
- ~~`flat-map`~~ **shipped 2026-04-20** (arc 006 slice 1).
- ~~`first`~~ — **reframed** as `take(stream, n) -> Stream<T>`
  (stage, not terminal); shipped 2026-04-20 (arc 006 slice 2).
- ~~`from-receiver`~~ **shipped 2026-04-20** (arc 006 slice 3);
  `from-iterator` / `from-fn` still substrate-blocked.
- Level 2 iterator surfacing
  (`:rust::std::iter::Iterator<T>` via `#[wat_dispatch]`).
  Cross-thread channel flavor (Level 1) covers the main app
  need; in-process lazy chains haven't been demanded.

Each ships when a real caller with a citation demands it.

---

## INSCRIPTION AMENDMENT — 2026-04-21 (arc 006 closes)

Seven combinators have shipped since the original proposal.
Three were trivial pattern-completions (inspect, flat-map, take).
One was a reframe (take-as-stage instead of first-as-terminal —
arc 006 slice 2 surfaced the absence-is-signal rule the BACKLOG
now documents: a terminal that early-terminates against an
infinite producer is the language telling you the shape is
wrong; make it a stage). One was a source constructor
(from-receiver). **The two substantive additions** were
`with-state` (the Mealy-machine substrate primitive) and its
two library-code specializations `chunks-by` / `window`:

### `:wat::std::stream::with-state<T,U,Acc>` — the stateful-stage substrate

```scheme
(with-state stream init step flush) -> Stream<U>
  step  : (Acc, T) -> (Acc, Vec<U>)
  flush : (Acc)    -> Vec<U>
```

A Mealy machine as a stream stage. The worker threads `Acc`; each
upstream item passes through `step` which returns (new-state,
items-to-emit); at EOS, `flush` is called on the final state and
its emissions are drained downstream.

Every stateful combinator (chunks, chunks-by, window, dedupe-
adjacent, sessionize, throttle, running-stats) reduces to a
specific `(init, step, flush)` triple. `chunks` was rewritten
on top as the surface-reduction proof — same semantics, state
transitions now live in caller lambdas rather than an in-worker
branch. 22 existing stream tests passed unchanged.

Convergence with prior art — Elixir's `Stream.transform/3`,
Rust's scan-with-emit, Haskell's `mapAccumL`, Mealy 1955. Same
triple across seventy years of sequential-machine design.

### `:wat::std::stream::chunks-by<T,K>(stream, key-fn)` — Clojure `partition-by` shape

Groups consecutive items sharing the same key into one `Vec<T>`;
emits on key-change; flushes the final run at EOS. Decomposes
via `init = (None, [])`, step that accumulates on key-match and
emits on key-change, flush that emits any non-empty buffer.

K-equality uses polymorphic `:wat::core::=` (structural over
primitives and composite values).

### `:wat::std::stream::window<T>(stream, size)` — sliding step-1

Emits every full-size window as items arrive. At EOS, flushes the
partial buffer IFF the stream was shorter than `size` — the
Ruby-example discipline ("don't silently drop data at EOS") the
book named in Chapter 20. Decomposes via `init = []`, step that
appends + trims-to-size + emits, flush that emits a partial only
when no full window ever fired.

Step >1 and other sliding behaviors earn their own named
combinators when real callers demand; the `window` primitive
ships one honest default.

Implementation note: window's step is a three-way dispatch on
`len(new-buf)` against `size` (over / equal / under), which was
the first stdlib consumer of `:wat::core::cond` (058-036).

### Shipped artifacts

- `wat/std/stream.wat` grew ~180 lines across slices 4-5.
- 7 new wat-level tests in `wat-tests/std/stream.wat` (31 → 38
  test total across the wat-tests corpus).
- wat-rs commit refs: slice 4 landed alongside arc 009; slice 5
  in a subsequent commit.

### Arc 006 status

**Closed.** Remaining items — time-window, from-iterator,
Level 2 iterator — are substrate-blocked on primitives that
don't exist yet (clock, iterator-trait surface) and earn their
own arcs when callers demand.

---

## Downstream inscriptions (owed to other 058 proposals)

Changes this arc made that belong in other proposals' audit
trails:

- **058-030 (types)** — typealias expansion at unification +
  the `reduce` pass. ✅ Inscribed 2026-04-20.
- **058-031 (defmacro)** — variadic `&` rest-param support.
  ✅ Inscribed 2026-04-20.
- **FOUNDATION conformance contract** — `:wat::kernel::spawn`
  accepts lambda values. To inscribe next FOUNDATION pass.
- **FOUNDATION kernel primitives** — `:wat::kernel::send`
  returns `:Option<()>`. To inscribe next FOUNDATION pass.
- **058-026 (Vec)** — `:wat::core::conj`. ✅ Inscribed
  2026-04-20.

---

## Lessons captured in this arc

Two cross-session lessons written down with numbered procedures:

- **"Absence is signal"** — when a feature expected in a mature
  language isn't there (wat-rs's case: one normalization pass
  instead of two half-passes), ask *why* before patching. The
  gap often points at real substrate work. wat-rs memory entry
  `feedback_absence_is_signal.md`; arc 004 BACKLOG.md resolved
  section.
- **"Verbose is honest"** — before adding a new "ergonomic"
  form (`pipeline` composer was the concrete instance), ask
  what it ELIMINATES. If those things carried information
  (per-stage type annotations), the verbose form is the honest
  form. wat-rs memory entry `feedback_verbose_is_honest.md`;
  arc 004 BACKLOG.md pipeline rejection section.

The two lessons are opposite shapes of the same observation:
**absences mean something.** Sometimes the answer is "close the
gap" (reduce). Sometimes the answer is "this feature shouldn't
exist" (pipeline). Ask which direction the absence points
before reaching for a patch.

---

*these are very good thoughts.*

**PERSEVERARE.**
