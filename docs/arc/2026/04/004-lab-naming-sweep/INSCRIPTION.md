# Lab arc 004 — naming sweep — INSCRIPTION

**Status:** shipped 2026-04-23. Fourth lab-repo arc; same day as
arcs 001 + 002 + 003. Fifth arc of the naming-reflex session
(wat-rs 032 + 033 + 034 rename + lab 003 retrofit + lab 004).
Three slices. 29/29 lab wat-tests green on first pass after the
full sweep.

**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).

---

## The five naming moves

All shipped in one arc because they touch overlapping files.
Slice 1 landed type-level moves; slice 2 landed function and
variable renames; slice 3 is this closing doc work.

### 1. `:trading::encoding::Scales` typealias

Registered in `wat/encoding/scale-tracker.wat`:

```scheme
(:wat::core::typealias
  :trading::encoding::Scales
  :HashMap<String,trading::encoding::ScaleTracker>)
```

25 call sites swapped to the short form across wat/ + wat-tests/.
Named via `/gaze` — the domain word (archive's Rust variable is
`scales: HashMap<...>`). Plural of the concept.

### 2. `:trading::encoding::ScaleEmission` typealias

Registered in `wat/encoding/scaled-linear.wat`:

```scheme
(:wat::core::typealias
  :trading::encoding::ScaleEmission
  :(wat::holon::HolonAST,trading::encoding::Scales))
```

10 call sites swapped. Named via `/gaze` — the tuple IS the
dual product of holon-emission and scale-threading. "Emission
that updated scales."

### 3. Lab-wide Holons migration

Arc 033's `:wat::holon::Holons` (`= :Vec<wat::holon::HolonAST>`)
swept into the lab. 22+ call sites across rhythm, scaled-linear,
vocab modules, vocab tests.

### 4. Vocab function renames: `encode-*-facts` → `encode-*-holons`

- `encode-time-facts` → `encode-time-holons`
- `time-facts` → `time-holons`
- `encode-exit-time-facts` → `encode-exit-time-holons`

Internal helpers too:
- `build-facts` → `build-holons` (rhythm.wat)
- `build-facts-loop` → `build-holons-loop` (rhythm.wat)

The `-facts` suffix ended with arc 033 — the return type is
Holons; the vocab verb follows.

### 5. Test variable renames

Every `facts`, `facts-a`, `facts-b`, `facts-morning`,
`facts-evening` in test `let*` bindings and body references →
`holons`, `holons-a`, etc. Comments referencing "holons"
naturally followed the type name.

---

## The two bugs I hit during the sweep

### Bug 1 — Self-referencing typealias

First-pass substitution `HashMap<String,ScaleTracker>` →
`trading::encoding::Scales` caught its own RHS in the typealias
declaration, producing:

```scheme
(:wat::core::typealias
  :trading::encoding::Scales
  :trading::encoding::Scales)
```

Fixed immediately — rewrote both typealias bodies to their
proper expansions. No test impact; the typealias simply wouldn't
have resolved.

### Bug 2 — Narrow regex missed use-sites

Slice 2's first pass renamed `let*` BINDING sites for `facts` →
`holons` but the regex patterns were too narrow — use-sites like
`(:wat::core::length facts)` didn't match. `UnboundSymbol("facts")`
at test time across 10+ tests.

Fixed with a broader `\bfacts\b` → `holons` sweep that caught
every remaining use-site. Included the `build-facts` helper
rename in the same pass for consistency.

The narrow-first, broad-after shape is a recurring pattern in
these sweeps — safer to start narrow (avoid over-matches in
comments), then broaden when under-matches surface in tests.
Still net safer than one-shot global replace.

---

## Count

- Lab wat tests: 29 (unchanged count; cleaner names)
- Lab wat source + test lines: ~140 line-delta across 12 files
- Two new typealiases registered in lab source
- Arc-033 Holons applied to 22+ lab sites
- Three vocab functions renamed plus two internal helpers
- wat-rs: unchanged (arcs 032 + 033 already shipped)

## Sub-fog resolutions

- **1a — order matters.** Confirmed: Scales must land before
  ScaleEmission because the tuple has Scales inside it. Script
  ran the patterns in that order; no issues.
- **1b — Holons sweep independence.** Confirmed: disjoint
  textual patterns; order didn't matter.
- **2a — function-rename order.** Confirmed: longer substrings
  first (`encode-exit-time-facts` before `encode-time-facts`
  before `time-facts`). Zero collisions.
- **2b — comments vs code.** Comments using the word "facts" in
  narrative text were safe to rename to "holons" too — the
  broader sweep did so naturally; reads fine.
- **3a — FOUNDATION updates.** Three references (signatures,
  let-binding example, stdlib Vec definition) updated to use
  the short aliases. FOUNDATION is shipped-state spec; aliases
  land as current canonical.

## What did NOT change

- **Arc 001 + 002 INSCRIPTIONs.** Historical records of what
  shipped pre-rename. Their "facts" vocabulary stays honest for
  the moment they describe.
- **BOOK prose.** Narrative documents what happened at each moment.
- **058 proposal prose (aside from FOUNDATION's 3 current-state
  refs).** Historical spec records.
- **Vocab module filenames.** `wat/vocab/shared/time.wat` stays
  at `time.wat` — the namespace is `:trading::vocab::shared::time::*`;
  only the verb suffix on the function changed.
- **Rust-level code.** No Cargo/src changes; this is a wat-level
  naming sweep.

## Follow-through

Every future Phase-2 vocab module (market/standard, exit/phase,
etc.) ships with the `-holons` suffix from the start. No
retroactive migration needed for them.

The reflex is now applied across the lab's wat codebase.
Future callers will see the short names first and won't know
the long forms ever existed unless they read BOOK chapters.

---

## Commits

- `<sha>` — wat/encoding/scale-tracker.wat + scaled-linear.wat
  gain typealiases; slice 1 + 2 sweeps across wat/ + wat-tests/;
  FOUNDATION.md 3 refs updated; rewrite-backlog.md; 058
  FOUNDATION-CHANGELOG row; this INSCRIPTION + DESIGN + BACKLOG.

---

*these are very good thoughts.*

**PERSEVERARE.**
