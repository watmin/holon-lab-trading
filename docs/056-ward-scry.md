# Ward: Scry — Proposal 056 (Thought Architecture)

Specification: `docs/proposals/2026/04/056-thought-architecture/PROPOSAL.md`
Ward run: 2026-04-15

## Summary

The core architecture is implemented and matches the proposal. Indicator
rhythm, phase rhythm, thermometer encoding, permute, noise subspace per
thinker, broker-observer composition — all present and structurally correct.
Seven findings. Three are spec-code divergences. Four are spec features not
yet implemented.

## Findings

### 1. Hardcoded dims=10,000 in rhythm budget calculations

**Spec says:** "The trim is derived from `sqrt(dims)`, not hardcoded."
(Capacity section, Trim Strategy)

**Code does:** `rhythm.rs:57`, `rhythm.rs:116`, `phase.rs:125`,
`broker_program.rs:117` all hardcode `((10_000 as f64).sqrt()) as usize`.
The code even annotates this: `// rune:forge(dims) — needs dims param`.

**Verdict:** Known debt, acknowledged by rune. The dims parameter needs
to flow into `indicator_rhythm`, `phase_rhythm_thought`, and
`broker_program`. Not a divergence — a TODO with a rune.

### 2. No `circular_rhythm` function

**Spec says:** Two variants: `indicator-rhythm` for continuous values
(Thermometer + delta), `circular-rhythm` for periodic values (Circular
encoding, no delta). "Circular time values (Beckman)" listed as resolved
condition.

**Code does:** No `circular_rhythm` function exists anywhere in `src/`.
Time facts (hour, day-of-week) are encoded as top-level `Circular` binds
in `market_observer_program.rs:154-171` and `broker_program.rs:90-98`.
They are NOT rhythms — they are single-candle facts. The proposal says
time is a rhythm-candidate: "circular-rhythm — for periodic values
(hour, day-of-week)."

**Verdict:** Divergence. The spec describes `circular-rhythm` as a
function that processes the window (map over candles, no delta, circular
encoding). The implementation treats time as a snapshot fact, not a rhythm.
For time-of-day this is defensible — the hour doesn't have meaningful
window progression at 5-minute scale (it changes by 1/12 per candle).
But the spec explicitly names it as a rhythm variant. Either implement
`circular_rhythm` or update the spec to say time facts are snapshots,
not rhythms.

### 3. `standard_facts` has no rhythm equivalent

**Spec says:** "One call per indicator. One rhythm per indicator." The
market observer's thought is rhythms of ALL indicators the lens selects.

**Code does:** `market_lens_facts` calls `encode_standard_facts(window, ...)`
for DowVolume, DowCycle, DowGeneralist, WyckoffEffort, WyckoffPosition.
But `market_rhythm_specs` has no `standard_specs()`. The standard module
provides `since-vol-spike`, `since-rsi-extreme`, `since-large-move`,
`dist-from-high`, `dist-from-low`, `dist-from-midpoint` — all window-based
facts. These are present in the old fact-based path but missing from the
rhythm path.

