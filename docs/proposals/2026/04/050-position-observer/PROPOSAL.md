# Proposal 050 — The Position Observer

**Scope:** userland

**Gaze finding:** Level 1 — Lie. "Exit observer" names one-third
of the job and hides the other two.

## The renaming

The **exit observer** becomes the **position observer**.

The market observer observes the market. The position observer
observes the position. The symmetry IS the explanation.

## Why "exit observer" lies

The component:
- Decides ENTRY timing: "is this a valley? Deploy."
- Decides HOLD: "is this a transition? Ride."
- Decides EXIT: "is this a peak? Take residue."
- Thinks about trade state (excursion, retracement, age)
- Thinks about the phase series (valley → transition → peak)
- Thinks about the pivot biography (sequence of actions)
- Predicts distances (trail width, stop width)
- Manages the LIFECYCLE of engagement with the market

"Exit observer" says one of three jobs. A programmer reading it
for the first time builds a mental model where this component
fires after entry, near the end of a position's life. That
model is wrong.

## Why "position observer" speaks

A position is the lifecycle object. You open it, hold it, close
it. The position observer observes all three phases. The name
says what it thinks about — the position — the same way
"market observer" says what it thinks about — the market.

Rejected alternatives:
- **engagement observer** — "engagement" is not a trading noun.
  It mumbles. Level 2.
- **lifecycle observer** — names the pattern, not the thing.
  Software architecture word, not a trading word. The enterprise
  speaks trading.
- **trade observer** — the broker also observes trades. Ambiguous.
- **action observer** — actions are verbs. This is a noun that
  has a reckoner and learns.
- **stance observer** — invented. Not a first-class concept.

## The enterprise vocabulary

```
market observer   — observes the market. Predicts direction.
position observer — observes the position. Predicts distances.
                    Decides enter, hold, exit.
broker            — pairs market with position. Grades the pair.
treasury          — manages capital. Funds proven brokers.
reckoner          — the learning primitive. Predicts from experience.
```

## What changes

Every file that says `exit_observer`, `exit-observer`, `ExitObserver`,
`exit_idx`, `ExitLens`, `ExitLearn`, `exit_learn_tx`, `exit_thought`,
`exit_anomaly`, `exit_distances`, `exit_batch`, `exit-slot`,
`exit-core`, `exit-full`:

→ `position_observer`, `position-observer`, `PositionObserver`,
`position_idx`, `PositionLens`, `PositionLearn`, `position_learn_tx`,
`position_thought`, `position_anomaly`, `position_distances`,
`position_batch`, `position-slot`, `position-core`, `position-full`.

The `ExitLearn` struct becomes `PositionLearn`. The `ExitSlot`
becomes `PositionSlot`. The exit observer program becomes the
position observer program.

## What doesn't change

- The behavior. Zero logic changes. Pure rename.
- The pipeline. The chain types. The telemetry.
- The reckoners. The distances. The noise subspace.
- The 10 trade atoms (040). The 2 lenses (core, full).
- The broker. The market observer. The treasury.
- The architecture just is.

## The timing

This rename should happen BEFORE the phase labeler (049) and
pivot biography integration (044-048 phase 2). The position
observer is about to gain phase-awareness and entry/hold/exit
vocabulary. Renaming after that work would touch more files.
Rename now. Build on the honest name.

## Designer review

Three designers reviewed.

- **Seykota:** REJECTED. Proposed "distance observer" — names
  what the reckoners predict today.
- **Hickey:** CONDITIONAL. Also proposed "distance observer."
  "Names for future things are lies told early."
- **Beckman:** CONDITIONAL. Accepted "position observer" as
  forward declaration — must ship with the phase labeler.

The tension: "distance observer" is honest now. "Position
observer" is honest after 049 lands.

## Resolution

**Position observer.** Shipped with 049's phase labeler in
the same commit. The name and the capability arrive together.
No window where the name lies. Beckman's condition is met —
the forward declaration is honored in the same development
cycle.

"Distance observer" names today's interface but not tomorrow's.
The component is about to gain phase awareness, entry/hold/exit
vocabulary, and position lifecycle management. Naming it for
what it predicts TODAY would require a second rename when 049
lands. Name it once. Name it right. Ship both together.

**APPROVED by the datamancer.**
