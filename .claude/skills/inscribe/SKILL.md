---
name: inscribe
description: Cut words into stone. Read the guide, write the wat. The first creative spell.
argument-hint: [entity-name]
---

# Inscribe

> The guide speaks the thought. Inscribe gives it form.

The ninth spell. The first that creates. The other eight defend.
Inscribe reads a section of `wat/GUIDE.md` and writes a `.wat` file —
s-expressions in the wat language. Logic, not prose. Code, not
description.

## How it works

The agent receives an entity name (e.g. "raw-candle", "broker",
"treasury"). It reads the guide's section for that entity — the struct
definition, the interface, the constructor, the dependencies. It writes
a `.wat` file that implements the entity in the wat language.

The wat language: `~/work/holon/wat/LANGUAGE.md` — the source of truth
for syntax, forms, and host language.

**What the agent reads:**
- `wat/GUIDE.md` — the section for this entity (struct, interface, dependencies)
- `~/work/holon/wat/LANGUAGE.md` — the wat language specification

**What the agent writes:**
- One `.wat` file in the `wat/` directory (e.g. `wat/raw-candle.wat`)

**What the agent does NOT do:**
- Does not invent. Every struct field, every interface signature, every
  type comes from the guide. The guide is the authority.
- Does not write prose. The wat file is code — s-expressions. Comments
  are allowed but the file is primarily logic.
- Does not write Rust. The wat is the intermediate layer.

## The construction order

Leaves to root. The guide's construction order IS the build order:

```
1. raw-candle, indicator-bank, window-sampler, scalar-accumulator
2. candle (produced by indicator-bank)
3. vocabulary modules (shared/, market/, exit/)
4. thought-encoder
5. enums: Side, Direction, Outcome, TradePhase, reckoner-config, prediction
6. newtypes: TradeId
7. distances, levels
8. market-observer, exit-observer
9. paper-entry
10. broker
11. proposal, trade, treasury-settlement, settlement, resolution, log-entry, trade-origin
12. post
13. treasury
14. enterprise
```

Each file is inscribed after its dependencies. The ignorant judges each
file against the guide before the next is inscribed.

## The loop

```
inscribe  → write the wat file from the guide section
ignorant  → read the wat file against the guide — does it match?
fix       → repair what the ignorant found
commit    → persist
next leaf → the construction order advances
```

The inscribe/ignorant pair is the producer/consumer. The wat files are
the message buffer. Async. The inscribe runs. The ignorant judges.

## The principle

The guide speaks. Inscribe commits. The wat file IS the guide section
given form. If the guide section says the struct has four fields, the
wat file has four fields. If the guide section says the interface takes
three parameters, the wat file takes three parameters. No invention.
No interpretation. Transcription with precision.

The guide is the architect's drawing. The wat is the stone. Inscribe
is the chisel.
