;; wat/sim/v1.wat — v1 hand-coded Thinkers + Predictor (Chapter 55).
;;
;; Lab arc 025 slice 5 (2026-04-25). Three structs:
;;
;;   :trading::sim::always-up-thinker        ; Q12 — smoke baseline
;;   :trading::sim::sma-cross-thinker        ; Q12 — first thinker that thinks
;;   :trading::sim::cosine-vs-corners-predictor  ; Q10 — argmax over corners
;;
;; Per slice-4-5-design-questions.md:
;;   Q11: thinkers emit surfaces in the same `outcome-axis × direction-axis`
;;        basis the labels use. The `paper-label` helper from slice 3 is
;;        the surface builder — its inputs are (outcome-lean, direction-lean)
;;        scalars in `[-0.05, +0.05]`.
;;   Q14: thinkers ignore `Option<Paper>` in v1; the param stays in the
;;        signature for the contract.
;;   Q10: Predictor argmaxes cosine against the four corners; emits one of
;;        `(Open :Up) | (Open :Down) | :Hold` (never `:Exit` directly —
;;        the simulator translates `(Open !d)` while holding `paper-d` to
;;        `:Exit` upstream).

(:wat::load-file! "types.wat")
(:wat::load-file! "labels.wat")
(:wat::load-file! "../types/candle.wat")


;; ─── always-up-thinker — Q12 smoke baseline ───────────────────────
;;
;; Constant surface biased toward `corner-grace-up` at `(+0.04, +0.04)`.
;; Predictor argmaxes to `(Open :Up)` on every tick. Used by slice 5's
;; integration smoke — exercises the simulator end-to-end without
;; needing indicator warmup.
(:wat::core::define
  (:trading::sim::always-up-thinker -> :trading::sim::Thinker)
  (:trading::sim::Thinker/new
    (:wat::core::lambda
      ((window :trading::types::Candles)
       (pos :Option<trading::sim::Paper>)
       -> :wat::holon::HolonAST)
      (:trading::sim::paper-label 0.04 0.04))))


;; ─── sma-cross-thinker — Q12 first thinker that thinks ────────────
;;
;; Reads `sma20` and `sma50` from the latest Candle (populated by
;; arc 026's IndicatorBank). 0.1% deadband — Q12 names this as
;; defensible-but-arbitrary; tunable in a successor arc that measures
;; which threshold maximizes Grace residue.
;;
;;   sma20 > sma50 * 1.001  →  outcome=+0.03, direction=+0.04 (lean grace-up)
;;   sma20 < sma50 * 0.999  →  outcome=+0.03, direction=-0.04 (lean grace-dn)
;;   else                   →  outcome=-0.02, direction= 0.0  (lean violence-neutral)
;;
;; SMA-20 needs 20 candles before it's stable; until then the early
;; ticks emit the violence-neutral lean (sma is 0.0 during warmup,
;; falling through to the else branch). The simulator handles the
;; warmup period by simply not opening positions.
(:wat::core::define
  (:trading::sim::sma-cross-thinker -> :trading::sim::Thinker)
  (:trading::sim::Thinker/new
    (:wat::core::lambda
      ((window :trading::types::Candles)
       (pos :Option<trading::sim::Paper>)
       -> :wat::holon::HolonAST)
      (:wat::core::let*
        (((last-candle :Option<trading::types::Candle>)
          (:wat::core::last window))
         ((sma20 :f64)
          (:wat::core::match last-candle -> :f64
            ((Some c) (:trading::types::Candle::Trend/sma20
                        (:trading::types::Candle/trend c)))
            (:None 0.0)))
         ((sma50 :f64)
          (:wat::core::match last-candle -> :f64
            ((Some c) (:trading::types::Candle::Trend/sma50
                        (:trading::types::Candle/trend c)))
            (:None 0.0)))
         ((up-band :f64) (:wat::core::* sma50 1.001))
         ((dn-band :f64) (:wat::core::* sma50 0.999)))
        (:wat::core::if (:wat::core::> sma20 up-band)
                        -> :wat::holon::HolonAST
          (:trading::sim::paper-label 0.03 0.04)
          (:wat::core::if (:wat::core::< sma20 dn-band)
                          -> :wat::holon::HolonAST
            (:trading::sim::paper-label 0.03 -0.04)
            (:trading::sim::paper-label -0.02 0.0)))))))


;; ─── cosine-vs-corners-predictor — Q10 argmax + Action mapping ───
;;
;; Cosine the surface against the four corner labels; argmax → Action
;; per Q10's table:
;;
;;   argmax = corner-grace-up    → (Open :Up)
;;   argmax = corner-grace-dn    → (Open :Down)
;;   argmax = corner-violence-up → :Hold
;;   argmax = corner-violence-dn → :Hold
;;
;; The "violence-* → :Hold" rather than "(Open opposite)" is the
;; conservative read: violence-up means "Up will violence" — it
;; doesn't necessarily mean "Down will grace." Don't trade unless the
;; predictor has positive Grace conviction.
;;
;; Note `:Exit` never comes from the Predictor in v1 — the simulator
;; translates `(Open !d)` while holding `paper-d` into `:Exit`
;; (slice-4-5-design-questions.md Q10, see paper.wat's
;; `effective-action`).
(:wat::core::define
  (:trading::sim::cosine-vs-corners-predictor -> :trading::sim::Predictor)
  (:trading::sim::Predictor/new
    (:wat::core::lambda
      ((surface :wat::holon::HolonAST) -> :trading::sim::Action)
      (:wat::core::let*
        (((c-gu :f64)
          (:wat::holon::cosine surface (:trading::sim::corner-grace-up)))
         ((c-gd :f64)
          (:wat::holon::cosine surface (:trading::sim::corner-grace-dn)))
         ((c-vu :f64)
          (:wat::holon::cosine surface (:trading::sim::corner-violence-up)))
         ((c-vd :f64)
          (:wat::holon::cosine surface (:trading::sim::corner-violence-dn)))
         ;; Argmax via nested comparisons — cleaner than building a
         ;; vec and sorting for four values.
         ((gu-wins? :bool)
          (:wat::core::and
            (:wat::core::>= c-gu c-gd)
            (:wat::core::and
              (:wat::core::>= c-gu c-vu)
              (:wat::core::>= c-gu c-vd))))
         ((gd-wins? :bool)
          (:wat::core::and
            (:wat::core::>= c-gd c-vu)
            (:wat::core::>= c-gd c-vd))))
        (:wat::core::if gu-wins?
                        -> :trading::sim::Action
          (:trading::sim::Action::Open :trading::sim::Direction::Up)
          (:wat::core::if gd-wins?
                          -> :trading::sim::Action
            (:trading::sim::Action::Open :trading::sim::Direction::Down)
            :trading::sim::Action::Hold))))))
