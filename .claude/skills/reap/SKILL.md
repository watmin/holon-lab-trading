---
name: reap
description: Harvest what no longer lives. The datamancer reaps dead code — structs never imported, fields never read, branches never taken. The cost of a dead thought is compute.
argument-hint: [file-path]
---

# Dead Thoughts

> A thought that produces no signal is not inert. It occupies space. It accumulates state. It steals cycles from good thoughts. — BOOK.md

The compiler warns about unused variables. It does NOT warn about:

1. **Structs defined and exported but never imported.** `grep` for `pub struct` in the file, then `grep` for its name across `src/`. If nothing imports it, it's dead.

2. **Parameters always passed as None/0/empty.** Check every call site. If every caller passes the same constant, the parameter is dead and the code that reads it is dead.

3. **Collections created but never populated.** A `Vec::new()` or `HashMap::new()` that never gets `.push()` or `.insert()`. The collection exists, passes through functions, gets checked for `.is_empty()` (always true), and the non-empty branch is dead.

4. **Branches that always evaluate the same way.** A boolean set to `false` at initialization and never changed. Every `if` that reads it goes to the else branch. The true branch is dead.

5. **Functions whose return value is always discarded.** Called with `.ok()` — fine for DB writes. But if a function returns a computed value and every caller ignores it, the computation is dead.

6. **Scaffolding that was never wired.** Variables with `_` prefix that were meant to be used later but never were. Comments saying "TODO" next to initialized-but-unused state.

## How to scan

Read the target file (default: `src/bin/enterprise.rs`). For each variable/struct/parameter:

1. Is it read after being written?
2. Is its value ever different from its initialization?
3. Does any branch depend on it actually being true/non-empty/non-None?
4. If removed, would any observable behavior change?

If the answer to all four is no, it's a dead thought. Report it.

## The visual encoding lesson

The visual encoding was removed. But PatternGroup structs kept accumulating — zero vectors compared against zero vectors, O(n × dims) per trade. Throughput degraded from 376/s to 83/s over 50k candles. Three deletions fixed it.

Later: IndicatorStreams (40 lines), suppressed_facts (always empty HashSet passed through 3 call sites), curve_stable (always false, progress line always said CALIBRATING).

Dead thoughts don't just waste space. They waste cycles, they lie to you, and they hide behind the compiler's silence.

## Runes

Skip findings annotated with `rune:reap(category)` in a comment at the site. The annotation must include a reason after the dash. Report the rune so the human knows it exists, but don't flag it as a finding.

Runes suppress bad thoughts without denying their presence. A rune tells the ward: the datamancer has been here. This is conscious.

```rust
// rune:reap(scaffolding) — exit journal learns but doesn't predict yet; wired when exit expert modulates trails
let exit_pending: Vec<ExitObservation> = Vec::new();
```

Categories: `scaffolding`, `unused-struct`, `always-none`, `never-populated`, `always-same-branch`.

## What to do

Remove the dead code. Don't comment it out. Don't add `_` prefix. Don't keep it "for compatibility." If it's dead, it's gone. Git remembers.
