;; :trading::rundb::* — wat surface over the SQLite paper-resolution writer.
;;
;; Backed by `:rust::trading::RunDb` from `src/shims.rs`. The shim holds a
;; `rusqlite::Connection`; every `log-paper-resolved` call takes its
;; `run-name` per-message and inserts one row into the
;; `paper_resolutions` table with that name attached. Thread-owned
;; scope — one db per program thread, no Mutex.
;;
;; Arc 029 (2026-04-25) refactored two ways:
;;   1. `run-name` moved from a per-handle bind (arc 027 shape) to a
;;      per-message parameter. Lets one shim handle drive multiple
;;      run names.
;;   2. `log-paper` renamed to `log-paper-resolved` to align with
;;      the slice-2 `:trading::log::LogEntry::PaperResolved` variant the
;;      `:trading::rundb::Service` wrapper dispatches over.
;;
;; Both changes are prerequisites for the CSP service shape that
;; fans in N clients onto one underlying connection
;; (see `wat/io/RunDbService.wat` — slice 2).
;;
;; Mirrors `wat-lru` and `CandleStream`'s surface shape (typealias +
;; thin define wrappers over `:rust::*`).
;;
;; Schema (auto-created on `open` for backward compat with
;; direct-shim callers like proof 002; service-mode callers will
;; install schemas explicitly via `execute-ddl` once slice 2 lands):
;;
;;   paper_resolutions(run_name, thinker, predictor, paper_id,
;;                     direction, opened_at, resolved_at, state,
;;                     residue, loss)
;;     PRIMARY KEY (run_name, paper_id)
;;
;; `INSERT OR REPLACE` semantics — re-logging the same
;; `(run_name, paper_id)` overwrites the prior row. Idempotent, which
;; keeps tests friendly to reruns without a `remove-file!` helper.
;;
;; Usage:
;;   (let* (((db :trading::rundb::RunDb)
;;           (:trading::rundb::open "runs/proof-002.db")))
;;     (:trading::rundb::log-paper-resolved db
;;       "always-up-baseline"
;;       "always-up" "cosine-vs-corners"
;;       1 "Up" 100 388 "Grace" 0.04 0.0))
;;
;; Read-side queries are out of scope for v1; use the `sqlite3` CLI
;; against the produced DB file. A future arc adds read APIs once a
;; wat consumer surfaces.

(:wat::core::use! :rust::trading::RunDb)

(:wat::core::typealias :trading::rundb::RunDb :rust::trading::RunDb)

;; Open or create a SQLite database at `path` and ensure the
;; `paper_resolutions` schema. The `run-name` discriminator for each
;; row is supplied per-call on `log-paper-resolved`.
(:wat::core::define
  (:trading::rundb::open
    (path :String)
    -> :trading::rundb::RunDb)
  (:rust::trading::RunDb::open path))

;; Run an arbitrary DDL string (CREATE TABLE, CREATE INDEX, etc.).
;; The slice-2 :trading::rundb::Service driver iterates :trading::log::all-
;; schemas at startup and execute-ddl's each. Idempotent — schemas
;; use CREATE TABLE IF NOT EXISTS.
(:wat::core::define
  (:trading::rundb::execute-ddl
    (db :trading::rundb::RunDb)
    (ddl-str :String)
    -> :())
  (:rust::trading::RunDb::execute_ddl db ddl-str))

;; Insert one row into `paper_resolutions` under the given run-name.
;; Auto-commit; no batching; idempotent on the (run-name, paper-id)
;; primary key.
(:wat::core::define
  (:trading::rundb::log-paper-resolved
    (db :trading::rundb::RunDb)
    (run-name :String)
    (thinker :String)
    (predictor :String)
    (paper-id :i64)
    (direction :String)
    (opened-at :i64)
    (resolved-at :i64)
    (state :String)
    (residue :f64)
    (loss :f64)
    -> :())
  (:rust::trading::RunDb::log_paper_resolved
    db run-name thinker predictor paper-id direction
    opened-at resolved-at state residue loss))

;; Insert one row into the `telemetry` table — CloudWatch-style
;; (namespace, id, dimensions, timestamp_ns, metric_name,
;;  metric_value, metric_unit). Auto-commit. Arc 030 slice 1.
;; Backed by `LogEntry::Telemetry`; the slice-2 service routes
;; that variant here through `Service/dispatch`.
(:wat::core::define
  (:trading::rundb::log-telemetry
    (db :trading::rundb::RunDb)
    (namespace :String)
    (id :String)
    (dimensions :String)
    (timestamp-ns :i64)
    (metric-name :String)
    (metric-value :f64)
    (metric-unit :String)
    -> :())
  (:rust::trading::RunDb::log_telemetry
    db namespace id dimensions
    timestamp-ns metric-name metric-value metric-unit))
