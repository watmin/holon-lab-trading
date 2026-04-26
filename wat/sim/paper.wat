;; wat/sim/paper.wat — Paper Lifecycle Simulator engine.
;;
;; Lab arc 025 slice 4 (2026-04-25; resumed after arc 026 closed).
;; The yardstick. Drives the four-gate Grace/Violence lifecycle from
;; Proposal 055 over a candle stream, using a Thinker (vocabulary)
;; and a Predictor (learner slot) per the Chapter 55 split.
;;
;; Architecture (Chapter 55):
;;   - Thinker emits a surface AST per candle from the (window, open-paper)
;;   - Predictor takes the surface and returns an Action
;;   - Engine owns lifecycle, gates 1-3, deadline, retroactive labeling,
;;     and continuous label assembly at resolution (Chapter 57)
;;
;; Per-candle waterfall:
;;   1. Pull (ts, o, h, l, c, v) from stream. None → terminate.
;;   2. Run IndicatorBank::tick → enriched candle. Append to window;
;;      trim to max-window-size.
;;   3. Build surface = (thinker.build-surface window open-paper).
;;   4. Get action = (predictor.predict surface).
;;   5. Detect phase trigger (PhaseState.generation changed this tick).
;;   6. If trigger fired AND open-paper: append TriggerEvent to trail.
;;   7. If open-paper:
;;      - If candle-i >= deadline → close Violence; back-fill trail.
;;      - Else if trigger AND market-direction-against AND residue >= min
;;             AND action == :Exit → close Grace; back-fill trail.
;;   8. If no open-paper AND action is `(Open dir)` → open new paper.
;;
;; Window is hardcoded to 256 candles (lab convention from BOOK
;; Chapter 36; comfortably wider than atr-period × 14, narrow enough
;; that the buffer fits in memory). Add to Config when a thinker
;; needs it different.
;;
;; SimState is engine-internal — not exported. The public API is:
;;   :trading::sim::run         stream thinker predictor config -> Aggregate
;;   :trading::sim::run-bounded stream thinker predictor config max -> Aggregate

(:wat::load-file! "types.wat")
(:wat::load-file! "labels.wat")
(:wat::load-file! "../io/CandleStream.wat")
(:wat::load-file! "../encoding/indicator-bank/bank.wat")


;; Window cap (per header note).
(:wat::core::define
  (:trading::sim::WINDOW-CAP -> :i64)
  256)


;; ─── SimState — engine-internal accumulator ──────────────────────

(:wat::core::struct :trading::sim::SimState
  (bank           :trading::encoding::IndicatorBank)
  (window         :trading::types::Candles)
  (open-paper     :Option<trading::sim::Paper>)
  (outcomes       :trading::sim::Outcomes)
  (paper-id       :i64)
  (aggregate      :trading::sim::Aggregate)
  (prev-phase-gen :i64)
  (count          :i64))


(:wat::core::define
  (:trading::sim::SimState::fresh -> :trading::sim::SimState)
  (:trading::sim::SimState/new
    (:trading::encoding::IndicatorBank::fresh)
    (:wat::core::vec :trading::types::Candle)
    :None
    (:wat::core::vec :trading::sim::Outcome)
    0
    (:trading::sim::Aggregate/new 0 0 0 0.0 0.0)
    0
    0))


;; ─── Helpers ─────────────────────────────────────────────────────

;; residue — net P&L as fraction of principal, after round-trip fees.
;; For Up: (current - entry) / entry - 2·fee; for Down: invert.
(:wat::core::define
  (:trading::sim::residue
    (entry-price :f64)
    (current-price :f64)
    (direction :trading::sim::Direction)
    (fee-bps :f64)
    -> :f64)
  (:wat::core::let*
    (((round-trip-fee :f64)
      (:wat::core::* 2.0 (:wat::core::/ fee-bps 10000.0)))
     ((raw-move :f64)
      (:wat::core::if (:wat::core::= entry-price 0.0) -> :f64
        0.0
        (:wat::core::/ (:wat::core::- current-price entry-price) entry-price)))
     ((directed :f64)
      (:wat::core::match direction -> :f64
        (:trading::sim::Direction::Up raw-move)
        (:trading::sim::Direction::Down (:wat::core::- 0.0 raw-move)))))
    (:wat::core::- directed round-trip-fee)))