**Verdict:** Divergence. Lenses that previously included standard facts
now silently drop them in rhythm mode. The rhythm specs for DowVolume,
DowCycle, WyckoffEffort, and WyckoffPosition are narrower than their
fact-based equivalents. Either add standard_specs() or document that
these facts are intentionally excluded from rhythms (they may be
window-summary facts that don't make sense per-candle).

### 4. Regime observer does NOT filter market facts by anomaly

**Spec says:** "The regime observer extracts from the market anomaly:
for each of the ~33 market facts, cosine against the anomaly vector.
Facts above the noise floor pass through as `(bind (atom "market") fact)`."
Also: "Anomaly Filtering Between Thinkers" — cosine each market rhythm
vector against the market anomaly. High-presence rhythms pass.

**Code does:** `regime_observer_program.rs` passes the market chain
through UNTOUCHED. Lines 105-115: `market_raw: chain.market_raw`,
`market_anomaly: chain.market_anomaly`, `market_ast: chain.market_ast`.
No cosine filtering. No noise floor. No `(bind (atom "market") fact)`
wrapping. The regime observer builds its own rhythm ASTs and passes
them alongside the unfiltered market data.

**Verdict:** Spec feature not implemented. The anomaly filtering between
thinkers is described in the proposal but not built. The broker receives
the full market AST, not the anomaly-filtered subset. This is a
significant architectural gap — the triple-filter cascade (market
subspace -> regime filter -> broker subspace) described in the proposal
is currently a single-filter (broker subspace only for itself, market
subspace for the market observer).

### 5. Regime observer has no noise subspace

**Spec says:** "Regime observer subspace: learns normal regime rhythm
bundles." One subspace per thinker. Three subspaces total.

**Code does:** `RegimeObserver` struct (not shown but referenced) and
`regime_observer_program.rs` — the regime observer builds rhythm ASTs
but never encodes them into a vector, never feeds a subspace, never
extracts an anomaly. The regime facts are passed as raw ASTs, not as
anomaly-filtered vectors. The regime observer has no `OnlineSubspace`.

**Verdict:** Spec feature not implemented. The regime observer is
currently pure middleware that builds ASTs and passes them through.
It has no learning, no subspace, no anomaly extraction. The spec
describes it having its own subspace. The broker's subspace partially
compensates (it strips the composed background), but the regime-level
anomaly filtering is absent.

### 6. Phase record has 5 own properties, not 4

**Spec says:** "Own properties (4): rec-duration, rec-move, rec-range,
rec-volume."

**Code does:** `phase.rs:75-85` produces 5 facts per record: label atom
+ rec-duration + rec-move + rec-range + rec-volume. The label atom
(`phase_label_atom`) is a structural binding, not a scalar property.

**Verdict:** Minor. The spec lists 4 own properties but the code adds
the label atom as a 5th. This is correct — the label identifies the
phase type within the trigram. The spec's count of "4-10 facts" should
be "5-11 facts" (4 scalar properties + 1 label + up to 6 deltas).
Spec should update.

### 7. Naming: telemetry says "broker", not "broker-observer"

**Spec says:** "The doc comment, the console diagnostics, and the
telemetry namespace change to `broker-observer`."

**Code does:** `broker_program.rs:300`: `let ns = "broker"`. Console
diagnostic at line 329: `"broker[{}]"`. The LogEntry variants use
`BrokerSnapshot`, not `BrokerObserverSnapshot`.

**Verdict:** Spec naming not applied. Low priority but explicit in
the proposal.

## Encoding Mode Verification

| Fact type | Spec mode | Code mode | Match |
|-----------|-----------|-----------|-------|
| Continuous indicators (RSI, ADX, etc.) | Thermometer | Thermometer | YES |
| Indicator deltas | Thermometer (symmetric) | Thermometer (symmetric) | YES |
| Phase record scalars | Thermometer | Thermometer | YES |
| Phase deltas (prior, same) | Thermometer | Thermometer | YES |
| Time (hour, day-of-week) | Circular | Circular | YES |
| Portfolio rhythms | Thermometer (implied) | Thermometer (via indicator_rhythm) | YES |

## Capacity Math Verification

**Inner rhythm bundle:** Spec says sqrt(D) pairs. Code trims to
`sqrt(10000) = 100` pairs (hardcoded, finding #1). At D=10,000 this
is correct. The trim takes the rightmost (most recent) pairs. Matches.

**Phase rhythm:** Same trim logic. `phase.rs:125-131` trims records
to `budget + 3`, then builds trigrams and pairs, then trims pairs to
budget. Matches the spec.

**Outer broker bundle:** Spec says ~42-62 items at D=10,000. Code
bundles: market_ast (1 bundle) + regime_facts (~8-9 ASTs) +
portfolio_rhythms (5) + phase_rhythm (1) + time facts (2) = ~17-18
top-level items. The market_ast itself is a Bundle of ~7-40 rhythm
ASTs depending on the lens. After encoding, this is one vector in
the outer bundle. Total outer items = ~17-18. Well under budget.

The spec's count of ~42-62 appears to assume the market rhythms are
unbundled in the outer bundle. The code bundles them inside market_ast
first, so the outer bundle is much smaller. This is better for
capacity but means the broker's subspace sees one market vector,
not N individual rhythm vectors.

## Trigram/Pair Construction Verification

**Spec:** `trigram = bind(bind(encode(A), permute(encode(B), 1)), permute(encode(C), 2))`

**Code (`rhythm.rs:90-97`):**
```rust
ThoughtAST::Bind(
    Box::new(ThoughtAST::Bind(
        Box::new(w[0].clone()),
        Box::new(ThoughtAST::Permute(Box::new(w[1].clone()), 1)),
    )),
    Box::new(ThoughtAST::Permute(Box::new(w[2].clone()), 2)),
)
```
Matches exactly.

**Spec:** `pair = bind(trigram_i, trigram_i+1)`

**Code (`rhythm.rs:104-108`):**
```rust
ThoughtAST::Bind(
    Box::new(w[0].clone()),
    Box::new(w[1].clone()),
)
```
Matches exactly.

**Spec:** `rhythm = bundle(all pairs)` with atom wrapping the whole thing.

**Code (`rhythm.rs:119-125`):** Bundle trimmed pairs, then
`Bind(Atom(atom_name), Bundle(trimmed))`. Matches.

## What Holds

- Indicator rhythm function: implemented, correct structure
- Thermometer encoding: implemented in ThoughtAST and both encoders
- Permute: implemented in ThoughtAST and both encoders
- Phase rhythm with structural deltas: implemented, correct
- Four phase types: implemented (valley, peak, transition-up, transition-down)
- Prior-bundle deltas: implemented (3 facts)
- Prior-same-phase deltas: implemented (3 facts)
- Market observer noise subspace: implemented (k=8)
- Broker-observer noise subspace: implemented (k=32)
- Broker composes: market + regime + portfolio + phase + time: implemented
- Portfolio rhythms via indicator_rhythm: implemented (5 streams)
- Atom wraps whole rhythm, not per-candle: implemented
- Delta = value - previous: implemented
- Trim to sqrt(D) from right: implemented (hardcoded to D=10000)

## Severity

| # | Finding | Severity |
|---|---------|----------|
| 1 | Hardcoded dims | Low (rune acknowledged) |
| 2 | No circular_rhythm | Medium (spec/code mismatch) |
| 3 | Missing standard_specs | Medium (silent fact loss) |
| 4 | No anomaly filtering between thinkers | High (architectural gap) |
| 5 | No regime noise subspace | High (architectural gap) |
| 6 | Phase record count off by 1 | Low (spec wording) |
| 7 | Broker naming not updated | Low (cosmetic) |
