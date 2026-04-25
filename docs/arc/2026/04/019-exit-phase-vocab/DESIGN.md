# Lab arc 019 — exit/phase vocab (current + scalar functions)

**Status:** opened 2026-04-24. Sixteenth Phase-2 vocab arc.
**First exit sub-tree vocab.** **First lab consumer of
user-enum match** (arc 048's capability finds its first caller).

**Motivation.** Port `vocab/exit/phase.rs` (348L, three
functions). This arc ships TWO of the three functions; the
third — `phase_rhythm_thought` (stateful 5-way-index
iteration + bigrams-of-trigrams + budget truncation) — is its
own substantial piece of work and ships as **arc 020** after
this one lands.

The two shipping here:

1. **`encode-phase-current-facts`** — 2 atoms describing the
   candle's current phase: a `phase` binding to the label name
   (derived from PhaseLabel + PhaseDirection via match) plus a
   `phase-duration` scaled-linear.
2. **`encode-phase-scalar-facts`** — up to 4 atoms describing
   phase history trends (valley-trend, peak-trend, range-trend,
   spacing-trend). Filter-based: takes PhaseRecords filtered by
   label, computes trends from the last-two of each filter.

The **rhythm** function deferred to arc 020: builds
bigrams-of-trigrams of per-record Bundles where each Bundle
carries 4-10 facts including prior-record deltas and
same-label-prior deltas. The 5-way state tracker
(last_valley, last_peak, last_trans_up, last_trans_down) is
non-trivial in wat; it deserves its own arc.

---

## Shape

Two public defines; one private helper.

```scheme
;; Helper — user-enum match exercises arc 048 capability.
(:trading::vocab::exit::phase::phase-label-name
  (label :trading::types::PhaseLabel)
  (direction :trading::types::PhaseDirection)
  -> :String)

;; Current — reads the Candle::Phase sub-struct.
(:trading::vocab::exit::phase::encode-phase-current-holons
  (p :trading::types::Candle::Phase)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)

;; Scalar trends — reads the Vec<PhaseRecord> history.
(:trading::vocab::exit::phase::encode-phase-scalar-holons
  (history :Vec<trading::types::PhaseRecord>)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

The three-function split matches the archive — each is
independently useful; the future regime observer calls whichever
combination it needs.

---

## The phase-label-name helper — arc 048's first real use

```scheme
(:wat::core::define
  (:trading::vocab::exit::phase::phase-label-name
    (label :trading::types::PhaseLabel)
    (direction :trading::types::PhaseDirection)
    -> :String)
  (:wat::core::match label -> :String
    (:trading::types::PhaseLabel::Valley "valley")
    (:trading::types::PhaseLabel::Peak   "peak")
    (:trading::types::PhaseLabel::Transition
      (:wat::core::match direction -> :String
        (:trading::types::PhaseDirection::Up   "transition-up")
        (:trading::types::PhaseDirection::Down "transition-down")
        (:trading::types::PhaseDirection::None "transition")))))
```

This is exactly the shape arc 048 ships support for: nested
match on two user enums, each arm producing a String. The
caller then wraps with `(Bind (Atom "phase") (Atom ...))` to
build the phase-label atom.

If this works cleanly it's the validation that arc 048 landed
correctly. If the port hits a wrinkle in arc 048's
implementation, this is where it surfaces.

---

## encode-phase-current-holons — 2 atoms

```scheme
;; phase-label atom: (Bind (Atom "phase") (Atom <name>))
;; phase-duration: scaled-linear
```

Reads `Candle::Phase` sub-struct's label + direction + duration
fields. The phase-label atom is NOT scaled-linear — it's a
nominal binding to a name-atom, no scale tracking.
phase-duration is a normal scaled-linear of the duration (i64
→ f64 conversion needed for scaled-linear's f64 input).

Returns emission of `(holons [phase-label, phase-duration], updated-scales)`.

---

## encode-phase-scalar-holons — up to 4 atoms

Four atoms, each CONDITIONALLY emitted based on history
sufficiency:

| Atom | Condition | Source |
|---|---|---|
| `phase-valley-trend` | ≥ 2 Valley records | `(last-valley.close-avg - prev-valley.close-avg) / prev-valley.close-avg` |
| `phase-peak-trend` | ≥ 2 Peak records | same shape with peaks |
| `phase-range-trend` | ≥ 2 total records | `last.range / prev.range` (last-two records, any label) |
| `phase-spacing-trend` | ≥ 2 total records + prev.duration > 0 | `last.duration / prev.duration` |

Pattern:
- Filter records by label (Valley-only, then Peak-only)
- `(last)` and `(second-to-last)` each filtered Vec — use `last`
  + `get vec (len - 2)` shape
- Compute trend, round, scaled-linear emit
- Guard emission on preconditions — uses `conj` to
  conditionally extend the Holons vec

New shape: **conditional emission based on history subset
length**. Similar to arc 006 divergence's conditional emission,
but the condition here is data-driven (history composition)
rather than value-driven (divergence strength).

Uses substrate `:wat::core::filter` (confirmed present) +
arc 047's `last` / `get` primitives.

---

## Signature consumers of Candle::Phase

Arc 008's K-sub-struct rule applies: single-candle vocabs take
specific sub-structs. Current-facts takes `Candle::Phase`
(K=1). Scalar-facts takes `Vec<PhaseRecord>` directly (it's a
vector of a struct, not a sub-struct of Candle — the history is
internal to the phase state).

Both functions are "sub-struct-level" by the rule; neither
crosses sub-structs. Future regime observer will call both with
the right slices of a single Candle.

---

## Why split from the rhythm

The rhythm function (`phase_rhythm_thought`) is qualitatively
different:
- Iterates `Vec<PhaseRecord>` with 5-way state (last_valley,
  last_peak, last_trans_up, last_trans_down + current index).
- Each record's output is a **nested Bundle** of 4-10 facts
  (label + own properties + conditional prior-delta + conditional
  same-label-delta).
- Windowing produces **bigrams of trigrams** (4-level tree of
  binds).
- Budget-truncates to the last ~100 records (sqrt of d=10000).

This is a full arc's worth of substrate-shape thinking — multi-
accumulator folds, nested Bundle construction, budget math. Arc
020 gets the thinking + implementation time it deserves.

Splitting doesn't block anything downstream: the regime observer
isn't shipping until exit/regime + broker ports land. Phase-
current + phase-scalar give the lab 80% of phase vocab working
immediately; rhythm closes the loop when arc 020 ships.

---

## Substrate primitives consumed

All present:
- `:wat::core::match` on user enums (arc 048) — phase-label-name
- `:wat::core::filter` — filtering history by label
- `:wat::core::length` — count filtered histories
- `:wat::core::last` (arc 047) — last of filtered Vec
- `:wat::core::get` — (len - 2) access for "previous" element
- `:wat::core::i64::to-f64` — duration conversion
- `:wat::core::f64::/` + other arith
- `:trading::encoding::round-to-2` / `round-to-4`
- `:trading::encoding::scaled-linear`

If any is missing, ship a sub-arc; none expected.

---

## Non-goals

- **Phase rhythm function.** Deferred to arc 020.
- **Cross-phase state aggregation** beyond the scalar trends.
  The rhythm arc carries all multi-record Bundle construction.
- **Integration with regime observer.** That ships when the
  exit observer tree is complete; phase is just one vocab in it.
- **Empirical refinement of scale-boundaries** for trend atoms.
  Best-current-estimate; future explore-log arc if observation
  data shows otherwise.
