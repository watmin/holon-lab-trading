;; :trading::log::LogEntry — the unit of communication crossing
;; the telemetry sink boundary.
;;
;; Discriminated union, one variant per *kind of thing that
;; happened* in a run. Grows variant-by-variant as proofs surface
;; new categories. The archive's enterprise (`archived/pre-wat-
;; native/src/types/log_entry.rs`) shipped 13 variants —
;; ProposalSubmitted, TradeSettled, PaperResolved, Diagnostic
;; (per-candle perf), Telemetry (CloudWatch-style), several
;; *Snapshot variants. Same shape; this slice ships two.
;;
;; This enum decl is now the SOURCE OF TRUTH for the on-disk
;; schema. `:wat::std::telemetry::Sqlite/auto-spawn` (arc 085)
;; reads this decl at startup, derives:
;;   - one CREATE TABLE per Tagged variant
;;     (variant name PascalCase → table name snake_case;
;;      field name kebab → column name snake;
;;      field type → SQLite affinity)
;;   - the per-variant INSERT
;;   - the per-entry binder (Value::Enum.fields → Param vec)
;;
;; Adding a future variant is one step: append it here. Schema +
;; INSERT + binder all derive automatically. Existing call sites
;; stay untouched.

(:wat::core::enum :trading::log::LogEntry
  ;; PaperResolved — the simulator emits one per Outcome at
  ;; resolution. Substrate derives table `paper_resolved` with
  ;; one column per field in declaration order.
  (PaperResolved
    (run-name :String) (thinker :String) (predictor :String)
    (paper-id :i64) (direction :String)
    (opened-at :i64) (resolved-at :i64)
    (state :String) (residue :f64) (loss :f64))
  ;; Telemetry — CloudWatch-style metric observation. Substrate
  ;; derives table `telemetry`. `dimensions` is JSON-encoded to
  ;; avoid needing a Map<String,String> in the sum.
  (Telemetry
    (namespace :String) (id :String) (dimensions :String)
    (timestamp-ns :i64)
    (metric-name :String) (metric-value :f64) (metric-unit :String)))
