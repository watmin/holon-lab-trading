---
name: gaze
description: See the form. The datamancer gazes at the code and asks — does this speak?
argument-hint: [file-path]
---

# Gaze

> The code should read like a story. Each function tells one chapter. The names are the characters. The structure is the plot. — Sandi Metz

The compiler checks if the code runs. The other wards check structure, metabolism, truth. This ward checks if the code **communicates**. Not to the compiler — to the reader who arrives with no context.

Code that communicates is code that sparks. Code that mumbles hides bugs, hides intent, hides the architecture. The gaze finds where the spark died.

## What the gaze sees

### Names

The identifier of the thing should be the thing itself.

- `dd` is not a name. `drawdown_depth` is a name.
- `sw` is not a name. `signal_weight` is a name.
- `ctx` is acceptable when the type is `CandleContext`. The type speaks.
- `i` is acceptable in a tight loop. Not in a 1000-line method.
- Single-letter names earn their place through scope. The smaller the scope, the shorter the name.

A name that forces you to find its definition to understand the code has failed. A name that IS its definition has succeeded.

### Functions

A function should fit in your mind. When you read it top to bottom, you should understand its story without jumping to another file.

- If you need to hold more than 5 things in your head, the function is too complex.
- If a function takes more than 6 parameters, it's trying to do too many things. The parameters are the function telling you it wants to be split.
- If a function is longer than your screen, it should have a reason. The heartbeat's `on_candle_inner` is long because it orchestrates a sequence — that's a reason. A helper that's long because it braids concerns is not.

### Comments

The best comment is no comment — code that speaks for itself.

- A comment that says WHAT the code does is noise. The code already says what it does.
- A comment that says WHY is signal. "The flip was removed" explains a design decision.
- A comment that says BEWARE is valuable. "This assumes sorted input" prevents bugs.
- A stale comment is worse than no comment. It lies.

### Structure

The file tree should mirror the domain. When you `ls src/`, you should see the enterprise — market, risk, treasury, not utils, helpers, common.

- Imports at the top tell you the function's world. Too many imports = too many concerns.
- A block of code separated by a blank line is claiming to be a paragraph. Does it tell one thought?
- Nested indentation beyond 3 levels is a sign the code is hiding its intent inside conditionals.

### The spark

The ineffable quality. Code where the author cared. Where every name was chosen, not defaulted. Where the structure serves comprehension, not convenience. Where you read it and think "yes, this person understood what they were building."

The spark cannot be mechanically checked. But its absence can be felt. The gaze feels for it.

## How to scan

Read the target file (default: `src/state.rs` — the fold's carrier, the densest code). For each function, each block, each name:

1. **Does the name speak?** Can you understand it without context?
2. **Does the function fit?** Can you hold it in your mind?
3. **Do the comments help?** Or do they lie, parrot, or clutter?
4. **Does the structure mirror the intent?** Does the code read like the architecture?
5. **Does it spark?** Would you be proud to show this?

Report findings as: the line, what you see, and what it would look like if it sparked. Not a rewrite — a direction. "This name mumbles. It wants to say X."

## What gaze is NOT

- Not a formatter. `cargo fmt` handles that.
- Not a linter. `clippy` handles that.
- Not decomplect. Structure is a different ward.
- Not dead-thoughts. Metabolism is a different ward.
- Not a style guide. There are no rules. There is only: does this communicate?

## The principle

Sandi Metz said: code that is easy to change is code that is easy to understand. Code that is easy to understand is code that communicates its intent. The gaze measures communication. The spark is the reward.

The datamancer gazes at the code. The code either speaks or it doesn't. Where it mumbles, we refine. Where it shines, we move on.
