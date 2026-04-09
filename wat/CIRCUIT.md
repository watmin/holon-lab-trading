# The Circuits

*The machine as signal flow diagrams. For humans.*

Each circuit is a mermaid graph definition. GitHub renders them natively.

---

## 1. The full enterprise

Signals flow down (candle → thought → proposal). Outcomes flow back up
(settlement → propagation → observers). The circuit is a loop. The fold
is one tick of the clock.

```mermaid
graph TD
    subgraph Post [One per asset pair]
        RC[RawCandle] --> IB[IndicatorBank]
        IB --> CD[Candle]
        CD --> MO[MarketObserver xN]
        CD --> EO[ExitObserver xM]
        MO -->|thought Vector| EO
        EO -->|composed + distances| BR[Broker xNxM]
    end
    MO -.->|uses| VO[Vocabulary]
    MO -.->|uses| TE[ThoughtEncoder ctx]
    EO -.->|uses| VO
    EO -.->|uses| TE
    BR -->|Proposals| TR[Treasury]
    TR -->|TreasurySettlement| EN[Enterprise]
    EN -->|direction + optimal + propagation args| Post
    Post -->|post-propagate| BR
    BR -->|Direction + thought + weight| MO
    BR -->|optimal Distances + composed + weight| EO
    TR -->|active trades| Post
    Post -->|new Levels| TR
```

Note: dashed arrows (-.->|uses|) show tools the observers call, not data
flow. The observer calls Vocabulary for ASTs, then ThoughtEncoder for
Vectors. Vocabulary and ThoughtEncoder are tools, not upstream producers.

**Component legend:**

| Node | Contains | Produces |
|------|----------|----------|
| **IndicatorBank** | streaming state (ring buffers, EMA accumulators) | Candle (100+ indicators) |
| **Vocabulary** | pure functions, no state | Vec\<ThoughtAST\> — data, not execution |
| **ThoughtEncoder** | atoms (permanent dict) + compositions (LRU cache, eventually-consistent via returned misses) | Vector from AST |
| **MarketObserver ×N** | lens (MarketLens), reckoner :discrete (Up/Down, curve internal), noise-subspace, window-sampler, engram gate | (Vector, Prediction, edge, misses\*) |
| **ExitObserver ×M** | lens (ExitLens), 4× reckoner :continuous (trail, stop, tp, runner-trail), default-distances | (Distances, experience) via cascade + misses\* |
| **Broker ×N×M** | reckoner :discrete (Grace/Violence, curve internal), noise-subspace, papers (deque), 4× scalar-accumulator, engram gate | Prediction + edge() |
| **Post** | indicator-bank, candle-window, market-observers, exit-observers, registry | Vec\<Proposal\> + Vec\<Vector\> + misses\* |
| **Treasury** | available ◄──► reserved, trades, trade-origins, next-trade-id | TreasurySettlement on settle |
| **Enterprise** | posts, treasury, market-thoughts-cache | (Vec\<LogEntry\>, misses\*) per candle |

\*misses = Vec\<(ThoughtAST, Vector)\> — cache misses returned as values, inserted by the binary between candles.

**Edge legend — data flow (solid arrows):**

| From → To | Type | Method |
|-----------|------|--------|
| RC → IB | RawCandle | tick(raw) → Candle |
| CD → MO | Candle (via candle-window slice) | observe-candle(window, ctx) → (Vector, Prediction, edge, misses) |
| CD → EO | Candle (for exit facts) | encode-exit-facts(candle) → Vec\<ThoughtAST\> |
| MO → EO | Vector (market thought) | evaluate-and-compose(thought, fact-asts, ctx) → (Vector, misses) |
| EO → BR | composed Vector + (Distances, experience) | recommended-distances(composed, accums) → (Distances, f64) |
| BR → TR | Proposal (the barrage) | submit-proposal(proposal) |
| TR → EN | TreasurySettlement | settle-triggered(prices) → (Vec\<TreasurySettlement\>, Vec\<LogEntry\>) |
| EN → Post | direction + optimal + propagation args | post-propagate(post, slot-idx, thought, outcome, weight, direction, optimal) |
| Post → BR | propagation args | broker.propagate(thought, outcome, weight, direction, optimal, observers) |
| BR → MO | Direction + thought + weight | resolve(thought, direction, weight) |
| BR → EO | optimal Distances + composed + weight | observe-distances(composed, optimal, weight) |
| TR → Post | active trades for trigger update | trades-for-post(post-idx) — step 3c |
| Post → TR | new Levels | update-trade-stops(trade-id, new-levels) — step 3c |

