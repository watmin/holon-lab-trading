---
name: wards
description: The datamancer's defense. Six spells that guard against bad thoughts. Structure, metabolism, truth, beauty, craft, substance.
argument-hint: [file-path]
---

# Wards

The datamancer's defense. Run all six guard spells in parallel against the target (default: the full enterprise).

Launch SIX SEPARATE background agents in a SINGLE message. Not one agent doing six things — six independent agents running in parallel. Each agent reads its own skill file and reports independently.

1. **`/sever`** — read `.claude/skills/sever/SKILL.md`, scan the target file(s). Cuts tangled threads. Finds braided concerns, misplaced logic, duplicated encoding. Recognize `rune:sever()` runes.

2. **`/reap`** — read `.claude/skills/reap/SKILL.md`, scan the target file(s). Harvests what no longer lives. Finds dead code, unused structs, write-only fields. Recognize `rune:reap()` runes.

3. **`/scry`** — read `.claude/skills/scry/SKILL.md`, check the relevant wat spec against its implementation counterpart. Divines truth from intention. Finds divergences between spec and code. Recognize `rune:scry()` runes.

4. **`/gaze`** — read `.claude/skills/gaze/SKILL.md`, scan the target file(s). Sees the form. Finds names that mumble, functions that don't fit in the mind, comments that lie, structure that hides intent. Recognize `rune:gaze()` runes.

5. **`/forge`** — read `.claude/skills/forge/SKILL.md`, scan the target file(s). Tests the craft. Hickey's heat removes impurity, Beckman's hammer tests composition. Values not places, types that enforce, abstractions at the right level, functions that compose. Recognize `rune:forge()` runes.

All five run as background agents. Wait for all to complete. Report the combined result.

## Default targets

When no argument is given, scan the core:
- `/sever` → `src/bin/enterprise.rs`
- `/reap` → `src/bin/enterprise.rs` + `src/state.rs`
- `/scry` → `wat/market/manager.wat` vs `src/market/manager.rs` + `src/state.rs`
- `/gaze` → `src/state.rs` (the densest code, where the spark matters most)

6. **`/assay`** — read `.claude/skills/assay/SKILL.md`, scan the target file(s). Measures substance. Is this a program or a description? Count expressions vs comments. Report the fraction. A specification that doesn't specify is just a letter about a program.

When a file is given, all six scan that file.

## The expected result

Clean bills from all six, with runes acknowledged. If any ward finds something, fix it before proceeding. The wards must pass before good thoughts can begin.

## The principle

The compiler checks if the code runs. The wards check if the code thinks correctly, lives honestly, speaks truly, shines beautifully, composes cleanly, and expresses fully. They are the datamancer's defense against bad thoughts.

Six wards. Six verbs. Sever. Reap. Scry. Gaze. Forge. Assay.
