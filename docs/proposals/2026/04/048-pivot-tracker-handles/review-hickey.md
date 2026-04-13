# Review: Hickey / Verdict: APPROVED

The correction is clean, the realization is honest, and the
pattern is already proven.

## The three questions

### Question 1: Is `()` the right query message?

Yes. The handle knows its market-idx at construction. The pipe
IS the identity. The query carries no information because no
information is needed -- the structural wiring already encodes
who is asking and what they want. A unit signal is the correct
message when the channel itself is the address.

The cache's get carries a key because the cache serves
arbitrary lookups -- the caller picks WHICH value. The pivot
handle is bound to one tracker at construction. There is no
choice to express. Unit is not laziness. Unit is the honest
representation of a choiceless request.

Should the query carry a candle number for staleness checking?
No. That complects the query with temporal reasoning. If you
need staleness detection, that is a concern for the driver or
the caller -- not the message protocol. The snapshot is always
current because the driver drains writes before reads. The
ordering guarantee comes from the program's loop structure,
not from metadata on the wire.

### Question 2: Bounded(1) for query queues

Bounded(1). The exit blocks on the reply. It sends exactly one
query at a time. It cannot have two outstanding queries on the
same handle. Bounded(1) makes this structural rather than
conventional. The type enforces what the protocol requires.
Unbounded would accept what it should reject. Use the type
system to say what you mean.

### Question 3: Vec<usize> vs array for slot-to-market

It does not matter. The mapping is fixed at construction. A
Vec and an array are both indexed by usize, both O(1) lookup,
both immutable after creation. The array is more precise in
the type system -- it says "this will never grow." But the Vec
works and the difference is aesthetic, not architectural. Do
not spend time on this.

## The 044-048 arc

Five proposals. One thought decomposed correctly.

- **044** discovered the vocabulary -- what pivots are, what
  atoms they produce, how biography and series encode
- **045** resolved the mechanics -- who detects, how the state
  machine works, what the rolling percentile looks like
- **046** asked how the data flows and got the answer wrong
  three times because it never questioned whether the main
  thread should hold the state
- **047** corrected the framing -- the tracker is a program,
  not main thread logic
- **048** corrected the read interface -- per-caller handles,
  not a shared mailbox

The progression is honest. 046 was wrong. 047 corrected the
ownership. 048 corrected the read topology. Each correction
was earned by noticing something the previous proposal
complected.

### Is the architecture clean?

Yes. The concerns are separated:

1. **Vocabulary** (044): what pivots mean, what atoms they
   produce. Domain knowledge. Lives in the thought modules.
2. **Detection** (045): the state machine that classifies
   candles as pivot or gap. Computational concern. Lives in
   the tracker.
3. **Ownership** (047): the tracker is a program on its own
   thread. Architectural concern. The kernel does not think.
4. **Communication** (048): per-caller handles for reads,
   fire-and-forget mailbox for writes. Protocol concern.
   The pipe IS the identity.

Each concern lives in one place. No concern lives in two
places. The vocabulary does not know about channels. The
channels do not know about pivots. The driver does not know
about market structure. The exit observer does not know about
other exit observers. Clean.

### Is anything still complected?

One thing. The `slot-to-market` mapping lives inside the
driver. The driver uses it to route: query arrives on
queue[slot-idx], the driver looks up market-idx in the map,
reads the tracker, replies. This is routing logic. It is
correct. But the mapping is ALSO implicit in the handle --
the handle stores its market-idx (line 3 of the handle
struct). That field is unused by the driver. The driver
routes by its own map. The handle stores the index for...
what? The caller does not use it either -- the caller calls
`pivot-query!` which sends `()`.

The market-idx on the handle is dead information. The handle
does not need to know which tracker it reads. The pipe IS the
identity. The driver knows the mapping. The caller does not
care. Remove `market-idx` from the handle struct. It
complects the handle with knowledge it does not use.

If the caller needs to know its market-idx for logging or
debugging, that is a concern of the caller, not the handle.
The handle is a communication primitive. It should contain
exactly what it needs to communicate: a query sender and a
reply receiver. Nothing else.

### What I want to see before this is built

1. **Remove market-idx from PivotHandle.** The handle should
   be `(query-tx, reply-rx)`. Two fields. The pipe is the
   identity. The handle does not need to know what it points
   to.

2. **Confirm the ordering guarantee.** The proposal says the
   driver drains writes before reads. This means the exit
   observer always sees the current candle's pivot state when
   it queries. But this depends on the market observer's tick
   arriving BEFORE the exit observer's query. The tick is
   fire-and-forget (unbounded). The query blocks. What
   guarantees the tick arrives first? The main thread's
   fan-out ordering -- market observers complete before exit
   observers run. State this explicitly. The guarantee is
   topological, not temporal. If the fan-out order ever
   changes, the pivot data could be one candle stale. That
   dependency should be documented, not assumed.

3. **The program loop's select.** The pseudocode ends with
   `(select-ready observation-rxs query-rxs)`. This is the
   mechanism that wakes the program when any channel has data.
   In Rust this is `crossbeam::Select` or a similar
   multi-channel wait. Confirm that the implementation can
   select across 11 + 22 = 33 channels efficiently. This is
   not a design concern -- it is an implementation detail that
   should not surprise anyone at build time.

Nothing else. The design is right. Build it.