**Tool usage (dashed arrows):**

| Observer | Tool | Purpose |
|----------|------|---------|
| MO, EO | Vocabulary | produce Vec\<ThoughtAST\> from Candle |
| MO, EO | ThoughtEncoder (ctx) | evaluate ASTs into Vectors |

---

## 2. The encoding circuit

Pure. No learning. No state (except the ThoughtEncoder's eventually-consistent
cache). RawCandle in, Vector out.

```mermaid
graph TD
    RC[RawCandle] --> IB[IndicatorBank]
    IB -->|Candle| OBS[Observer selects lens]
    OBS -->|lens modules| VO[Vocabulary]
    VO -->|ThoughtASTs| OBS
    OBS -->|Bundle AST| TE[ThoughtEncoder]
    TE -->|Vector + misses| OUT[thought vector]
```

The observer selects which vocabulary modules fire (its lens). The
vocabulary produces ASTs — data describing what to think. The observer
wraps them in a Bundle. The encoder evaluates — computing the minimum
work via cache. Atoms are permanent. Compositions are optimistic (LRU,
eventually-consistent via returned misses).

---

## 3. The learning circuit

The feedback loop. Where Grace and Violence shape the next prediction.

```mermaid
graph TD
    TH[thought] --> RK[Reckoner]
    RK -->|predict| PR[Prediction]
    PR --> ACT[action in world]
    ACT -->|outcome| OC[Grace or Violence]
    OC -->|observe| RK
```

The reckoner accumulates observations. The discriminant sharpens. The
prediction improves. The loop is the learning. Each tick, the reckoner
that predicted Grace gets stronger. The one that predicted Violence
gets weaker.

---

## 4. The paper circuit

The fast learning stream. Every candle. Every broker. No real capital.

```mermaid
graph TD
    CT[composed thought] --> REG[register paper]
    REG --> PE[PaperEntry in deque]
    PE -->|tick with price| CHK[check stops]
    CHK -->|resolved?| RES[Resolution]
    RES -->|propagate| MO[MarketObserver]
    RES -->|propagate| EO[ExitObserver]
    RES -->|propagate| BR[Broker self]
```

Papers play both sides (buy and sell) simultaneously. When a side's
trailing stop fires, the paper resolves. Direction: buy-side fires → :up,
sell-side fires → :down. The resolution carries the optimal distances
from hindsight. Papers are how the machine learns before it trades.

---

## 5. The funding circuit

The capital lifecycle. Deploy, protect, recover, accumulate.

```mermaid
graph TD
    PR[Proposal] --> TR[Treasury evaluates]
    TR -->|fund| AV[available → reserved]
    AV --> TD[Trade :active]
    TD -->|safety-stop hit| SV[Settled :violence]
    SV --> RET1[principal - loss → available]
    TD -->|take-profit hit| RN[Runner :runner]
    RN --> RET2[principal → available]
    RN -->|runner-trail hit| SG[Settled :grace]
    SG --> RES[residue → available — permanent gain]
    TR -->|reject| DR[drained]
```

The treasury funds proven proposals. Capital moves from available to
reserved. The trade is :active. Violence path: 2 swaps (entry + stop-loss). Grace path via runner: 3 swaps (entry + take-profit recovery + runner capture). Each swap costs `swap-fee + slippage`. Two trigger paths:
- **Safety-stop hit** → :settled-violence. Principal minus loss returns.
  Bounded by the reservation.
