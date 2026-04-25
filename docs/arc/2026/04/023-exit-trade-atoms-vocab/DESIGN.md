# Lab arc 023 — exit/trade_atoms vocab + PaperEntry type

**Status:** opened 2026-04-24. Twentieth Phase-2 vocab arc.
**First lab consumer of arc 049's newtype value semantics.**
PaperEntry ships alongside as Phase 1.9 retroactive (same
"type-with-its-caller" pattern as PortfolioSnapshot in arc 022).

**Motivation.** Port `vocab/exit/trade_atoms.rs` (120L) — the
trade-atom vocabulary the regime observer reads to decide
exit timing. 13 atoms describing a paper trade's state:
excursion, retracement, age, peak-age, signaled, trail/stop
distances, R-multiple, heat, trail-cushion, plus three phase-
biography atoms (phases-since-entry, phases-survived,
entry-vs-phase-avg). Plus the lens selector (Core = first 5,
Full = all 13).

**Blocker reassessment retired the wait.** Rewrite-backlog said
"BLOCKED on PaperEntry." Two findings closed the gap:

1. **The Vector-field framing was Rust-tier, not wat-tier.** The
   archive stores `composed_thought: Vector` as a Rust-perf
   optimization (avoid re-encoding). Wat's substrate stores the
   AST and caches vector materialization implicitly; the
   wat-native shape stores `:wat::holon::HolonAST` not Vector.
   The experiment under this arc directory
   (`holon-as-field.wat`, ran 2026-04-24) confirmed HolonAST is
   a valid struct field type.
2. **`:trading::types::Price` newtype was declared but
   inconstructible.** wat-rs arc 049 (shipped 2026-04-24) added
   `register_newtype_methods` — `(:Price/new f64)` constructor
   and `:Price/0` accessor. PaperEntry's three Price fields now
   ship properly typed.

PaperEntry is unblocked end-to-end. Arc 023 ships the type,
the vocab, and the tests in one commit.

---

## PaperEntry shape (15 fields)

```scheme
(:wat::core::struct :trading::types::PaperEntry
  (paper-id          :i64)
  (composed-thought  :wat::holon::HolonAST)
  (market-thought    :wat::holon::HolonAST)
  (position-thought  :wat::holon::HolonAST)
  (prediction        :trading::types::Direction)
  (entry-price       :trading::types::Price)
  (distances         :trading::types::Distances)
  (extreme           :f64)
  (trail-level       :trading::types::Price)
  (stop-level        :trading::types::Price)
  (signaled          :bool)
  (resolved          :bool)
  (age               :i64)
  (entry-candle      :i64)
  (price-history     :Vec<f64>))
```

Field-by-field deltas from archive:

- **`paper-id`, `age`, `entry-candle`**: archive uses `usize`;
  wat uses `:i64` per pivot.wat's existing convention (PhaseRecord's
  candle indices use `:i64`).
- **`composed-thought`, `market-thought`, `position-thought`**:
  archive uses `Vector`; wat uses `:wat::holon::HolonAST`.
  Substrate caches materialization — storing the AST is the
  honest wat-native form.
- **`entry-price`, `trail-level`, `stop-level`**: archive uses
  `Price` (newtype f64); wat uses `:trading::types::Price` (same
  newtype, now constructible via wat-rs arc 049).
- **`distances`**: archive uses `Distances` struct; wat uses the
  already-shipped `:trading::types::Distances`.
- **`prediction`**: archive uses `Direction` enum; wat uses the
  already-shipped `:trading::types::Direction`.
- **`signaled`, `resolved`**: bool, no change.
- **`extreme`, `price-history`**: f64 / Vec<f64>, no change.

**No plural typealias** — PaperEntry doesn't have an
established collection caller in this arc. If broker observers
in Phase 5 surface `:Vec<PaperEntry>`, a `PaperEntries`
typealias ships then.

---

## compute-trade-atoms shape

```scheme
(:trading::vocab::exit::trade-atoms::compute-trade-atoms
  (paper :trading::types::PaperEntry)
  (current-price :f64)
  (phase-history :trading::types::PhaseRecords)
  -> :Vec<wat::holon::HolonAST>)
```

Returns a plain `Vec<HolonAST>` of length 13. **No Scales
threading** — every atom uses fixed-bound `Log` or fixed-scale
`Thermometer(value, -1, 1)`; no scaled-linear involvement.

13 atoms in archive order:

