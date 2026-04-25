;; wat/vocab/exit/trade-atoms.wat — Phase 2.20 (lab arc 023).
;;
;; Port of archived/pre-wat-native/src/vocab/exit/trade_atoms.rs (120L).
;; First lab consumer of arc 049's newtype value semantics — reads
;; `:trading::types::Price` fields via `:Price/0` and computes 13
;; atoms describing a paper trade's state.
;;
;; 5 Log atoms + 8 Thermometer atoms; no Scales threading (every
;; atom uses fixed bounds / fixed scale).
;;
;; Atom families used:
;;   - fraction-of-price Log (0.0001, 0.5): excursion, trail-distance,
;;     stop-distance — same family as arcs 013/015/016/017
;;   - count-full-window Log (1.0, 100.0): age, peak-age, phases-
;;     since-entry, phases-survived — same family as arc 018
;;   - multiple Log (0.0001, 10.0): r-multiple — NEW family this arc;
;;     R-multiple is profitability divided by initial-risk, 10× is
;;     the realistic upper saturation
;;   - Thermometer(value, -1, 1): retracement, signaled, heat,
;;     trail-cushion, entry-vs-phase-avg — fixed-scale atoms;
;;     archive's `Linear { value, scale: 1.0 }`

(:wat::load-file! "../../types/paper-entry.wat")
(:wat::load-file! "../../types/pivot.wat")

