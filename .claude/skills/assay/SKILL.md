---
name: assay
description: Measure substance. The datamancer assays the specification — is it a program or a description? A file full of comments is a rock that glitters. The assayer crushes it and reports the fraction.
argument-hint: [file-path]
---

# Assay

> Comments tell the human. Expressions tell the wards. — The Forge

The five wards check the quality of what exists. The assay checks whether it exists at all. A specification file that's mostly comments passes sever, reap, scry, gaze, and forge — because those wards test the expressions that are present. The assay tests how many expressions are present.

## What the assay measures

### Expression density

Count the lines that are actual s-expressions (forms that begin with `(`) versus lines that are comments (begin with `;;` or `;`). Report the ratio.

| Ratio | Verdict |
|-------|---------|
| < 2:1 comments:code | **Program** — the specification expresses the system |
| 2:1 to 4:1 | **Mixed** — some prose, some program. Identify which sections are prose |
| > 4:1 | **Description** — the specification narrates but does not model |
| Comments only | **Empty** — no specification exists, only documentation |

### Function completeness

For each `define` in the file, does the body contain actual expressions or commented-out pseudocode?

- A `define` with a `let*` chain of real bindings: **expressed**
- A `define` with comments describing what the Rust does: **described**
- A `define` that returns its input unchanged with prose between: **hollow**

Report: N functions defined, M fully expressed, P described, Q hollow.

### Composition testability

Can the forge test the joints between functions in this file? If a function calls another function that exists only in comments, the joint is **untestable**. Count:

- Testable joints: function A calls function B, both are real expressions
- Untestable joints: function A references function B in a comment

### Coverage

Compare the wat file against its Rust counterpart. How many of the Rust's public functions/methods have corresponding `define` forms in the wat?

- Full coverage: every public Rust function has a wat `define`
- Partial: some functions expressed, others described or missing
- Minimal: structs declared but behavior is prose

## How to scan

1. Count comment lines vs code lines. Report the ratio.
2. For each `define`, classify as expressed / described / hollow.
3. Count testable vs untestable composition joints.
4. Compare against the Rust file for coverage.
5. Report the overall verdict: program, mixed, description, or empty.

## What assay is NOT

- Not gaze. Gaze checks beauty — does it communicate? Assay checks substance — does it express?
- Not scry. Scry checks truth — does it match the Rust? Assay checks density — how much is modeled vs narrated?
- Not forge. Forge checks craft — do the expressions compose? Assay checks existence — are there expressions to compose?
- A file can be beautiful (gaze), honest (scry), well-crafted (forge), and still empty (assay).

## Runes

Skip findings annotated with `rune:assay(category)` in a comment at the site.

```scheme
;; rune:assay(prose) — this section describes an algorithm too imperative
;; for wat; the contract is specified, the Rust implements the mechanism
```

Categories: `prose` (intentionally described, not expressed), `pending` (will be expressed when the feature is built).

## The principle

A specification that doesn't specify is a letter about a program, not the program itself. The assayer doesn't judge quality — the other five wards do that. The assayer measures quantity. Is there gold in this rock, or is it just rock?

The datamancer assays. The rock yields its fraction. What's metal becomes the program. What's slag becomes a rune explaining why.
