;; wat/sim/types.wat — Simulator types (paper lifecycle).
;;
;; Lab arc 025 slice 3 (2026-04-25). Type definitions for the
;; yardstick simulator — papers, gates, decisions, retroactive labels,
;; aggregates, the Thinker / Predictor split (Chapter 55), and config.
;;
;; No logic here. The label-coordinate machinery (Chapters 56–57)
;; lives next door in `wat/sim/labels.wat`. The lifecycle engine
;; (slice 4) lives in `wat/sim/paper.wat`.
;;
;; Plurals via typealias per arc 020's pattern (PhaseRecords / Candles
;; precedent): callers reference `:trading::sim::Papers` instead of
;; `:Vec<trading::sim::Paper>`.
;;
;; Chapter 55 reshape: the Thinker emits a *surface AST*; a separate
;; Predictor turns the surface into an Action. v1 hand-codes the
;; Predictor; the successor arc swaps in a reckoner-backed one. The
;; struct-typed slot makes the swap a one-line change.

;; Standalone-loadable: pull in our type deps so this file freezes
;; cleanly under test sandboxes.
(:wat::load-file! "../types/candle.wat")
(:wat::load-file! "../types/pivot.wat")


;; ─── Direction — Up vs Down ───────────────────────────────────────

(:wat::core::enum :trading::sim::Direction :Up :Down)


;; ─── PositionState — paper lifecycle stage ────────────────────────
;;
;; Active until resolution. Grace carries the realized residue
;; (signed; positive = profitable). Violence is loss-bounded by
;; principal — no residue field needed (residue captured in Outcome
;; instead, with an explicit sign).

(:wat::core::enum :trading::sim::PositionState
  :Active
  (Grace (residue :f64))
  :Violence)


;; ─── Decision — the per-phase trigger evaluation ──────────────────
;;
;; What the gates 1-3 + Predictor said at this trigger. NotEvaluated
;; means we passed through a phase boundary but the gates pre-empted
;; the Predictor (e.g. residue floor not cleared).

(:wat::core::enum :trading::sim::Decision :Hold :Exit :NotEvaluated)


;; ─── TriggerLabel — retroactive trail label (Proposal 055) ───────
;;
;; Set at paper resolution by walking the trail. `:Exit` means "the
;; right move was Exit at this trigger — taken or could-have-been-
;; taken." `:Hold` means "the right move was Hold here." `:Unknown`
;; sits on trails of papers that haven't resolved yet (or that
;; resolved without populating this entry, e.g. trigger fired before
;; the residue floor cleared).

(:wat::core::enum :trading::sim::TriggerLabel :Exit :Hold :Unknown)


;; ─── Action — the Predictor's output ──────────────────────────────
;;
;; Returned by `Predictor.predict surface`. Mixes unit and tagged
;; variants per arc 048's enum design. The simulator interprets:
;;   - `:Hold`  — keep current state (no open / don't close)
;;   - `:Exit`  — close any open paper (gates 1-3 willing)
;;   - `(Open dir)` — open a new paper in the given direction
;;     (only acted on when no paper is open)

(:wat::core::enum :trading::sim::Action
  :Hold
  (Open (direction :trading::sim::Direction))
  :Exit)


;; ─── TriggerEvent — what happened at a phase trigger ──────────────
;;
;; Chapter 55: carries the surface AST so the back-fill at resolution
;; can pair it with the retroactive label and feed
;; `(surface, paper-label)` into the future reckoner-backed Predictor.

(:wat::core::struct :trading::sim::TriggerEvent
  (candle-i    :i64)
  (phase-label :trading::types::PhaseLabel)
  (decision    :trading::sim::Decision)
  (surface     :wat::holon::HolonAST))


;; TriggerEvents — bounded by `deadline` × phase-trigger fraction.
(:wat::core::typealias
  :trading::sim::TriggerEvents
  :Vec<trading::sim::TriggerEvent>)


;; ─── LabeledTrigger — TriggerEvent + retroactive label ────────────

(:wat::core::struct :trading::sim::LabeledTrigger
  (event :trading::sim::TriggerEvent)
  (label :trading::sim::TriggerLabel))


;; LabeledTriggers — bounded by trail length at resolution.
(:wat::core::typealias
  :trading::sim::LabeledTriggers
  :Vec<trading::sim::LabeledTrigger>)


;; ─── Paper — an open or resolved position ─────────────────────────
;;
;; Chapter 55: `entry-surface` is the surface AST that opened the
;; position. The same surface also lives at `trail[0].surface` for
;; convenience during walks; the dedicated field at the Paper level
;; lets resolution code pair `entry-surface` with `paper-label`
;; without indirecting through the trail.

(:wat::core::struct :trading::sim::Paper
  (id              :i64)
  (direction       :trading::sim::Direction)
  (entry-price     :f64)
  (entry-candle    :i64)
  (entry-surface   :wat::holon::HolonAST)
  (deadline-candle :i64)
  (state           :trading::sim::PositionState)
  (trail           :trading::sim::TriggerEvents))


;; ─── Outcome — a resolved paper ──────────────────────────────────
;;
;; Chapter 57: `paper-label` is a continuous coordinate (Thermometer-
;; encoded outcome × direction position; see wat/sim/labels.wat).
;; The 4-corner `(:Grace :Up)` etc. labels are derived references for
;; argmax queries; the *training* labels are these continuous
;; positions captured at the actual resolution magnitudes.

(:wat::core::struct :trading::sim::Outcome
  (paper          :trading::sim::Paper)
  (closed-at      :i64)
  (final-residue  :f64)
  (paper-label    :wat::holon::HolonAST)
  (labeled-trail  :trading::sim::LabeledTriggers))


;; ─── Aggregate — per-run summary statistics ──────────────────────

(:wat::core::struct :trading::sim::Aggregate
  (papers         :i64)
  (grace-count    :i64)
  (violence-count :i64)
  (total-residue  :f64)
  (total-loss     :f64))


;; ─── Config — per-run knobs ──────────────────────────────────────
;;
;; v1 defaults (per DESIGN sub-fog 5c): deadline=288 (1 day),
;; min-residue=0.01 (1% — clears 0.7% round-trip cost), fee-bps=35
;; (0.35% per swap), atr-period=14 (Wilder convention).

(:wat::core::struct :trading::sim::Config
  (deadline    :i64)
  (min-residue :f64)
  (fee-bps     :f64)
  (atr-period  :i64))


;; ─── Thinker — vocabulary (Chapter 55) ───────────────────────────
;;
;; Stateless about outcomes. Given a window of candles + the optional
;; open paper, build a thought-AST with concrete values. The
;; vocabulary the thinker speaks IS the surface it produces.

(:wat::core::struct :trading::sim::Thinker
  (build-surface :fn(trading::types::Candles,Option<trading::sim::Paper>)->wat::holon::HolonAST))


;; ─── Predictor — learner slot (Chapter 55) ───────────────────────
;;
;; Given a surface, return the Action. v1 ships hand-coded predictors
;; (always-Up, always-Hold, cosine-vs-corners). The reckoner-backed
;; successor swaps in via the same struct shape — no simulator
;; rewire.

(:wat::core::struct :trading::sim::Predictor
  (predict :fn(wat::holon::HolonAST)->trading::sim::Action))


;; ─── Plurals (typealiases) ───────────────────────────────────────

(:wat::core::typealias
  :trading::sim::Papers
  :Vec<trading::sim::Paper>)

(:wat::core::typealias
  :trading::sim::Outcomes
  :Vec<trading::sim::Outcome>)