| Pos | Atom | Encoding | Bounds / Scale | Notes |
|---|---|---|---|---|
| 0 | `exit-excursion` | Log | (0.0001, 0.5) | fraction-of-price family |
| 1 | `exit-retracement` | Thermometer | (-1, 1) | clamped to [0, 1] inside |
| 2 | `exit-age` | Log | (1.0, 100.0) | count-full-window family |
| 3 | `exit-peak-age` | Log | (1.0, 100.0) | count-full-window family |
| 4 | `exit-signaled` | Thermometer | (-1, 1) | 0.0 or 1.0 input |
| 5 | `exit-trail-distance` | Log | (0.0001, 0.5) | fraction-of-price |
| 6 | `exit-stop-distance` | Log | (0.0001, 0.5) | fraction-of-price |
| 7 | `exit-r-multiple` | Log | (0.0001, 10.0) | multiple family |
| 8 | `exit-heat` | Thermometer | (-1, 1) | clamped to ≤ 1.0 |
| 9 | `exit-trail-cushion` | Thermometer | (-1, 1) | bounded [0, 1] inside |
| 10 | `phases-since-entry` | Log | (1.0, 100.0) | count |
| 11 | `phases-survived` | Log | (1.0, 100.0) | count |
| 12 | `entry-vs-phase-avg` | Thermometer | (-1, 1) | can be negative |

Bounds rationale:

- **Fraction-of-price family `(0.0001, 0.5)`**: same as arcs
  013/015/016/017's plain-Log fraction atoms. Excursion / trail
  / stop are all fractions of entry price; max half is
  unrealistic.
- **Count-full-window family `(1.0, 100.0)`**: same as arc
  018's session-depth and arc 020's phase-rhythm budget. Paper
  ages and phase counts are bounded by typical paper lifetime
  (~100 candles).
- **Multiple family `(0.0001, 10.0)`**: new family for
  R-multiple. Profitability multiple of initial risk; 10× is
  the realistic upper saturation.

Each atom is `Bind(Atom name, <encoded value>)` — same shape as
every other vocab module's emission.

---

## Computed values — per archive

| Computed | Definition |
|---|---|
| `excursion` | `((extreme - entry) / entry).abs()` |
| `retracement` | `if excursion > 0.0001: ((extreme - current_price) / (extreme - entry)).abs().min(1.0); else 0.0` |
| `peak_age` | scan price_history backward for last index where p == extreme; `(length - 1 - i)`; else 0.0 |
| `signaled` | `if paper.signaled then 1.0 else 0.0` |
| `r_multiple` | `if stop_distance > 0.0001: excursion / stop_distance; else 0.0` |
| `remaining_profit` | `(excursion - retracement * excursion).max(0.0)` |
| `heat` | `if remaining_profit > 0.0001: trail_distance / remaining_profit; else 1.0` |
| `trail_cushion` | `if excursion > 0.0001: ((current_price - trail_level).abs() / (extreme - entry).abs()).min(1.0); else 0.0` |
| `phases_since_entry` | `count(phase_history, |r| r.start_candle >= entry_candle).max(1.0)` |
| `phases_survived` | `count(phase_history, |r| r.start_candle >= entry_candle && r.label == Peak).max(1.0)` |
| `entry_vs_phase_avg` | `if phase_history.is_empty() or entry == 0.0: 0.0; else: (entry - mean(close_avg)) / entry` |

Implemented via the natural form: `let*` chain with
`:wat::core::find-last-index` for peak_age, `:wat::core::filter`
for phase counts, `:wat::core::map` + `:wat::core::foldl` for
the mean computation, conditional ifs for the divide-by-zero
guards.

---

## select-trade-atoms shape

```scheme
(:trading::vocab::exit::trade-atoms::select-trade-atoms
  (lens :trading::types::RegimeLens)
  (atoms :Vec<wat::holon::HolonAST>)
  -> :Vec<wat::holon::HolonAST>)
```

Match on lens:
- `:trading::types::RegimeLens::Core` → `(:wat::core::take atoms 5)` — first 5 atoms.
- `:trading::types::RegimeLens::Full` → `atoms` — all 13.

Two-arm exhaustive match on a unit-variant enum. Direct port of
archive's `match` body.

---

## Sub-fogs

- **(none expected.)** All substrate primitives needed are
  present (find-last-index from arc 047; filter/map/foldl from
  earlier; newtype values from arc 049; HolonAST as struct field
  proven by experiment). The 13-atom emission is mechanical.

---

## Non-goals

- **PaperEntry constructor sugar.** The default `:PaperEntry/new`
  takes all 15 args positionally. Test fixture supplies them
  directly. The "Direction-dependent stop_level/trail_level
  initial computation" from archive's
  `PaperEntry::new(prediction, entry_price, ...)` is broker
  logic (Phase 5), not a Phase 1 type concern.
- **PaperEntry tick logic.** Archive's `tick(&mut self,
  current_price)` computes new extreme, trail, signaled, resolved
  state. That's broker mechanics (Phase 5), not vocab.
- **`PaperEntries` plural typealias.** No collection caller this
  arc; ships when one surfaces.
- **Phase 4 learning consumers.** OnlineSubspace + Reckoner take
  HolonAST when they ship; PaperEntry's three thought fields
  feed those callers in Phase 4-5. Vocab work is done at this
  arc.
