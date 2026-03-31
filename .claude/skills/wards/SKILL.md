---
name: wards
description: The datamancer's defense. Four spells that guard against bad thoughts. Structure, metabolism, truth, beauty.
argument-hint: [file-path]
---

# Wards

The datamancer's defense. Run all four guard spells in parallel against the target (default: the full enterprise).

Launch FOUR SEPARATE background agents in a SINGLE message. Not one agent doing four things — four independent agents running in parallel. Each agent reads its own skill file and reports independently.

1. **`/sever`** — read `.claude/skills/sever/SKILL.md`, scan the target file(s). Cuts tangled threads. Finds braided concerns, misplaced logic, duplicated encoding. Recognize `decomplect:allow()` annotations.

2. **`/reap`** — read `.claude/skills/reap/SKILL.md`, scan the target file(s). Harvests what no longer lives. Finds dead code, unused structs, write-only fields. Recognize `dead-thoughts:allow()` annotations.

3. **`/scry`** — read `.claude/skills/scry/SKILL.md`, check the relevant wat spec against its implementation counterpart. Divines truth from intention. Finds divergences between spec and code.

4. **`/gaze`** — read `.claude/skills/gaze/SKILL.md`, scan the target file(s). Sees the form. Finds names that mumble, functions that don't fit in the mind, comments that lie, structure that hides intent.

All four run as background agents. Wait for all to complete. Report the combined result.

## Default targets

When no argument is given, scan the core:
- `/sever` → `src/bin/enterprise.rs`
- `/reap` → `src/bin/enterprise.rs` + `src/state.rs`
- `/scry` → `wat/market/manager.wat` vs `src/market/manager.rs` + `src/state.rs`
- `/gaze` → `src/state.rs` (the densest code, where the spark matters most)

When a file is given, all four scan that file.

## The expected result

Clean bills from all four, with accepted annotations acknowledged. If any ward finds something, fix it before proceeding. The wards must pass before good thoughts can begin.

## The principle

The compiler checks if the code runs. The wards check if the code thinks correctly, lives honestly, speaks truly, and shines beautifully. They are the datamancer's defense against bad thoughts.

Four wards. Four verbs. Sever. Reap. Scry. Gaze.
