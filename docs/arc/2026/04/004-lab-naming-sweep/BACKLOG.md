# Lab arc 004 — naming sweep — BACKLOG

**Shape:** three slices, five naming moves.

---

## Slice 1 — type aliases + Holons migration

**Status: ready.**

Order:
1. Add `:trading::encoding::Scales` typealias to
   `wat/encoding/scale-tracker.wat`. Before migration of
   dependent files so alias resolution works on first read.
2. Add `:trading::encoding::ScaleEmission` typealias to
   `wat/encoding/scaled-linear.wat`.
3. Python substring sweep, multi-pattern:
   - `HashMap<String,trading::encoding::ScaleTracker>` → `trading::encoding::Scales`
   - `(wat::holon::HolonAST,trading::encoding::Scales)` → `trading::encoding::ScaleEmission` (runs AFTER the first — it depends on the Scales substitution)
   - `Vec<wat::holon::HolonAST>` → `wat::holon::Holons`

Targets: `wat/`, `wat-tests/` in lab. The substitutions leave
leading `:` outside the match so both standalone and nested
positions work — same trick arcs 032 + 033 used.

**Sub-fogs:**
- **1a — order matters.** Scales MUST land before ScaleEmission
  (the tuple type has Scales inside it). Sequence: register
  Scales in scale-tracker.wat; sweep HashMap→Scales; THEN
  register ScaleEmission; THEN sweep the tuple.
- **1b — Holons sweep independence.** Holons and the
  HashMap/tuple patterns don't interfere (disjoint textual
  matches). Order among them doesn't matter.

## Slice 2 — vocab function renames + test variable renames

**Status: obvious in shape** (once slice 1 lands).

Patterns (whole-word, order matters):
1. `encode-exit-time-facts` → `encode-exit-time-holons`
2. `encode-time-facts` → `encode-time-holons`
3. `time-facts` → `time-holons` (after the above two, so the
   `time-facts` substring in `encode-time-facts` doesn't double-swap)

Then variable-name renames (lower-risk, case-insensitive whole-word):
- `facts-a` → `holons-a`
- `facts-b` → `holons-b`
- `facts-morning` → `holons-morning`
- `facts-evening` → `holons-evening`
- Standalone `facts` as a let-binding name (more careful —
  check each site manually; don't global-sed because `facts`
  appears in comments).

Targets: `wat/vocab/**/*.wat`, `wat-tests/vocab/**/*.wat`,
`wat/main.wat` (no function refs there but verify).

**Sub-fogs:**
- **2a — order of function renames.** `encode-time-facts`
  contains the substring `time-facts`. Do the longer names first.
- **2b — `facts` in comments vs code.** Keep the word in
  comments that describe the semantic ("the candle's time
  facts") — those read honestly. Only rename variables + function
  names.

## Slice 3 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slices 1 + 2 land).

- `docs/arc/2026/04/004-lab-naming-sweep/INSCRIPTION.md`
- `docs/rewrite-backlog.md` — Phase 2 section notes the rename
  (references `encode-*-holons` in the "remaining modules"
  list going forward).
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION.md`
  — three occurrences of `Vec<wat::holon::HolonAST>` in:
  - A let-binding example (line 650)
  - Bundle's signature description (line 2538)
  - The stdlib Vec constructor definition (line 2756)
  Update to use the new typealias names where honest. Bundle's
  signature description should reflect `:wat::holon::Holons →
  :wat::holon::BundleResult` (arcs 032 + 033 names).
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — new row documenting the five-move arc.
- `wat-rs/docs/USER-GUIDE.md` — verified clean, no type-shape
  references to update.

**Sub-fogs:**
- **3a — FOUNDATION historical vs current.** FOUNDATION is the
  current shipped spec, not a historical record. Update
  references where the new names are honest shipped reality.
  Prior FOUNDATION-CHANGELOG rows describing what shipped under
  old names stay — those are historical audit trail.

---

## Working notes

- Opened 2026-04-23 end of session. Fifth arc of the day.
  The naming-reflex is running continuously now.