;; price-move — signed direction-weighted move (positive = profitable
;; for the given direction). Used at resolution to feed direction-axis.
(:wat::core::define
  (:trading::sim::price-move
    (entry-price :f64)
    (current-price :f64)
    (direction :trading::sim::Direction)
    -> :f64)
  (:wat::core::let*
    (((raw-move :f64)
      (:wat::core::if (:wat::core::= entry-price 0.0) -> :f64
        0.0
        (:wat::core::/ (:wat::core::- current-price entry-price) entry-price))))
    (:wat::core::match direction -> :f64
      (:trading::sim::Direction::Up raw-move)
      (:trading::sim::Direction::Down (:wat::core::- 0.0 raw-move)))))


;; market-direction-against? — a paper's "against" direction is Down
;; for an Up paper (price reversal at Peak), Up for a Down paper
;; (reversal at Valley). Detected by the just-fired phase label.
(:wat::core::define
  (:trading::sim::direction-against?
    (paper-direction :trading::sim::Direction)
    (phase-label :trading::types::PhaseLabel)
    -> :bool)
  (:wat::core::match paper-direction -> :bool
    (:trading::sim::Direction::Up
      (:wat::core::match phase-label -> :bool
        (:trading::types::PhaseLabel::Peak true)
        (_ false)))
    (:trading::sim::Direction::Down
      (:wat::core::match phase-label -> :bool
        (:trading::types::PhaseLabel::Valley true)
        (_ false)))))


;; Trail back-fill (Grace) — trigger at index `t-idx` is the closing
;; trigger (labeled :Exit); all earlier triggers labeled :Hold.
(:wat::core::define
  (:trading::sim::label-trail-grace
    (trail :trading::sim::TriggerEvents)
    (close-trigger-idx :i64)
    -> :trading::sim::LabeledTriggers)
  (:wat::core::map
    (:wat::core::range 0 (:wat::core::length trail))
    (:wat::core::lambda ((i :i64) -> :trading::sim::LabeledTrigger)
      (:wat::core::let*
        (((event :trading::sim::TriggerEvent)
          (:wat::core::match (:wat::core::get trail i) -> :trading::sim::TriggerEvent
            ((Some e) e)
            (:None
              ;; Unreachable — i is in range by construction.
              (:trading::sim::TriggerEvent/new
                0 :trading::types::PhaseLabel::Valley
                :trading::sim::Decision::NotEvaluated
                (:wat::holon::Atom (:wat::core::quote :unreachable))))))
         ((label :trading::sim::TriggerLabel)
          (:wat::core::if (:wat::core::= i close-trigger-idx)
                          -> :trading::sim::TriggerLabel
            :trading::sim::TriggerLabel::Exit
            :trading::sim::TriggerLabel::Hold)))
        (:trading::sim::LabeledTrigger/new event label)))))


;; Trail back-fill (Violence) — every passed trigger labeled :Exit
;; ("should-have-Exit'd"). Deadline-resolved papers used the wrong
;; calls all the way through.
(:wat::core::define
  (:trading::sim::label-trail-violence
    (trail :trading::sim::TriggerEvents)
    -> :trading::sim::LabeledTriggers)
  (:wat::core::map trail
    (:wat::core::lambda ((event :trading::sim::TriggerEvent)
                         -> :trading::sim::LabeledTrigger)
      (:trading::sim::LabeledTrigger/new
        event :trading::sim::TriggerLabel::Exit))))


;; Aggregate update on Grace.
(:wat::core::define
  (:trading::sim::aggregate-grace
    (agg :trading::sim::Aggregate)
    (residue :f64)
    -> :trading::sim::Aggregate)
  (:trading::sim::Aggregate/new
    (:wat::core::+ (:trading::sim::Aggregate/papers agg) 1)
    (:wat::core::+ (:trading::sim::Aggregate/grace-count agg) 1)
    (:trading::sim::Aggregate/violence-count agg)
    (:wat::core::+ (:trading::sim::Aggregate/total-residue agg) residue)
    (:trading::sim::Aggregate/total-loss agg)))


;; Aggregate update on Violence.
(:wat::core::define
  (:trading::sim::aggregate-violence
    (agg :trading::sim::Aggregate)
    (residue :f64)
    -> :trading::sim::Aggregate)
  (:trading::sim::Aggregate/new
    (:wat::core::+ (:trading::sim::Aggregate/papers agg) 1)
    (:trading::sim::Aggregate/grace-count agg)
    (:wat::core::+ (:trading::sim::Aggregate/violence-count agg) 1)
    (:trading::sim::Aggregate/total-residue agg)
    ;; total-loss accumulates negative residues' absolute value.
    (:wat::core::+
      (:trading::sim::Aggregate/total-loss agg)
      (:wat::core::f64::abs residue))))


