;; :trading::log::LogEntry — the unit of communication crossing
;; the rundb service boundary.
;;
;; Discriminated union, one variant per *kind of thing that
;; happened* in a run. Grows variant-by-variant as proofs surface
;; new categories. The archive's enterprise (`archived/pre-wat-
;; native/src/types/log_entry.rs`) shipped 13 variants —
;; ProposalSubmitted, TradeSettled, PaperResolved, Diagnostic
;; (per-candle perf), Telemetry (CloudWatch-style), several
;; *Snapshot variants. Same shape; this arc ships just one.
;;
;; The slice-2 service `(:trading::rundb::Service)` accepts
;; `Vec<LogEntry>` per batch and dispatches each entry to its
;; per-variant shim wrapper (`:trading::rundb::log-paper-resolved`
;; today; `:trading::rundb::log-telemetry`, etc., when they ship).
;; Variant dispatch is pattern-match in wat (per arc 029 Q9 —
;; "as much as we can in wat"); the shim only owns the typed
;; INSERT wrappers.
;;
;; Adding a future variant is four steps:
;;   1. New `(VariantName field-types...)` arm in this enum.
;;   2. New `(:trading::log::schema-<variant-snake>)` constant +
;;      registration in `:trading::log::all-schemas` (in schema.wat).
;;   3. New shim method `pub fn log_<variant_snake>(...)` +
;;      wat wrapper at `:trading::rundb::log-<variant-name>`.
;;   4. New arm in `Service/dispatch`'s match.
;; Existing callers stay untouched.

(:wat::core::enum :trading::log::LogEntry
  ;; PaperResolved — the simulator emits one per Outcome at
  ;; resolution. Field order matches `:trading::rundb::log-paper-
  ;; resolved` after `db`: run-name, thinker, predictor, paper-id,
  ;; direction, opened-at, resolved-at, state, residue, loss.
  (PaperResolved
    (run-name :String) (thinker :String) (predictor :String)
    (paper-id :i64) (direction :String)
    (opened-at :i64) (resolved-at :i64)
    (state :String) (residue :f64) (loss :f64)))
