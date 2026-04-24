# Lab arc 004 — naming sweep

**Status:** opened 2026-04-23. Fifth naming arc of the session
(third, fourth, fifth under `/gaze`: wat-rs 032 BundleResult,
wat-rs 033 Holons, plus tonight's file-rename sweep). The reflex
arrived earlier in the session; arc 004 applies it across the
lab's domain vocabulary in one pass.

**Motivation.** `/gaze` surfaced multiple redundant / epistemically-
wrong names in rapid succession tonight:
- `:HashMap<String, trading::encoding::ScaleTracker>` — 25 occurrences, no name.
- `:(wat::holon::HolonAST, HashMap<...ScaleTracker>)` — 10 occurrences, no name.
- `:Vec<wat::holon::HolonAST>` — 35 lab occurrences, no name until arc 033.
- `encode-time-facts` / `time-facts` / `encode-exit-time-facts` — vocab functions naming their return as "facts." Once `Holons` became the substrate type name, the vocab-function names drifted out of sync: they return `Holons`, not "facts."

All five naming moves in one arc because they touch overlapping
files (every vocab test references the return type AND the
function name AND the variable-name convention). Batching keeps
the commit history clean — one arc, one review surface.

---

## The five moves

### 1. `:trading::encoding::Scales`

```
typealias :trading::encoding::Scales
  = :HashMap<String, trading::encoding::ScaleTracker>
```

Location: `wat/encoding/scale-tracker.wat` (next to the ScaleTracker
struct it aggregates). Every file that loads scale-tracker.wat
(transitively or directly) sees Scales.

Domain word: the archive's Rust uses `scales: HashMap<...>` as the
variable name. Plural of the element type's concept. Self-describing.

### 2. `:trading::encoding::ScaleEmission`

```
typealias :trading::encoding::ScaleEmission
  = :(wat::holon::HolonAST, trading::encoding::Scales)
```

Location: `wat/encoding/scaled-linear.wat` (the function that
returns this shape). Every scaled-linear-style encoding call
(present + future) returns a ScaleEmission — a holon paired with
the updated scales.

Name rationale: "emission that updated scales" — scaled-linear
emits a holon while updating scales state; the tuple IS that
dual product.

### 3. Lab-wide Holons migration

Apply arc 033's `:wat::holon::Holons` alias across the lab's
35 occurrences. Files:
- `wat/vocab/**/*.wat` (encode-*-facts return type annotations)
- `wat-tests/vocab/**/*.wat` (let-binding annotations)
- `wat-tests/encoding/**/*.wat` (stream tests)
- `wat/encoding/rhythm.wat` (if any remain)

### 4. Vocab function renames: `-facts` → `-holons`

The vocab functions emit Holons (arc 033's type name). The `-facts`
suffix drifts out of sync. `/gaze` discipline:

- `encode-time-facts` → `encode-time-holons`
- `time-facts` → `time-holons`
- `encode-exit-time-facts` → `encode-exit-time-holons`

The `-facts` era ended with arc 033's substrate alias. Any future
vocab function uses `-holons` as the return-shape suffix.

### 5. Test variable renames: `facts*` → `holons*`

Test `let*` bindings for the return value of vocab functions
currently use `facts`, `facts-a`, `facts-b`, `facts-morning`,
`facts-evening` as variable names. Renamed to `holons`,
`holons-a`, etc., to stay consistent with the function names.

Not mandatory under the type alias (variable names are informal),
but honest: if the function is `encode-time-holons`, the returned
value reads clearest as `holons`.

---

## Why all five in one arc

They touch the same files. Splitting would force each file
through three review cycles for three commits that do mechanically-
identical textual swaps. Batching is honest.

Arc INSCRIPTION records each move separately so future readers
can see the five distinct naming decisions even though they
shipped together.

---

## What does NOT change

- **Vocab module names.** `wat/vocab/shared/time.wat` stays at
  `time.wat`; the namespace is `:trading::vocab::shared::time::*`.
  Only the function suffix changes.
- **The algebra module names.** `wat/holon/*.wat` files stay
  (they are named for the TYPE they export, not a verb pattern).
- **Cross-repo loads or Rust bridge code.** No Rust-side rename;
  lab Cargo.toml, main.rs unchanged.
- **058 proposal prose.** Historical records keep their voice.

---

## Follow-through

Every new vocab module (arc 005 onward: market/standard, exit/phase,
etc.) uses `-holons` as the return-value suffix from the start.
The `-facts` convention ends with arc 004. Arc 001 + 002's
INSCRIPTIONs stay as-is (historical record of what shipped
pre-rename).
