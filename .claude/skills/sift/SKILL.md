---
name: sift
description: Sift real forms from imposters. The farmer sifts grain from chaff. The datamancer sifts valid language from phantom syntax.
argument-hint: [file-path or directory]
---

# Sift

> What belongs passes through. What doesn't gets caught.

The tenth ward. Language conformance. Does the wat use only valid
forms from the language specification?

## How it works

The agent reads the wat language specification:
`~/work/holon/wat/LANGUAGE.md`

Then reads the target wat file(s). For every form used — every
function call, every control flow construct, every host form,
every structural form — the agent checks: is this defined in
LANGUAGE.md?

The agent reports:

1. **Phantom forms** — syntax that looks valid but isn't defined.
   `pmap-indexed`, `hash-map`, `defn` — things that feel like
   they should exist but don't. The wat compiles to Rust. If the
   form doesn't exist, the Rust has nothing to compile to.

2. **Misused forms** — a form used with the wrong arity or shape.
   `(match x (a b))` where match expects `((Pattern) body)`.
   The form exists but the usage is wrong.

3. **Missing requires** — a form from a wat file used without
   requiring it. The form exists but the dependency isn't declared.

## What the agent reads

- `~/work/holon/wat/LANGUAGE.md` — the grammar, host forms, core forms
- `~/work/holon/wat/core/primitives.wat` — the algebra + reckoner coalgebra
- `~/work/holon/wat/std/*.wat` — stdlib operations
- The target wat file(s)

## The principle

The wat language has a finite set of forms. Everything used in a wat
file must trace back to one of: the host language (LANGUAGE.md), the
core primitives (core/primitives.wat), the stdlib (std/*.wat), or a
required application file. If a form can't be traced, it's a phantom.
Phantoms compile to nothing.

The farmer sifts grain from chaff. The datamancer sifts real forms
from imposters. What belongs passes through. What doesn't gets caught.
