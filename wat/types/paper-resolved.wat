;; :trading::PaperResolved — domain payload struct for the lab's
;; per-paper resolution observation.
;;
;; Slice 6 (arc 091) replaced the `:trading::log::LogEntry::PaperResolved`
;; variant. The struct is now domain data — the substrate's
;; `:wat::telemetry::Event::Log` carries it as Tagged data on the
;; row's `data` column. SQL queries against runs/<id>.db's `log`
;; table parse the EDN back to typed fields.
;;
;; Used by:
;;   - wat/programs/smoke.wat (showcase emission)
;;   - wat-tests-integ/proof/002-thinker-baseline (per-outcome row)
;;   - wat-tests-integ/proof/003-thinker-significance (per-outcome row)

(:wat::core::struct :trading::PaperResolved
  (run-name    :wat::core::String)
  (thinker     :wat::core::String)
  (predictor   :wat::core::String)
  (paper-id    :wat::core::i64)
  (direction   :wat::core::String)
  (opened-at   :wat::core::i64)
  (resolved-at :wat::core::i64)
  (state       :wat::core::String)
  (residue     :wat::core::f64)
  (loss        :wat::core::f64))
