# Question 001: Guide Edges

The guide (`wat/GUIDE.md`) was tested with the /ignorant ward.
What remains are not text fixes -- they are design decisions the guide
cannot make on its own.

## Question 1: How does the treasury size a trade?

**What's undecided:** The treasury receives proposals from posts and
"funds proven ones" proportionally to edge. The broker exposes
`(funding broker) -> f64` and the proof curve maps conviction to
accuracy. But the treasury interface has no sizing function. There
is no declared mechanism for converting an edge measurement into a
capital amount. `fund-proposals` is a black box -- it evaluates and
funds, but the guide never specifies how much.

**Lines:** 168-170 ("The treasury funds proportionally. More edge, more
capital."), 1000-1001 ("funding broker -> f64 -- how much edge?"),
1095-1101 (treasury interface: `fund-proposals`, `capital-available?`,
but no `size-trade` or sizing formula).

**Why it matters:** Position sizing is the single largest determinant of
whether the enterprise survives or blows up. If the guide doesn't declare
the sizing rule, every implementor will invent one. The proof curve, the
funding value, the available capital, the number of active trades -- all
feed into sizing, but the formula is absent. This is the gap between
"the treasury funds proportionally" and actual code.

## Question 2: Where does trade direction come from?

**What's undecided:** The market observer predicts Win/Loss -- "did the
price move in the predicted direction?" The Prediction struct carries
scores, conviction, and experience. But there is no Buy or Sell anywhere.
The treasury's `capital-available?` takes a `direction` parameter. The
Trade struct has `source-asset` and `target-asset` but no direction field.
Something converts a Win/Loss prediction into a directional trade, and
that something is not in the guide.

**Lines:** 68-69 ("Win = yes. Loss = no."), 385-392 (Prediction struct --
scores, value, conviction, experience, no direction), 394-399 (Proposal
struct -- composed-thought, prediction, distances, no direction),
401-413 (Trade struct -- no direction field), 1100 (`capital-available?`
takes `direction`).

**Why it matters:** A prediction of "Win with high conviction" is
meaningless without knowing which direction Win means. Does the market
observer predict Win-as-Buy and Loss-as-Sell? Or does it have two
discriminants? Is the direction implicit in the asset ordering
(source -> target = buy)? The guide leaves a hole between prediction
and action that every downstream decision depends on.

## Question 3: What rule determines which broker sets exist?

**What's undecided:** The guide says "at construction, the enterprise
enumerates all broker sets" and assigns flat slot indices. The broker
definition says it binds "any number" of observers -- "two today, three
tomorrow." The slot-idx formula is `market-idx x M + exit-idx`, which
implies exactly N x M pairs (one market, one exit). But the broker
definition says the set can have three or more observers. Is the
registry exactly N x M pairs? Or is it an arbitrary enumeration of
observer subsets? The cardinality rule is unstated.

**Lines:** 174-175 ("Any number -- two today, three tomorrow"),
200-202 (slot-idx = market-idx x M + exit-idx), 966-970 ("the
enterprise enumerates all broker sets"), 373-380 (construction example
hardcodes `("momentum" "volatility")`).

**Why it matters:** The slot-idx formula and the "any number" definition
contradict. If slot-idx = market-idx x M + exit-idx, then every broker
has exactly one market observer and one exit observer. But the definition
allows three-observer sets. Either the formula is wrong (needs a
different indexing scheme for variable-sized sets) or the "any number"
is aspirational and the current system is strictly pairwise. A designer
must decide which is true now.

## Question 4: How do brokers access observers they don't own?

**What's undecided:** The broker stores observer names as `Set<String>`.
The post owns the observer instances. The broker's `tick-papers` and
`propagate` interfaces take an `observers` parameter, but the guide
never specifies the type of that parameter. At runtime, the broker
needs mutable access to observers (to call `resolve` on them). The
bridge between name-as-identity and mutable-reference-at-runtime is
undeclared.

**Lines:** 960-962 ("The broker does NOT own the observers -- it
references them. The post owns the observers."), 979 (struct field:
`observers ; Set<String>`), 1005-1008 (`tick-papers` and `propagate`
take `observers` as parameter -- type unspecified).

**Why it matters:** In Rust, this is a borrowing question with real
consequences. If the broker borrows observers mutably, the post
can't access them simultaneously. If the broker takes indices into
the post's observer vecs, the interface needs index types, not strings.
The lock-free parallel access claim (lines 966-975) depends on disjoint
slots, but the observer access pattern across broker boundaries is the
part that could violate disjointness.

## Question 5: Who creates Proposal structs?

**What's undecided:** The post's `post-on-candle` returns `Vec<Proposal>`.
The Proposal has a `composed-thought`, a `prediction`, and `distances`.
The composed thought comes from the exit observer's `compose`. The
prediction comes from the broker's `propose`. The distances come from
the exit observer's `recommended-distances`. But the guide never shows
which entity assembles these three pieces into a Proposal. Is it the
post? The broker? The exit observer? The guide shows the parts but not
the assembly.

**Lines:** 394-399 (Proposal struct: composed-thought, prediction,
distances), 926-928 (exit observer: compose, recommended-distances),
998-999 (broker: propose returns Prediction), 1055-1057 (post:
post-on-candle returns Vec<Proposal>).

**Why it matters:** The Proposal is the interface between the post and
the treasury. Whoever assembles it must have access to the composed
thought (from exit observer), the prediction (from broker), and the
distances (from exit observer). If the broker assembles it, the broker
needs access to exit observer outputs. If the post assembles it, the
post must coordinate broker and exit observer calls in the right order.
The assembly point determines the data flow in Step 2 (COMPUTE/DISPATCH).

## Question 6: How are active trade stops updated?

**What's undecided:** `post-update-triggers` takes `trades` and `thoughts`
and "updates active trade triggers with fresh thoughts." The Trade struct
has trail-stop, safety-stop, and take-profit as f64 fields. The exit
observer can produce fresh distances via `recommended-distances`. But
the guide doesn't specify: does the system re-query exit observers every
candle for active trades? Does the treasury mutate its Trade structs?
Who converts a fresh distance into an updated stop level? Is this a
trailing stop that only moves in the favorable direction, or can stops
widen?

**Lines:** 1058-1059 (post-update-triggers interface), 401-413 (Trade
struct with trail-stop, safety-stop, take-profit as plain f64),
928-929 (recommended-distances returns distances).

**Why it matters:** If stops are static (set at entry, never updated),
the exit observer's continuous learning only affects NEW trades. If
stops are dynamic (re-queried every candle), the exit observer's learning
affects ALL open trades -- a much stronger feedback loop but also a
source of instability if the reckoner's estimates shift rapidly. The
interface exists (`post-update-triggers`) but its semantics are undeclared.

## Question 7: How are distances converted to price levels?

**What's undecided:** The Proposal carries `distances: (trail, stop, tp)`
as relative values -- the exit observer estimates distances. The Trade
struct has `trail-stop`, `safety-stop`, `take-profit` as absolute f64
price levels. The guide mentions ATR ("multipliers of ATR") and the
Trade has `entry-atr`. But the conversion formula (distance x ATR +
entry price? distance as percentage of price? distance as raw price
delta?) is never stated.

**Lines:** 399 (Proposal distances), 86-94 (magic numbers as ATR
multipliers), 407-412 (Trade struct with absolute levels and entry-atr).

**Why it matters:** The exit observer's continuous reckoner has
`default-value 0.015`. Is 0.015 a percentage? An ATR multiplier? An
absolute dollar amount? The interpretation determines what the reckoner
learns and what the scalar accumulator extracts. If trail-distance means
"1.5% of price" vs "1.5x ATR" vs "$1500", the entire learning pipeline
produces different things. The units of distance are unstated.

## Question 8: What does a reckoner do when it has no experience?

**What's undecided:** The reckoner's `experience` returns 0.0 when
ignorant. The Prediction struct carries experience. The treasury funds
"proven" proposals. The proof curve maps conviction to accuracy. But
the guide never specifies the behavior of `predict` when experience is
0.0. Does it return a zero-conviction prediction? Does it return the
default value? Does the curve return 0.0 edge? The cascade from
ignorance to competence is described philosophically ("the crutch is
replaced by what the market actually said") but not mechanically.

**Lines:** 39 (`experience -> f64 -- 0.0 = ignorant`), 92-94 ("each one
is a crutch -- a default value returned when the system has no
experience"), 168-170 (proof curve funds proportionally), 392
(Prediction carries experience).

**Why it matters:** During bootstrap, every reckoner is ignorant. If
`predict` returns high conviction with zero experience, the treasury
might fund baseless proposals. If `funding` returns 0.0 for zero
experience, the system never takes a trade and never learns. The
bootstrap behavior determines whether the system can learn at all.
This is the cold-start problem and the guide reaches its edge here.

## Question 9: Which trailing stop distance do paper trades use?

**What's undecided:** PaperEntry has `recommended-distance` (what the
exit observer predicted at entry) and separate `buy-trail-stop` /
`sell-trail-stop` levels. The guide defines a cascade for live trades:
contextual (reckoner) -> global (ScalarAccumulator) -> default (crutch).
But for paper trades, the cascade is not stated. Papers are "every
candle, every broker" -- the fast learning stream. If papers use the
crutch while the reckoner is ignorant, they learn from a fixed distance.
If they use the reckoner from the start, they learn from an untrained
estimate.

**Lines:** 360-370 (PaperEntry struct), 940-945 (cascade: contextual ->
global -> default), 1002-1004 (register-paper takes distances).

**Why it matters:** Papers are how the system learns before it trades.
They are the bootstrap mechanism. The distance they use determines what
they teach. If papers use the crutch, the system learns "what would have
happened with the crutch distance" -- not "what was optimal." If papers
use the reckoner's estimate (even when ignorant), the learning is
circular. The paper's distance source determines the quality of the
entire learning pipeline.

## Question 10: How does the thought-encoder cache work under parallelism?

**What's undecided:** The thought-encoder is declared "immutable, shared"
in the Enterprise struct. It is "owned by the enterprise, passed to
posts." But its `compositions` field is an LRU cache that performs
store and evict operations -- mutations. Market observers encode in
parallel via par_iter. Multiple observers writing to the same cache
simultaneously is a data race.

**Lines:** 693-694 ("Owned by the enterprise. Passed to posts."),
698 (compositions: LRU cache), 752 (`store` call in encode), 1119
("market observers encode simultaneously (par_iter)"), 1135 ("immutable,
shared").

**Why it matters:** This is not a text inconsistency -- it is a design
tension. The options are: (1) the cache is behind a lock (contradicts
"immutable"), (2) the cache is per-thread (contradicts "shared"), (3)
the cache is lock-free concurrent (requires a specific data structure
the guide doesn't name), (4) the cache is populated at startup and
read-only at runtime (contradicts the LRU eviction description). Each
choice has different performance and correctness properties. The guide
asserts both immutability and mutation without resolving the conflict.

## Question 11: What does the risk architecture look like?

**What's undecided:** The guide defers risk explicitly: "risk/ --
portfolio health. Coordinate for future work. Not in 007." But the
broker definition already accommodates risk observers ("three tomorrow
-- market + exit + risk"), and the project's CLAUDE.md describes five
active risk domains (drawdown, accuracy, volatility, correlation, panel)
with a RiskManager using Template 1 (Journal: Healthy/Unhealthy). The
guide leaves risk as a named gap, but the project appears to already
have risk branches in the code.

**Lines:** 174-175 ("three tomorrow (market + exit + risk)"), 589
("risk/ -- portfolio health. Coordinate for future work. Not in 007.").

**Why it matters:** If the guide is the source of truth and the code
should match it, the existing risk code is orphaned -- implemented but
unspecified. If the code has discovered something the spec missed, the
guide should say so. The current state is silence: risk is deferred in
the guide but present in the project. A designer must decide whether
007 includes risk or explicitly acknowledges the existing code as
pre-007 legacy.

## Question 12: Does exit generalist see market vocabulary?

**What's undecided:** MarketLens `:generalist` selects "all facts."
ExitLens `:generalist` selects "ALL three (volatility + structure +
timing)." The exit observer's `compose` bundles market thought with
exit facts. But does the exit generalist's "ALL three" mean all exit
modules only, or all exit modules plus shared modules (time)? And
since `compose` already bundles the market thought in, does the exit
generalist effectively see everything? The boundary between "what the
exit observer thinks about independently" and "what it receives from
the market observer via composition" is blurred for the generalist case.

**Lines:** 302-303 (MarketLens and ExitLens enums), 587 ("The
:generalist exit lens selects ALL three"), 905-907 ("Composes market
thoughts with its own judgment facts"), 926-927 (compose bundles market
thought with exit facts).

**Why it matters:** If the exit generalist sees market vocabulary
directly (not just via composition), it double-encodes market facts --
once in the market thought it receives, once in its own encoding. The
discriminant might learn from this redundancy or be confused by it. The
guide needs to say whether "all" means "all exit" or "all everything."
