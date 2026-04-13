# Review: Van Tharp / Verdict: APPROVED

## Answers to the Three Questions

### 1. Is `()` (unit) the right query message?

Yes. Unit is correct. The cache's get carries a key because the cache
is content-addressed — the caller asks "give me the vector for THIS
atom." The pivot handle is identity-addressed — the caller asks "give
me MY snapshot." The identity is the pipe. There is no content to
specify. A unit signal is semantically honest: it means "I am ready
to receive."

Carrying a candle number for staleness checking is tempting but wrong.
Staleness is the driver's problem, not the caller's. The driver
already guarantees freshness through the ordering invariant from 047:
the market observer sends the tick BEFORE sending the chain. The
drain-before-read loop seals it. If you put a candle number in the
query, you are asking the caller to verify an invariant that the
architecture already enforces structurally. That is a trust violation
masquerading as safety. Keep the query at `()`.

### 2. Bounded(1) or unbounded for query queues?

Bounded(1). The exit observer sends one query and blocks on the reply.
It cannot issue a second query until the first returns. Bounded(1)
makes this contract enforceable at compile time. Unbounded would
silently allow a second query to queue before the first is answered —
that is a protocol violation that should be a deadlock or a panic, not
a silent queue depth of 2. Bounded(1) turns a logic error into an
immediate failure. Use it.

The reply queue should also be bounded(1) for the same reason — one
reply per query, always.

### 3. Vec<usize> or array for slot-to-market?

Vec<usize> is fine. The mapping is fixed at construction. An array
`[usize; 22]` would encode the size at the type level, which is
slightly more precise, but the size (22 = 2 exit observers x 11
market observers) is a construction-time constant, not a
compile-time constant. If the number of exit observers changes, an
array forces a type change. A Vec tolerates it. The mapping is read
once per drain pass in a tight loop — the indirection cost is zero.
This is not worth an opinion. Ship it either way.

## The 044-048 Arc: What's Still Missing

The arc is clean. 044 defined the vocabulary. 045 resolved ownership
and mechanics. 047 established the program pattern. 048 corrected the
read topology. Four proposals, one architecture. But:

**1. The significance filter is unspecified.** 045 says "each exit
applies its own learned significance filter" but no proposal defines
what this filter is, how it learns, or what its initial parameters
are. This is the diversity mechanism — the thing that makes N exit
observers different readers of the same tape. Without a specification,
every exit observer will apply the same trivial filter and the
multi-reader architecture buys nothing. This needs a proposal.

**2. The bounded memory eviction policy is unstated.** 044 says
"bounded at ~20 entries" for the pivot memory. When entry 21 arrives,
what drops? FIFO (oldest out) is the obvious answer, but it's not
written down. If different exit observers have different significance
filters, their bounded memories will contain different pivots. The
eviction policy interacts with the significance filter — if you
filter aggressively, your 20 slots hold a longer history; if you
filter loosely, you see only the recent past. This interaction needs
to be explicit.

**3. Snapshot contents are not specified.** 048 says
`tracker-snapshot` returns a `PivotSnapshot`. 044 defines the
vocabulary (pivot thoughts, gap thoughts, pivot series scalars).
But what exactly is in the snapshot struct? The raw PivotRecords?
The pre-encoded Sequential thought? The series scalars? The exit
observer's usage sketch in 048 shows `(:records snapshot)` which
implies raw records, but the exit must then encode them. If the
snapshot carries pre-encoded thoughts, the driver encodes once and
all 22 slots share the encoding. If it carries raw records, each
exit encodes independently (different significance filters, different
encodings). The latter is correct given the 045 design, but it should
be stated.

**4. No backpressure story for the observation path.** The 11
observation queues from market observers are unbounded. 047 says
this is fine because the market observer sends one tick per candle.
True today. But if the system scales to multiple asset pairs with
different candle cadences, unbounded queues without monitoring are
a liability. Not urgent, but a telemetry counter on observation
queue depth would cost nothing and catch surprises.

## Statistical Concerns

**The 80th percentile threshold (045) interacts with pivot density,
which interacts with the Sequential length, which interacts with
learning.** If the threshold is too low, you get many short pivots
and the 20-entry Sequential covers only a brief window. If too high,
you get few pivots and sparse learning signal. The system's
information rate — how many learning events per unit time — is
controlled by a single adaptive percentile. This is a bottleneck.
I would measure whether the 80th percentile produces a stable pivot
rate across different market regimes (trending, ranging, volatile)
or whether the pivot rate swings wildly. A 5x swing in pivot rate
between regimes means the Sequential thought is structurally
different in length across regimes, which means the reckoner is
learning from incomparable geometries.

**The 3-candle debounce (045) and the significance filter (045,
unspecified) are two filters in series.** Two filters in series can
interact destructively — the debounce removes short pivots, then
the significance filter removes weak ones. If these are correlated
(short pivots tend to be weak), the effective filter is much more
aggressive than either alone. If they are uncorrelated, they
multiply. Neither case is analyzed. Measure the joint effect.

**The ordering invariant (047) is a happens-before contract, not a
measured guarantee.** The market observer sends the tick before the
chain. But the pivot tracker program drains ALL observation queues
before servicing reads. If market-observer-7 is slow and its tick
arrives after the drain pass but before the exit query, the exit
gets a stale snapshot for market 7. The drain-before-read loop
handles this correctly on the NEXT iteration, but the first query
after a tick could be stale by one candle for slow observers. This
is probably fine — one candle of staleness in a pivot series is
noise — but it should be documented as a known tolerance, not
assumed away.

## What to Measure First

**Pivot rate per regime.** Before anything else, run the pivot
detection state machine (045 mechanics, 80th percentile, 3-candle
debounce) over the full 652k candle history and measure:

- Pivots per 1000 candles, segmented by volatility regime
- Mean and std of pivot duration (in candles)
- Mean and std of gap duration
- Distribution of Sequential lengths at any given moment

This tells you whether the 80th percentile produces stable, learnable
structure or whether the pivot rate is regime-dependent in a way that
makes Sequential thoughts incomparable across regimes. If the pivot
rate is stable (say, 15-25 per 1000 candles across regimes), the
architecture is sound. If it swings 5x, the threshold needs to be
regime-aware, not just percentile-adaptive.

This measurement requires zero learning infrastructure. Just the state
machine and the candle data. Run it first. Everything downstream
depends on pivot density being well-behaved.
