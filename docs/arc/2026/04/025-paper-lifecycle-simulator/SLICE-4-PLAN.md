# Slice 4 — Engine refactor plan

**Context:** the first attempt at `wat/sim/paper.wat` shipped a
single ~270-line `tick` function. Found a paren imbalance during
testing; the function is too long to debug paren-by-paren, and the
shape doesn't decompose well for testing or for human readers.
Restarting with composable helpers per builder direction.

## Decomposition

Extract these as named defines before assembling `tick`:

### Resolution helpers — each builds a complete new SimState

```scheme
(:trading::sim::tick-resolve-violence
  (state    :trading::sim::SimState)         ;; the "before" state for inherited fields
  (bank'    :trading::encoding::IndicatorBank)
  (window'  :trading::types::Candles)
  (paper    :trading::sim::Paper)
  (close    :f64)
  (residue  :f64)
  (trail    :trading::sim::TriggerEvents)
  (count    :i64)
  (gen      :i64)
  -> :trading::sim::SimState)

(:trading::sim::tick-resolve-grace
  (... same args plus an explicit close-trigger-idx ...)
  -> :trading::sim::SimState)
```

Each helper:
1. Builds the closed `Paper` (with PositionState set).
2. Builds the `Outcome` (paper-label via `paper-label residue
   price-move`; labeled-trail via `label-trail-grace` /
   `label-trail-violence`).
3. Updates `Aggregate` via `aggregate-grace` / `aggregate-violence`.
4. Constructs the new `SimState` with `:None` open-paper + appended
   outcomes.

### Action-dispatch helpers — each builds a complete SimState

```scheme
(:trading::sim::tick-open-new-paper
  (state   :trading::sim::SimState)
  (bank'   :trading::encoding::IndicatorBank)
  (window' :trading::types::Candles)
  (surface :wat::holon::HolonAST)
  (dir     :trading::sim::Direction)
  (close   :f64)
  (count   :i64)
  (gen     :i64)
  (config  :trading::sim::Config)
  -> :trading::sim::SimState)

(:trading::sim::tick-continue-holding
  (state   :trading::sim::SimState)
  (bank'   :trading::encoding::IndicatorBank)
  (window' :trading::types::Candles)
  (paper   :trading::sim::Paper)
  (trail   :trading::sim::TriggerEvents)
  (count   :i64)
  (gen     :i64)
  -> :trading::sim::SimState)

(:trading::sim::tick-handle-no-paper
  (state   :trading::sim::SimState)
  (bank'   :trading::encoding::IndicatorBank)
  (window' :trading::types::Candles)
  (action  :trading::sim::Action)
  (surface :wat::holon::HolonAST)
  (close   :f64)
  (count   :i64)
  (gen     :i64)
  (config  :trading::sim::Config)
  -> :trading::sim::SimState)
```

### Gate helper

```scheme
(:trading::sim::evaluate-grace-eligible?
  (paper          :trading::sim::Paper)
  (trigger-fired? :bool)
  (phase-label    :trading::types::PhaseLabel)
  (residue        :f64)
  (action         :trading::sim::Action)
  (config         :trading::sim::Config)
  -> :bool)
```

Computes `gate-1 AND gate-2 AND gate-3 AND action==:Exit`.

## tick body becomes ~30 lines

```scheme
(:trading::sim::tick state ohlcv config thinker predictor)
  (let* (
    ;; bank, candle, window
    ((bank+candle ...) ...)
    ((bank' candle window') ...)
    ;; surface, action
    ((surface ...) ...)
    ((action  ...) ...)
    ;; phase trigger detection
    ((current-gen ...) ...)
    ((trigger-fired? ...) ...)
    ((current-label ...) ...)
    ((next-count ...) ...)
    ((trigger-event ...) ...)
    ((current-close ...) ...))
    (match (state.open-paper) ->
      :None
        (tick-handle-no-paper state bank' window' action surface
                              current-close next-count current-gen config)
      ((Some paper)
        (let* (
          ((trail-with-trigger ...) ...)
          ((residue ...) ...)
          ((deadline-reached? ...) ...))
          (cond
            (deadline-reached?
              (tick-resolve-violence state bank' window' paper
                                     current-close residue
                                     trail-with-trigger
                                     next-count current-gen))
            ((evaluate-grace-eligible? paper trigger-fired?
                                       current-label residue action config)
              (tick-resolve-grace state bank' window' paper
                                  current-close residue
                                  trail-with-trigger
                                  next-count current-gen))
            (true
              (tick-continue-holding state bank' window' paper
                                     trail-with-trigger
                                     next-count current-gen)))))))
```

## Order of work

1. Write `evaluate-grace-eligible?` (small, pure boolean).
2. Write `tick-open-new-paper` (no resolution; cleanest first).
3. Write `tick-continue-holding` (paper-update only).
4. Write `tick-resolve-violence` (full resolution path).
5. Write `tick-resolve-grace` (full resolution path).
6. Write `tick-handle-no-paper` (orchestrator over Action variants).
7. Rewrite `tick` body using the helpers.
8. Compile + test each step.

## Test ordering

The existing test file should still cover the same invariants. Run
in order:

1. `test-fresh-zero-count` / `test-fresh-no-open-paper` — sanity.
2. `test-hold-no-papers` — exercises `tick-handle-no-paper` Hold path.
3. `test-open-up-creates-paper` — exercises `tick-open-new-paper`.
4. `test-deadline-violence` — exercises `tick-resolve-violence`.
5. `test-violence-aggregate-paper-count` — same.
6. `test-outcome-paper-label-non-empty` — confirms continuous label.
7. `test-predictor-swap-different-aggregates` — Chapter 55 seam.

## Notes

- All helpers are in the same `wat/sim/paper.wat` file (no new
  files; the engine stays as one module).
- Each helper that builds a SimState expects the "before" state and
  the new bank+window — the helpers handle the rest of the field
  inheritance.
- Paren discipline: write one helper at a time; after each, run
  `cargo test --release wat_suite` to confirm parses cleanly.
- This planning doc stays after slice 4 ships — honest record per
  `feedback_proposal_process` (rejected/superseded versions stay).
