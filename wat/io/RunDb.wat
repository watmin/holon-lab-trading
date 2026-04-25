;; :lab::rundb::* — wat surface over the SQLite paper-resolution writer.
;;
;; Backed by `:rust::lab::RunDb` from `src/shims.rs`. The shim holds a
;; `rusqlite::Connection` plus a `run_name` discriminator bound at
;; open time; every `log-paper` call inserts one row into the
;; `paper_resolutions` table with that run name attached. Thread-owned
;; scope — one db per program thread, no Mutex.
;;
;; Mirrors `wat-lru` and `CandleStream`'s surface shape (typealias +
;; thin define wrappers over `:rust::*`).
;;
;; Schema (auto-created on `open`):
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
;;   (let* (((db :lab::rundb::RunDb)
;;           (:lab::rundb::open "runs/proof-002.db" "always-up-baseline")))
;;     (:lab::rundb::log-paper db "always-up" "cosine-vs-corners"
;;                              1 "Up" 100 388 "Grace" 0.04 0.0)
;;     (:lab::rundb::close db))
;;
;; Read-side queries are out of scope for v1; use the `sqlite3` CLI
;; against the produced DB file. A future arc adds read APIs once a
;; wat consumer surfaces.

(:wat::core::use! :rust::lab::RunDb)

(:wat::core::typealias :lab::rundb::RunDb :rust::lab::RunDb)

;; Open or create a SQLite database at `path`, ensure the
;; `paper_resolutions` schema, and bind `run-name` for every
;; subsequent `log-paper` call.
(:wat::core::define
  (:lab::rundb::open
    (path :String)
    (run-name :String)
    -> :lab::rundb::RunDb)
  (:rust::lab::RunDb::open path run-name))

;; Insert one row into `paper_resolutions`. Auto-commit; no batching;
;; idempotent on the (run-name, paper-id) primary key.
(:wat::core::define
  (:lab::rundb::log-paper
    (db :lab::rundb::RunDb)
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
  (:rust::lab::RunDb::log_paper
    db thinker predictor paper-id direction
    opened-at resolved-at state residue loss))