- **Take-profit hit** → :runner. Principal returns to available AND
  residue continues with a wider trailing stop. One transition, not two.
  Zero cost basis — house money.
- **Runner-trail hit** → :settled-grace. Residue is permanent gain.
  Returns to available. The trade is done.

---

## 6. The cascade circuit

Three levels of distance knowledge. Specific to general.

```mermaid
graph TD
    Q[query distance] --> RK[Reckoner contextual]
    RK -->|experienced?| YES1[use reckoner answer]
    RK -->|inexperienced| SA[ScalarAccumulator global]
    SA -->|has data?| YES2[use accumulator answer]
    SA -->|empty| DEF[default crutch]
```

For each distance (trail, stop, tp, runner-trail): try the contextual answer first
(reckoner — "for THIS thought, what distance?"). If inexperienced, try the
global answer (scalar accumulator — "what does Grace prefer for this pair
overall?"). If empty, use the crutch (the default value from construction).

---

## 7. The propagation circuit

The signal that teaches. TreasurySettlement → enterprise computes → observers learn.

```mermaid
graph TD
    TS[TreasurySettlement] --> EN[Enterprise computes direction + optimal]
    EN -->|slot-idx + thought + outcome + weight + direction + optimal| PP[post-propagate]
    PP --> BR[Broker]
    BR -->|Grace/Violence + thought + weight| BRK[broker reckoner]
    BR -->|Direction + thought + weight| MO[MarketObserver resolve]
    BR -->|optimal Distances + composed + weight| EO[ExitObserver observe-distances]
    BR -->|value + outcome + weight| SA[ScalarAccumulators]
```

The enterprise computes direction and optimal-distances from the
TreasurySettlement's trade (replays price-history). Routes values directly —
no intermediate Settlement struct. Routes
to the post. The post calls broker.propagate. The broker fans out —
weight on every edge, because a large Grace teaches harder than a
marginal one: Grace/Violence to its own reckoner, Direction to the
market observer, optimal Distances to the exit observer, scalar values
to the accumulators. Everyone learns from one resolution.

---

## 8. The binary circuit

The outer loop. The fold driver. Everything above happens INSIDE one
call to `on-candle`. The binary is what calls it.

```mermaid
graph TD
    CLI[CLI args] --> BIN[Binary]
    BIN -->|construct| CTX[ctx — immutable world]
    BIN -->|construct| ENT[Enterprise — mutable state]
    DS[Data Source] -->|RawCandle stream| BIN
    BIN -->|on-candle raw ctx| ENT
    ENT -->|Vec LogEntry + cache misses| BIN
    BIN -->|insert misses| CTX
    BIN -->|flush logs| LED[Ledger — SQLite]
    BIN -->|progress| DISP[Display]
    KILL[trader-stop file] -.->|abort| BIN
```

The binary creates the world (ctx) and the machine (enterprise) from
CLI arguments. It opens the data source — parquet or websocket. It
feeds raw candles one at a time. It collects log entries and cache
misses from each `on-candle` call. It inserts cache misses into ctx's
ThoughtEncoder between candles (the one seam). It flushes log entries
to the ledger in batches. It displays progress. It checks the kill
switch. When the stream ends, it prints the summary.

The binary does not think. It drives the fold and writes what happened.

---

## The composition

The full enterprise is the composition of all sub-circuits. The encoding
circuit feeds the learning circuit. The paper circuit is the learning
circuit applied to hypotheticals. The funding circuit converts proposals
into trades. The cascade circuit provides distances at every experience
level. The propagation circuit closes the loop. The binary circuit
wraps them all — it drives the fold and persists the results.

`f(state, candle) → state` — one tick of the clock. All circuits fire.
The fold advances. Grace strengthens. Violence decays. The machine learns.
