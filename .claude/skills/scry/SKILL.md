---
name: scry
description: Divine truth from intention. The datamancer scries the wat specification against the Rust implementation. When code and spec diverge, one of them is wrong.
argument-hint: [wat-file]
---

# Wat Check

> The spec is the source of truth for what the enterprise SHOULD do. The Rust implements it. When code and spec diverge, update the one that's wrong. — CLAUDE.md

Two layers of specification:

**Language layer** (`~/work/holon/wat/`): the wat repo defines the core primitives and stdlib. This is the language definition — the source of truth for what the primitives ARE. Always read `~/work/holon/wat/core/primitives.wat` and relevant `~/work/holon/wat/std/*.wat` files.

**Application layer** (`wat/` in this repo): domain specifications for the trading enterprise. These use the language primitives to describe what each component thinks.

The Rust in `src/` implements both layers — `holon-rs` implements the language, `src/` implements the application.

This skill finds divergence between specs and implementation at BOTH layers.

## How to check

First, read the language core: `~/work/holon/wat/core/primitives.wat`. Verify the Rust code uses the primitives as defined (correct forms, correct types, Labels as symbols, journal coalgebra interface).

Then, for a given application wat file (default: all in `wat/`), read the spec and find its implementation counterpart:

```
wat/market/manager.wat        → src/market/manager.rs + enterprise.rs (manager sections)
wat/market/generalist.wat     → enterprise.rs (generalist sections)
wat/market/observer/*.wat     → src/market/observer.rs + src/thought/mod.rs
wat/risk.wat                  → src/risk/ + enterprise.rs (risk sections)
wat/treasury.wat              → src/treasury.rs + enterprise.rs (treasury sections)
wat/ledger.wat                → src/ledger.rs
wat/position.wat              → src/position.rs + enterprise.rs (position sections)
wat/vocab.wat                 → src/vocab/mod.rs + src/vocab/*.rs
```

For each spec section, verify:

1. **Atoms match.** Every atom declared in the spec exists in the implementation. Every atom used in the implementation is declared in the spec.

2. **Encoding matches.** The encoding pattern described in the spec (bind, bundle, encode-linear, encode-log, encode-circular) matches what the code does. Same atoms, same composition, same scalar modes.

3. **Labels match.** The learning labels described in the spec (Buy/Sell for direction, Win/Lose for profitability, Healthy/Unhealthy for risk) match what the code passes to `journal.observe()`. No label mixing — each journal gets ONE kind of label.

4. **"Does NOT" clauses hold.** Every spec has a section saying what the component does NOT do. Verify the implementation respects these boundaries. The manager does NOT encode candles. The treasury does NOT predict. The ledger does NOT transform.

5. **Learning frequency matches.** The spec says when learning happens (at horizon, at first crossing, at resolution). The code should learn at the same events, not more, not fewer.

6. **Gate conditions match.** The spec describes proof gates (curve validation, minimum accuracy). The code should gate at the same thresholds using the same mechanism.

7. **Abstractions match.** For each `define` in the wat, does a corresponding function exist in the Rust? The wat names its helpers — `linreg-slope`, `bind-triple`, `panel-shape`, `market-context`. The Rust should have corresponding functions. If the wat extracted a helper, the Rust should extract the same helper. If the Rust inlines what the wat named, the structural intent has diverged. The incantation says HOW the code is organized, not just WHAT it produces. The compiled spell should follow the blueprint's structure.

8. **Host forms preserved.** When the wat uses a host language form (`quantile`, `sort`, `mean`, `fold`, `encode-linear`, etc.), the Rust should implement it as ONE operation, not expand it into multiple steps. If the wat says `(quantile xs q)`, the Rust should call a quantile function — not inline `collect → sort → index`. The host form is an abstraction. Inlining it in the Rust breaks the abstraction and may introduce inefficiency. Check: for each host form used in the wat, does the Rust preserve it as a single operation? Refer to docs/COMPILATION.md for the expected mappings.

## What to report

For each divergence:
- **Spec says:** (quote the relevant wat lines)
- **Code does:** (cite file:line and what it actually does)
- **Verdict:** spec is right and code should change, OR code evolved past the spec and spec should update

## Runes

Skip divergences annotated with `rune:scry(category)` in the code. Report the rune so the human knows it exists, but don't flag it as a finding.

Runes suppress bad thoughts without denying their presence. A rune tells the ward: the datamancer has been here. This is conscious.

```rust
// rune:scry(aspirational) — risk manager with Journal-based learning not yet implemented
```

Categories: `aspirational` (spec describes future work), `evolved` (code intentionally diverges, spec needs update).

## The principle

The wat files are the sorcerer's incantations — what the enterprise SHOULD think. The Rust is the compiled spell. When the compiled spell doesn't match the incantation, the spell is broken. The curve won't confirm a broken spell.
