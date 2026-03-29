---
name: trinity
description: Run all three guard spells in parallel. Structure, metabolism, truth.
argument-hint: [file-path]
---

# Trinity

The datamancer's ward. Run all three linters in parallel against the target (default: the full enterprise).

Launch THREE SEPARATE background agents in a SINGLE message. Not one agent doing three things — three independent agents running in parallel. Each agent reads its own skill file and reports independently.

1. **`/decomplect`** — read `.claude/skills/decomplect/SKILL.md`, scan the target file(s). Recognize `decomplect:allow()` annotations. Report only new unaccepted findings.

2. **`/dead-thoughts`** — read `.claude/skills/dead-thoughts/SKILL.md`, scan the target file(s). Recognize `dead-thoughts:allow()` annotations. Report only new unaccepted findings.

3. **`/wat-check`** — read `.claude/skills/wat-check/SKILL.md`, check the relevant wat spec against its implementation counterpart. Report divergences.

All three run as background agents. Wait for all to complete. Report the combined result.

## Default targets

When no argument is given, scan the core:
- `/decomplect` → `src/bin/enterprise.rs`
- `/dead-thoughts` → `src/bin/enterprise.rs` + `src/thought/mod.rs`
- `/wat-check` → `wat/manager.wat` vs `src/market/manager.rs` + enterprise.rs

When a file is given (e.g., `src/bin/build_candles.rs`), all three scan that file, with `/wat-check` checking the relevant spec (e.g., `wat/candle.wat`).

## The expected result

Clean bills of health from all three, with accepted annotations acknowledged. If any spell finds something new, fix it before proceeding. The trinity must pass before good thoughts can begin.

## The principle

The compiler checks if the code runs. The trinity checks if the code thinks correctly. Run it after every structural change. Run it before every benchmark. The spells guard. The curve confirms.
