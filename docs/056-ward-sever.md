# Ward: Sever — Proposal 056

> "I'd rather have more things hanging nice, straight down, not twisted together,
> than just a couple of things tied in a knot." — Rich Hickey

Three files examined. Five findings.

---

## File 1: broker_program.rs

### Finding 1: Inline struct — PortfolioSnapshot (line 42)

`PortfolioSnapshot` is defined inside `broker_program.rs`. It is a domain
concept — a per-candle summary of broker portfolio state. It has a companion
function `portfolio_rhythm_asts` (line 50) that converts a window of snapshots
into rhythm ASTs. This is a vocabulary module trapped in a program file.

**Where it goes:** `src/vocab/exit/portfolio.rs` (new file). The struct,
the rhythm builder, and the snapshot construction logic (lines 149-179)
are one concern: "portfolio as a stream of rhythms." The broker program
calls it; it doesn't define it.

**What the call site becomes:**
```rust
// Before (broker_program.rs lines 149-179):
let snap = PortfolioSnapshot { avg_age: ..., avg_tp: ..., ... };
portfolio_window.push(snap);

// After:
let snap = portfolio_snapshot(&active_receipts, candle_count, price, broker.expected_value);
portfolio_window.push(snap);
```

**Why it matters:** The broker program becomes pure orchestration. The
portfolio vocabulary becomes testable in isolation — different snapshot
shapes, different rhythm specs, without starting a broker thread.

**Severity:** Moderate. The struct is small. The function is clean. But
it's a concept in the wrong home.

### Finding 2: Concerns hang straight — NOT complected

The main loop (lines 123-335) does many things: submit paper, compose
thought, gate prediction, exit proposals, outcome learning, DB snapshot,
telemetry, console diagnostic. But each step is sequential, clearly
delimited with comments (numbered 1-6), and timed independently. The
telemetry block (lines 295-315) is long but flat — just emit calls.

This is the heartbeat. It orchestrates a sequence. The length is the
sequence, not interleaving. **Not a finding.**

### Finding 3: Learning inside retain closure (lines 219-257)

The `active_receipts.retain()` closure braids three concerns:
1. State discovery (treasury read — lines 220-223)
2. Outcome recording (broker state mutation — line 238)
3. Gate learning (reckoner observe + resolve — lines 243-254)

These are three different kinds of work: a read, a state transition, and
a learning event. They are braided inside a closure that also decides
retention. However, they must all execute atomically per receipt — the
outcome determines both the broker record and the gate label, and the
receipt must be removed in the same pass.

**Verdict:** Aware but acceptable. The braiding is forced by the retain
semantics. Extracting would require a two-pass approach (collect outcomes,
then learn) that splits what is logically one event. The closure is 38
lines, not 380. **Not actionable.**

---

## File 2: rhythm.rs

### Finding 4: Clean separation — NOT complected

The question: does rhythm braid AST construction with capacity management?

No. The function has five clearly labeled steps:
1. Values to thermometer+delta facts (lines 66-84)
2. Trigrams from facts (lines 87-98)
3. Bigram-pairs from trigrams (lines 101-109)
4. Trim to budget (lines 116-118)
5. Bind atom to rhythm (lines 121-125)

The capacity trim (step 4) is a post-processing step, not interleaved
with construction. The early trim (lines 57-63) prevents over-allocation
by limiting input before construction — this is an optimization, not a
braiding. The budget calculation is duplicated (lines 57 and 116) with
the same `rune:forge(dims)` annotation on both.

**Not a finding.** The function does one thing: build a rhythm AST from
a value series. The steps are sequential and each transforms the previous
output.

---

## File 3: lens.rs

### Finding 5: Dead code — old fact path braided with new rhythm path

`market_lens_facts` (line 43) and `regime_lens_facts` (line 172) are the
old encoding path. They call vocab `encode_*_facts` functions that produce
`ThoughtAST` nodes from a single candle + scale trackers.

`market_rhythm_specs` (line 296) and `regime_rhythm_specs` (line 383) are
the new encoding path. They return `IndicatorSpec` lists for rhythm
encoding from a candle window.

**The old path is dead.** Production callers:
- `market_rhythm_specs` — called by `market_observer_program.rs`
- `regime_rhythm_specs` — called by `regime_observer_program.rs`
- `market_lens_facts` — called only by tests in lens.rs
- `regime_lens_facts` — called only by tests in lens.rs

The old functions and their imports are kept alive solely by their own
tests. This is not braiding in the interleaving sense — both paths hang
straight. But the file carries 170 lines of dead production code
(`market_lens_facts` + `regime_lens_facts` + their match arms) plus 60
lines of dead tests, plus 10 dead imports (`encode_*_facts` functions).

This is a `/reap` finding more than a `/sever` finding. The old and new
paths do not interleave — they are parallel and independent. But they
cohabit the same file, creating the illusion that both paths are live.

Additionally, `market_lens_facts` calls `encode_standard_facts(window, ...)`
for DowVolume, DowCycle, DowGeneralist, WyckoffEffort, and
WyckoffPosition — but `market_rhythm_specs` has no `standard_specs()`
equivalent. The standard module's window-based facts (since-vol-spike,
dist-from-high, etc.) have no rhythm translation. This is either a
conscious omission or a gap that the dead code masks.

**Severity:** Moderate. The dead code is not harmful, but it obscures the
live architecture. When someone reads lens.rs, they see four public
functions and must grep callers to know which two are alive.

**Recommendation:** Reap the old path. Move `market_lens_facts`,
`regime_lens_facts`, their imports, and their tests to `archived/` or
delete them. If the standard-facts gap matters, track it as a separate
concern.

---

## Summary

| # | File | Type | Severity | Action |
|---|------|------|----------|--------|
| 1 | broker_program.rs:42 | Inline struct (PortfolioSnapshot) | Moderate | Extract to `vocab/exit/portfolio.rs` |
| 2 | broker_program.rs:123-335 | Heartbeat loop | — | Not complected |
| 3 | broker_program.rs:219-257 | Retain closure braids read+record+learn | Low | Aware, not actionable |
| 4 | rhythm.rs | AST construction vs capacity | — | Not complected |
| 5 | lens.rs:43-166, 172-189 | Dead fact path alongside live rhythm path | Moderate | Reap (defer to /reap ward) |

### Runes observed

- `rune:forge(dims)` at broker_program.rs:117 and rhythm.rs:57,116 — budget
  calculated from hardcoded 10_000 instead of dims parameter.
- `rune:temper(disabled)` at broker_program.rs:261 — rhythm AST serialization
  disabled due to size.

### Verdict

The broker program is not as complected as suspected. The main loop is long
but sequential — each step calls modules, and concerns are delimited. The
one real sever finding is `PortfolioSnapshot` living in the wrong file.

The rhythm function is clean. Steps are sequential, capacity is post-processing.

The lens file's real issue is dead code, not braiding. The old fact path and
new rhythm path coexist independently. This is a reap concern.

**One extraction recommended. One reap deferred.**