(:wat::core::define
  (:trading::vocab::exit::trade-atoms::compute-trade-atoms
    (paper :trading::types::PaperEntry)
    (current-price :f64)
    (phase-history :trading::types::PhaseRecords)
    -> :Vec<wat::holon::HolonAST>)
  (:wat::core::let*
    ;; ─── Extract paper fields ──────────────────────────────────
    (((entry :f64)
      (:trading::types::Price/0
        (:trading::types::PaperEntry/entry-price paper)))
     ((extreme :f64) (:trading::types::PaperEntry/extreme paper))
     ((trail-level :f64)
      (:trading::types::Price/0
        (:trading::types::PaperEntry/trail-level paper)))
     ((entry-candle :i64) (:trading::types::PaperEntry/entry-candle paper))
     ((age-i64 :i64) (:trading::types::PaperEntry/age paper))
     ((age :f64) (:wat::core::i64::to-f64 age-i64))
     ((signaled-bool :bool) (:trading::types::PaperEntry/signaled paper))
     ((distances :trading::types::Distances)
      (:trading::types::PaperEntry/distances paper))
     ((trail-distance :f64) (:trading::types::Distances/trail distances))
     ((stop-distance :f64) (:trading::types::Distances/stop distances))
     ((price-history :Vec<f64>)
      (:trading::types::PaperEntry/price-history paper))

     ;; ─── Computed values per archive ──────────────────────────
     ((excursion :f64)
      (:wat::core::f64::abs
        (:wat::core::/
          (:wat::core::- extreme entry) entry)))

     ;; retracement: if excursion > 0.0001, |((extreme - cur) /
     ;; (extreme - entry)).min(1.0)|; else 0.0.
     ((retracement :f64)
      (:wat::core::if (:wat::core::> excursion 0.0001) -> :f64
        (:wat::core::f64::min
          (:wat::core::f64::abs
            (:wat::core::/
              (:wat::core::- extreme current-price)
              (:wat::core::- extreme entry)))
          1.0)
        0.0))

     ;; peak-age: scan price-history backward for the last index
     ;; where p == extreme; peak_age = (length - 1 - i); else 0.
     ((peak-idx-opt :Option<i64>)
      (:wat::core::find-last-index price-history
        (:wat::core::lambda ((p :f64) -> :bool)
          (:wat::core::<
            (:wat::core::f64::abs (:wat::core::- p extreme))
            0.0000000001))))
     ((peak-age :f64)
      (:wat::core::match peak-idx-opt -> :f64
        ((Some i)
         (:wat::core::i64::to-f64
           (:wat::core::-
             (:wat::core::- (:wat::core::length price-history) 1)
             i)))
        (:None 0.0)))

     ((signaled :f64)
      (:wat::core::if signaled-bool -> :f64 1.0 0.0))

     ((initial-risk :f64) stop-distance)
     ((r-multiple :f64)
      (:wat::core::if (:wat::core::> initial-risk 0.0001) -> :f64
        (:wat::core::/ excursion initial-risk)
        0.0))

     ;; remaining-profit = (excursion - retracement * excursion).max(0)
     ((remaining-profit :f64)
      (:wat::core::f64::max
        (:wat::core::-
          excursion
          (:wat::core::* retracement excursion))
        0.0))

     ((heat :f64)
      (:wat::core::if (:wat::core::> remaining-profit 0.0001) -> :f64
        (:wat::core::/ trail-distance remaining-profit)
        1.0))

     ;; trail-cushion: if excursion > 0.0001,
     ;; |(cur - trail) / (extreme - entry)|.min(1.0); else 0.
     ((trail-cushion :f64)
      (:wat::core::if (:wat::core::> excursion 0.0001) -> :f64
        (:wat::core::f64::min
          (:wat::core::/
            (:wat::core::f64::abs
              (:wat::core::- current-price trail-level))
            (:wat::core::f64::abs
              (:wat::core::- extreme entry)))
          1.0)
        0.0))

     ;; phases-since-entry: count of phase records with start_candle
     ;; >= entry_candle, then max with 1.0.
     ((phases-from-entry :trading::types::PhaseRecords)
      (:wat::core::filter phase-history
        (:wat::core::lambda ((r :trading::types::PhaseRecord) -> :bool)
          (:wat::core::>=
            (:trading::types::PhaseRecord/start-candle r) entry-candle))))
     ((phases-since-entry :f64)
      (:wat::core::f64::max
        (:wat::core::i64::to-f64
          (:wat::core::length phases-from-entry))
        1.0))

     ;; phases-survived: count of those that are also Peak.
     ((phases-peak :trading::types::PhaseRecords)
      (:wat::core::filter phases-from-entry
        (:wat::core::lambda ((r :trading::types::PhaseRecord) -> :bool)
          (:wat::core::match (:trading::types::PhaseRecord/label r) -> :bool
            (:trading::types::PhaseLabel::Peak true)
            (:trading::types::PhaseLabel::Valley false)
            (:trading::types::PhaseLabel::Transition false)))))
     ((phases-survived :f64)
      (:wat::core::f64::max
        (:wat::core::i64::to-f64
          (:wat::core::length phases-peak))
        1.0))

     ;; entry-vs-phase-avg: 0 if phase_history empty or entry==0,
     ;; else (entry - mean(close_avg)) / entry.
     ((entry-vs-phase-avg :f64)
      (:wat::core::if
        (:wat::core::or
          (:wat::core::empty? phase-history)
          (:wat::core::= entry 0.0)) -> :f64
        0.0
        (:wat::core::let*
          (((closes :Vec<f64>)
            (:wat::core::map phase-history
              (:wat::core::lambda ((r :trading::types::PhaseRecord) -> :f64)
                (:trading::types::PhaseRecord/close-avg r))))
           ((sum :f64)
            (:wat::core::foldl closes 0.0
              (:wat::core::lambda ((acc :f64) (x :f64) -> :f64)
                (:wat::core::+ acc x))))
           ((avg :f64)
            (:wat::core::/
              sum
              (:wat::core::i64::to-f64
                (:wat::core::length phase-history)))))
          (:wat::core::/
            (:wat::core::- entry avg) entry))))

     ;; ─── Encode the 13 atoms (archive order) ──────────────────

     ;; 0: exit-excursion — Log fraction-of-price.
     ((excursion-floored :f64) (:wat::core::f64::max excursion 0.0001))
     ((h0 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "exit-excursion")
        (:wat::holon::Log excursion-floored 0.0001 0.5)))

     ;; 1: exit-retracement — Thermometer.
     ((h1 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "exit-retracement")
        (:wat::holon::Thermometer retracement -1.0 1.0)))

     ;; 2: exit-age — Log count-full-window.
     ((age-floored :f64) (:wat::core::f64::max age 1.0))
     ((h2 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "exit-age")
        (:wat::holon::Log age-floored 1.0 100.0)))

     ;; 3: exit-peak-age — Log count-full-window.
     ((peak-age-floored :f64) (:wat::core::f64::max peak-age 1.0))
     ((h3 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "exit-peak-age")
        (:wat::holon::Log peak-age-floored 1.0 100.0)))

     ;; 4: exit-signaled — Thermometer (0 or 1).
     ((h4 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "exit-signaled")
        (:wat::holon::Thermometer signaled -1.0 1.0)))

     ;; 5: exit-trail-distance — Log fraction-of-price.
     ((trail-distance-floored :f64)
      (:wat::core::f64::max trail-distance 0.0001))
     ((h5 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "exit-trail-distance")
        (:wat::holon::Log trail-distance-floored 0.0001 0.5)))

     ;; 6: exit-stop-distance — Log fraction-of-price.
     ((stop-distance-floored :f64)
      (:wat::core::f64::max stop-distance 0.0001))
     ((h6 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "exit-stop-distance")
        (:wat::holon::Log stop-distance-floored 0.0001 0.5)))

     ;; 7: exit-r-multiple — Log multiple family (0.0001, 10).
     ((r-multiple-floored :f64) (:wat::core::f64::max r-multiple 0.0001))
     ((h7 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "exit-r-multiple")
        (:wat::holon::Log r-multiple-floored 0.0001 10.0)))

     ;; 8: exit-heat — Thermometer (clamped to ≤ 1).
     ((heat-clamped :f64) (:wat::core::f64::min heat 1.0))
     ((h8 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "exit-heat")
        (:wat::holon::Thermometer heat-clamped -1.0 1.0)))

     ;; 9: exit-trail-cushion — Thermometer.
     ((h9 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "exit-trail-cushion")
        (:wat::holon::Thermometer trail-cushion -1.0 1.0)))

     ;; 10: phases-since-entry — Log count.
     ((h10 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "phases-since-entry")
        (:wat::holon::Log phases-since-entry 1.0 100.0)))

     ;; 11: phases-survived — Log count.
     ((h11 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "phases-survived")
        (:wat::holon::Log phases-survived 1.0 100.0)))

     ;; 12: entry-vs-phase-avg — Thermometer.
     ((h12 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "entry-vs-phase-avg")
        (:wat::holon::Thermometer entry-vs-phase-avg -1.0 1.0))))

    (:wat::core::vec :wat::holon::HolonAST
      h0 h1 h2 h3 h4 h5 h6 h7 h8 h9 h10 h11 h12)))

;; ─── Lens selector ─────────────────────────────────────────────

(:wat::core::define
  (:trading::vocab::exit::trade-atoms::select-trade-atoms
    (lens :trading::types::RegimeLens)
    (atoms :Vec<wat::holon::HolonAST>)
    -> :Vec<wat::holon::HolonAST>)
  (:wat::core::match lens -> :Vec<wat::holon::HolonAST>
    (:trading::types::RegimeLens::Core (:wat::core::take atoms 5))
    (:trading::types::RegimeLens::Full atoms)))