;; ─── effective-action — Q10 simulator-side translation ──────────
;;
;; The Predictor is stateless w.r.t. open-paper (slice-4-5-design-
;; questions.md Q10): it argmaxes corners and emits one of
;; `:Hold | (Open :Up) | (Open :Down)`. The simulator owns the
;; position-aware translation:
;;
;;   no paper open    + raw-action       → raw-action  (identity)
;;   paper-d open     + (Open d)         → :Hold       (already going there)
;;   paper-d open     + (Open !d)        → :Exit       (trend turned)
;;   paper open       + :Hold            → :Hold       (keep)
;;   paper open       + :Exit            → :Exit       (defensive; v1 doesn't emit)
;;
;; The translation runs once per tick; the gate evaluator and the
;; tick-handle-no-paper dispatcher both consume the result.
(:wat::core::define
  (:trading::sim::direction-equal?
    (a :trading::sim::Direction)
    (b :trading::sim::Direction)
    -> :bool)
  (:wat::core::match a -> :bool
    (:trading::sim::Direction::Up
      (:wat::core::match b -> :bool
        (:trading::sim::Direction::Up true)
        (:trading::sim::Direction::Down false)))
    (:trading::sim::Direction::Down
      (:wat::core::match b -> :bool
        (:trading::sim::Direction::Up false)
        (:trading::sim::Direction::Down true)))))

(:wat::core::define
  (:trading::sim::effective-action
    (raw :trading::sim::Action)
    (open-paper :Option<trading::sim::Paper>)
    -> :trading::sim::Action)
  (:wat::core::match open-paper -> :trading::sim::Action
    (:None raw)
    ((Some paper)
      (:wat::core::match raw -> :trading::sim::Action
        (:trading::sim::Action::Hold :trading::sim::Action::Hold)
        (:trading::sim::Action::Exit :trading::sim::Action::Exit)
        ((:trading::sim::Action::Open dir)
          (:wat::core::if
            (:trading::sim::direction-equal?
              dir (:trading::sim::Paper/direction paper))
            -> :trading::sim::Action
            :trading::sim::Action::Hold
            :trading::sim::Action::Exit))))))


;; ─── Gate-evaluation helper ──────────────────────────────────────
;;
;; Grace is reachable when:
;;   gate-1: phase trigger fired this tick
;;   gate-2: phase label is "against" the paper's direction
;;   gate-3: residue clears the min-residue floor
;;   gate-4: effective-action is :Exit (translated from raw predictor
;;           output by `effective-action`; in v1 the Predictor never
;;           emits :Exit directly — it emits (Open !d) and the
;;           simulator translates).
;; All four → grace-eligible? = true.
(:wat::core::define
  (:trading::sim::evaluate-grace-eligible?
    (paper :trading::sim::Paper)
    (trigger-fired? :bool)
    (phase-label :trading::types::PhaseLabel)
    (residue :f64)
    (action :trading::sim::Action)
    (config :trading::sim::Config)
    -> :bool)
  (:wat::core::let*
    (((g2 :bool)
      (:trading::sim::direction-against?
        (:trading::sim::Paper/direction paper) phase-label))
     ((g3 :bool)
      (:wat::core::>= residue
        (:trading::sim::Config/min-residue config)))
     ((g4 :bool)
      (:wat::core::match action -> :bool
        (:trading::sim::Action::Exit true)
        (_ false))))
    (:wat::core::and trigger-fired?
      (:wat::core::and g2
        (:wat::core::and g3 g4)))))


;; ─── Resolution helpers — each returns a complete new SimState ──

;; Violence: deadline-resolved paper. Trail back-filled with
;; should-have-Exit'd labels at every passed trigger.
(:wat::core::define
  (:trading::sim::tick-resolve-violence
    (state :trading::sim::SimState)
    (bank' :trading::encoding::IndicatorBank)
    (window' :trading::types::Candles)
    (paper :trading::sim::Paper)
    (current-close :f64)
    (residue :f64)
    (trail :trading::sim::TriggerEvents)
    (count :i64)
    (gen :i64)
    -> :trading::sim::SimState)
  (:wat::core::let*
    (((dir :trading::sim::Direction) (:trading::sim::Paper/direction paper))
     ((entry-price :f64) (:trading::sim::Paper/entry-price paper))
     ((pmove :f64)
      (:trading::sim::price-move entry-price current-close dir))
     ((label :wat::holon::HolonAST)
      (:trading::sim::paper-label residue pmove))
     ((labeled :trading::sim::LabeledTriggers)
      (:trading::sim::label-trail-violence trail))
     ((closed :trading::sim::Paper)
      (:trading::sim::Paper/new
        (:trading::sim::Paper/id paper)
        dir entry-price
        (:trading::sim::Paper/entry-candle paper)
        (:trading::sim::Paper/entry-surface paper)
        (:trading::sim::Paper/deadline-candle paper)
        :trading::sim::PositionState::Violence
        trail))
     ((outcome :trading::sim::Outcome)
      (:trading::sim::Outcome/new closed count residue label labeled))
     ((agg' :trading::sim::Aggregate)
      (:trading::sim::aggregate-violence
        (:trading::sim::SimState/aggregate state) residue)))
    (:trading::sim::SimState/new
      bank' window' :None
      (:wat::core::conj (:trading::sim::SimState/outcomes state) outcome)
      (:trading::sim::SimState/paper-id state)
      agg' gen count)))


;; Grace: gates 1-3 + Action::Exit. Trail back-filled with the
;; closing trigger at the last index labeled :Exit, all earlier
;; passed triggers labeled :Hold.
(:wat::core::define
  (:trading::sim::tick-resolve-grace
    (state :trading::sim::SimState)
    (bank' :trading::encoding::IndicatorBank)
    (window' :trading::types::Candles)
    (paper :trading::sim::Paper)
    (current-close :f64)
    (residue :f64)
    (trail :trading::sim::TriggerEvents)
    (count :i64)
    (gen :i64)
    -> :trading::sim::SimState)
  (:wat::core::let*
    (((dir :trading::sim::Direction) (:trading::sim::Paper/direction paper))
     ((entry-price :f64) (:trading::sim::Paper/entry-price paper))
     ((pmove :f64)
      (:trading::sim::price-move entry-price current-close dir))
     ((label :wat::holon::HolonAST)
      (:trading::sim::paper-label residue pmove))
     ((close-idx :i64)
      (:wat::core::- (:wat::core::length trail) 1))
     ((labeled :trading::sim::LabeledTriggers)
      (:trading::sim::label-trail-grace trail close-idx))
     ((closed :trading::sim::Paper)
      (:trading::sim::Paper/new
        (:trading::sim::Paper/id paper)
        dir entry-price
        (:trading::sim::Paper/entry-candle paper)
        (:trading::sim::Paper/entry-surface paper)
        (:trading::sim::Paper/deadline-candle paper)
        (:trading::sim::PositionState::Grace residue)
        trail))
     ((outcome :trading::sim::Outcome)
      (:trading::sim::Outcome/new closed count residue label labeled))
     ((agg' :trading::sim::Aggregate)
      (:trading::sim::aggregate-grace
        (:trading::sim::SimState/aggregate state) residue)))
    (:trading::sim::SimState/new
      bank' window' :None
      (:wat::core::conj (:trading::sim::SimState/outcomes state) outcome)
      (:trading::sim::SimState/paper-id state)
      agg' gen count)))


;; Open a new paper at this candle's close.
(:wat::core::define
  (:trading::sim::tick-open-new-paper
    (state :trading::sim::SimState)
    (bank' :trading::encoding::IndicatorBank)
    (window' :trading::types::Candles)
    (surface :wat::holon::HolonAST)
    (dir :trading::sim::Direction)
    (current-close :f64)
    (count :i64)
    (gen :i64)
    (config :trading::sim::Config)
    -> :trading::sim::SimState)
  (:wat::core::let*
    (((new-id :i64)
      (:wat::core::+ (:trading::sim::SimState/paper-id state) 1))
     ((deadline :i64)
      (:wat::core::+ count (:trading::sim::Config/deadline config)))
     ((paper :trading::sim::Paper)
      (:trading::sim::Paper/new
        new-id dir current-close count surface deadline
        :trading::sim::PositionState::Active
        (:wat::core::vec :trading::sim::TriggerEvent))))
    (:trading::sim::SimState/new
      bank' window' (Some paper)
      (:trading::sim::SimState/outcomes state)
      new-id
      (:trading::sim::SimState/aggregate state)
      gen count)))


;; Continue holding — paper still active; only trail extends.
(:wat::core::define
  (:trading::sim::tick-continue-holding
    (state :trading::sim::SimState)
    (bank' :trading::encoding::IndicatorBank)
    (window' :trading::types::Candles)
    (paper :trading::sim::Paper)
    (trail :trading::sim::TriggerEvents)
    (count :i64)
    (gen :i64)
    -> :trading::sim::SimState)
  (:wat::core::let*
    (((paper' :trading::sim::Paper)
      (:trading::sim::Paper/new
        (:trading::sim::Paper/id paper)
        (:trading::sim::Paper/direction paper)
        (:trading::sim::Paper/entry-price paper)
        (:trading::sim::Paper/entry-candle paper)
        (:trading::sim::Paper/entry-surface paper)
        (:trading::sim::Paper/deadline-candle paper)
        :trading::sim::PositionState::Active
        trail)))
    (:trading::sim::SimState/new
      bank' window' (Some paper')
      (:trading::sim::SimState/outcomes state)
      (:trading::sim::SimState/paper-id state)
      (:trading::sim::SimState/aggregate state)
      gen count)))


;; No-paper dispatch. Action::Hold and ::Exit both no-op (advance
;; bookkeeping fields only); ::Open opens a new paper.
(:wat::core::define
  (:trading::sim::tick-handle-no-paper
    (state :trading::sim::SimState)
    (bank' :trading::encoding::IndicatorBank)
    (window' :trading::types::Candles)
    (action :trading::sim::Action)
    (surface :wat::holon::HolonAST)
    (current-close :f64)
    (count :i64)
    (gen :i64)
    (config :trading::sim::Config)
    -> :trading::sim::SimState)
  (:wat::core::match action -> :trading::sim::SimState
    (:trading::sim::Action::Hold
      (:trading::sim::SimState/new
        bank' window' :None
        (:trading::sim::SimState/outcomes state)
        (:trading::sim::SimState/paper-id state)
        (:trading::sim::SimState/aggregate state)
        gen count))
    (:trading::sim::Action::Exit
      (:trading::sim::SimState/new
        bank' window' :None
        (:trading::sim::SimState/outcomes state)
        (:trading::sim::SimState/paper-id state)
        (:trading::sim::SimState/aggregate state)
        gen count))
    ((:trading::sim::Action::Open dir)
      (:trading::sim::tick-open-new-paper
        state bank' window' surface dir current-close count gen config))))


;; ─── Tick — orchestrate the helpers ──────────────────────────────

(:wat::core::define
  (:trading::sim::tick
    (state :trading::sim::SimState)
    (ohlcv :trading::types::Ohlcv)
    (config :trading::sim::Config)
    (thinker :trading::sim::Thinker)
    (predictor :trading::sim::Predictor)
    -> :trading::sim::SimState)
  (:wat::core::let*
    (((bank-tick-result
       :(trading::encoding::IndicatorBank,trading::types::Candle))
      (:trading::encoding::IndicatorBank::tick
        (:trading::sim::SimState/bank state) ohlcv))
     ((bank' :trading::encoding::IndicatorBank)
      (:wat::core::first bank-tick-result))
     ((candle :trading::types::Candle) (:wat::core::second bank-tick-result))

     ;; Append to window; trim to cap.
     ((appended :trading::types::Candles)
      (:wat::core::conj
        (:trading::sim::SimState/window state) candle))
     ((window-len :i64) (:wat::core::length appended))
     ((window' :trading::types::Candles)
      (:wat::core::if (:wat::core::> window-len (:trading::sim::WINDOW-CAP))
                      -> :trading::types::Candles
        (:wat::core::drop appended
          (:wat::core::- window-len (:trading::sim::WINDOW-CAP)))
        appended))

     ;; Build surface + ask Predictor.
     ((open-paper :Option<trading::sim::Paper>)
      (:trading::sim::SimState/open-paper state))
     ((surface :wat::holon::HolonAST)
      ((:trading::sim::Thinker/build-surface thinker)
       window' open-paper))
     ((raw-action :trading::sim::Action)
      ((:trading::sim::Predictor/predict predictor) surface))
     ;; Q10 translation — see `effective-action` above.
     ((action :trading::sim::Action)
      (:trading::sim::effective-action raw-action open-paper))

     ;; Phase trigger detection — generation incremented this tick.
     ((phase-state :trading::encoding::PhaseState)
      (:trading::encoding::IndicatorBank/phase-state bank'))
     ((current-gen :i64)
      (:trading::encoding::PhaseState/generation phase-state))
     ((trigger-fired? :bool)
      (:wat::core::not= current-gen
        (:trading::sim::SimState/prev-phase-gen state)))
     ((current-label :trading::types::PhaseLabel)
      (:trading::encoding::PhaseState/current-label phase-state))

     ;; Build TriggerEvent if trigger fired (used regardless of
     ;; whether a paper is open; only appended to open paper's trail).
     ((next-count :i64)
      (:wat::core::+ (:trading::sim::SimState/count state) 1))
     ((trigger-event :trading::sim::TriggerEvent)
      (:trading::sim::TriggerEvent/new
        next-count current-label
        :trading::sim::Decision::NotEvaluated
        surface))

     ;; Current close from candle's ohlcv.
     ((current-close :f64)
      (:trading::types::Ohlcv/close
        (:trading::types::Candle/ohlcv candle)))

     ;; Dispatch: no paper vs open paper.
     ((result-state :trading::sim::SimState)
      (:wat::core::match open-paper -> :trading::sim::SimState
        (:None
          (:trading::sim::tick-handle-no-paper
            state bank' window' action surface
            current-close next-count current-gen config))
        ((Some paper)
          (:wat::core::let*
            (((trail-with-trigger :trading::sim::TriggerEvents)
              (:wat::core::if trigger-fired?
                              -> :trading::sim::TriggerEvents
                (:wat::core::conj
                  (:trading::sim::Paper/trail paper) trigger-event)
                (:trading::sim::Paper/trail paper)))
             ((deadline-reached? :bool)
              (:wat::core::>= next-count
                (:trading::sim::Paper/deadline-candle paper)))
             ((current-residue :f64)
              (:trading::sim::residue
                (:trading::sim::Paper/entry-price paper)
                current-close
                (:trading::sim::Paper/direction paper)
                (:trading::sim::Config/fee-bps config)))
             ((grace? :bool)
              (:trading::sim::evaluate-grace-eligible?
                paper trigger-fired? current-label
                current-residue action config)))
            (:wat::core::if deadline-reached?
                            -> :trading::sim::SimState
              (:trading::sim::tick-resolve-violence
                state bank' window' paper current-close
                current-residue trail-with-trigger
                next-count current-gen)
              (:wat::core::if grace?
                              -> :trading::sim::SimState
                (:trading::sim::tick-resolve-grace
                  state bank' window' paper current-close
                  current-residue trail-with-trigger
                  next-count current-gen)
                (:trading::sim::tick-continue-holding
                  state bank' window' paper trail-with-trigger
                  next-count current-gen))))))))
    result-state))


;; ─── Loop — tail-recursive over the stream ───────────────────────
;;
;; No internal max-candles. The stream's `next!` returning :None is
;; the only termination signal. Callers bound runs by passing a
;; bounded stream constructed via `:trading::candles::open-bounded path n`.

(:wat::core::define
  (:trading::sim::run-loop
    (state :trading::sim::SimState)
    (stream :trading::candles::Stream)
    (config :trading::sim::Config)
    (thinker :trading::sim::Thinker)
    (predictor :trading::sim::Predictor)
    -> :trading::sim::SimState)
  (:wat::core::match (:trading::candles::next! stream)
                     -> :trading::sim::SimState
    (:None state)
    ((Some (ts open high low close volume))
      (:wat::core::let*
        (((ohlcv :trading::types::Ohlcv)
          (:trading::types::Ohlcv/new
            (:trading::types::Asset/new "BTC")
            (:trading::types::Asset/new "USDC")
            (:wat::core::i64::to-string ts)
            open high low close volume))
         ((state' :trading::sim::SimState)
          (:trading::sim::tick state ohlcv config thinker predictor)))
        (:trading::sim::run-loop
          state' stream config thinker predictor)))))


;; ─── Public API — single `run` ───────────────────────────────────
;;
;; Bound at construction: callers pass `:trading::candles::open-bounded
;; "path" 1000` for a cap-1000 run, or plain `:trading::candles::open
;; "path"` for full-stream.

(:wat::core::define
  (:trading::sim::run
    (stream :trading::candles::Stream)
    (thinker :trading::sim::Thinker)
    (predictor :trading::sim::Predictor)
    (config :trading::sim::Config)
    -> :trading::sim::Aggregate)
  (:wat::core::let*
    (((final-state :trading::sim::SimState)
      (:trading::sim::run-loop
        (:trading::sim::SimState::fresh)
        stream config thinker predictor)))
    (:trading::sim::SimState/aggregate final-state)))
