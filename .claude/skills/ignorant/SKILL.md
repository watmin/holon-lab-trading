---
name: ignorant
description: The ignorant reader. Walks the path from nothing. Measures what it can't reach. The eighth ward.
argument-hint: [file-path]
---

# The Ignorant Reader

> Every document is a journal. Every reader is an observer.
> The path through the document is the candle stream.
> The understanding accumulated is the prototype.
> The ignorant reader's confusion is the residual.

The eighth ward. It measures what the other seven can't — whether
the path teaches. The wards check the code. The ignorant reader
checks the document.

## How it works

Launch a background agent that reads the target file (default:
`wat/GUIDE.md`) from top to bottom. The agent knows NOTHING about
the project. No context. No history. No memory. It is the ignorant
reader.

The agent reports:

1. **Name errors** — any name or concept referenced BEFORE it has
   been introduced. "I don't know what X is yet." These are broken
   paths — coordinates that cannot be reached from where the reader
   stands.

2. **Confusion** — any place where the reader can't understand what's
   being said because the path to understanding wasn't built. The
   concept exists but the reader can't get there.

3. **Contradictions** — two different things said about the same
   concept. The path forks and the reader can't follow both.
   This includes type mismatches: if a struct is defined with
   specific fields, but an interface claims a different return type,
   that is a contradiction. Check that struct definitions match
   how they are used in interfaces.

4. **Missing links** — a concept used in an interface but never
   defined. A name without a shape.

5. **Order violations** — a section that appears before its
   dependencies have been detailed. The construction order is wrong.

6. **Rough paths** — places where the reader succeeded but had to
   work harder than necessary. An assumption the document forced the
   reader to make. A connection between concepts that the reader had
   to infer alone. A definition that was technically present but not
   grounded enough to carry the reader through the next section.
   These aren't broken paths — they're paths that would have been
   easier with a sentence or two more. Report what you assumed and
   where, so the author can decide whether to smooth it.

## The loop

Fix, commit, test. The same loop as the enterprise.

```
observation  → the ignorant reader walks the path
findings     → what it can't reach
fix          → repair the broken coordinates
commit       → persist the fix
test         → send the ignorant reader again
```

The finding count is the proof curve. It should drop. When it rises,
the fix introduced new broken paths. When it falls, the document
got closer to teaching. When it flattens, the remaining findings are
design decisions, not text fixes.

## The principle

A document that an ignorant reader can walk from top to bottom —
building understanding at each step, never meeting a name it hasn't
been introduced to, never confused by a concept whose path wasn't
built — is a document that teaches. The ignorant reader is the proof.

The enterprise graduates from ignorance to competence through
measurement. The document graduates from broken to teachable through
the same measurement. The ignorant reader IS the candle stream.
The finding count IS the proof curve.

## When to cast

- After writing or rewriting a guide, specification, or architectural document
- After a session of changes to wat/ files
- When you suspect the path has broken — new concepts added without definitions
- As the final ward before committing a document change

## Working memory

You have a scratch directory in the workspace: `.scratch/ignorant/`.
Create it and use it:

```bash
mkdir -p .scratch/ignorant
```

Write as many files as you need — notes, inventories, cross-references.
Use the Write tool (not Bash) to create files there. The directory is
yours. You decide what to track.

**First pass — read and note.** Read the document top to bottom. When
the document references another file as a source of truth or dependency
(e.g. "defined in LANGUAGE.md", "see CIRCUIT.md"), FOLLOW THE POINTER
and read that file too. A real reader follows references. The ignorant
is a real reader. Write to your scratch files: every struct (name,
fields, types), every interface (function, params, return type), every
definition.

**Second pass — mechanical type audit.** Read your notes back. For
each type used in an interface return or parameter: does it match
a defined struct? If an interface says `→ f64` but a struct exists
for that concept, that is a contradiction. If a constructor takes
different arguments than the interface declares, that is a contradiction.
This pass is MECHANICAL — check every line, not just what confused you.

**Third pass — report.** Combine understanding issues from the read
with type issues from the audit.

When done, clean up:

```bash
rm -rf .scratch/ignorant
```

## The agent prompt

The agent receives this instruction:

> You are reading a document for the first time. You know NOTHING about
> this project. You have no context. You are the ignorant reader.
>
> Read [file] from top to bottom, exactly as written.
>
> Report: name errors, confusion, contradictions, missing links, order
> violations. If a sentence assumes knowledge you don't have yet from
> THIS document, flag it.
>
> Also report: rough paths — places where you understood but had to
> work harder than necessary. Where an assumption you had to make
> would have been easier if the document had stated it. Where a
> sentence or two more would have carried you through the next section.
> These are suggestions, not findings. Report what you assumed and where.
>
> Be thorough. Report with line references. Keep under 600 words.

The agent runs in the background. The finding count is the residual.

## Runes

There are no runes for the ignorant reader. The document either
teaches or it doesn't. There is no exception. There is no "the
reader should already know this." The reader knows nothing.

That is the point.
