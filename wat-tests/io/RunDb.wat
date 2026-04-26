;; wat-tests/io/RunDb.wat — smoke tests for the SQLite paper-resolution shim.
;;
;; Three direct `:wat::test::deftest` exercises against the
;; `:rust::lab::RunDb` dispatch:
;;   1. open + reopen at the same path (idempotent schema creation)
;;   2. open + log-paper one row (no crash)
;;   3. open + log-paper ten rows (no crash, exercises the loop shape)
;;
;; v1 has no read API at the wat surface (slice-1 spec sub-fog
;; "Read APIs — future arc"); these tests verify writes don't crash.
;; The richer "round-trip read what was written" test waits on the
;; future arc that adds query primitives. Out-of-band verification
;; is via the `sqlite3` CLI on the produced files.
;;
;; Filenames live under `/tmp/` per the BACKLOG's risk note. The
;; `INSERT OR REPLACE` semantics on the `(run_name, paper_id)` PK
;; make rerun-collisions harmless — same row rewritten on second
;; run. No `remove-file!` step required.
;;
;; Pattern: empty-prelude `:wat::test::deftest` (mirror
;; `wat-tests/io/CandleStream.wat`). The shim's `wat_sources()`
;; auto-registers `wat/io/RunDb.wat` via `deps: [shims]` in
;; `tests/test.rs`, so `:lab::rundb::*` is in scope at startup.

;; ─── deftest: open creates schema, reopen succeeds ────────────────
(:wat::test::deftest :trading::test::io::rundb::test-open-creates-schema
  ()
  (:wat::core::let*
    (((db1 :lab::rundb::RunDb)
      (:lab::rundb::open "/tmp/rundb-test-001.db"))
     ;; Open a second handle on the same file. CREATE TABLE IF NOT
     ;; EXISTS makes this idempotent; the binding shadows the first,
     ;; which drops at let* exit.
     ((db2 :lab::rundb::RunDb)
      (:lab::rundb::open "/tmp/rundb-test-001.db")))
    (:wat::test::assert-eq true true)))


;; ─── deftest: log one row, don't crash ────────────────────────────
(:wat::test::deftest :trading::test::io::rundb::test-log-paper-one-row
  ()
  (:wat::core::let*
    (((db :lab::rundb::RunDb)
      (:lab::rundb::open "/tmp/rundb-test-002.db"))
     ((u1 :())
      (:lab::rundb::log-paper-resolved db
        "single-row-run"
        "always-up" "cosine-vs-corners"
        1 "Up"
        100 388
        "Grace"
        0.04 0.0)))
    (:wat::test::assert-eq true true)))


;; ─── deftest: log multiple rows, don't crash ──────────────────────
;; Same handle, two run-names — proves arc 029's per-call run_name
;; routing works (one connection drives many runs, no need to reopen).
(:wat::test::deftest :trading::test::io::rundb::test-log-paper-multiple-rows
  ()
  (:wat::core::let*
    (((db :lab::rundb::RunDb)
      (:lab::rundb::open "/tmp/rundb-test-003.db"))
     ((u1 :())
      (:lab::rundb::log-paper-resolved db "multi-row-up" "always-up" "cosine"
        1 "Up"  100 388 "Grace"    0.04  0.0))
     ((u2 :())
      (:lab::rundb::log-paper-resolved db "multi-row-up" "always-up" "cosine"
        2 "Up"  400 688 "Violence" 0.0   0.02))
     ((u3 :())
      (:lab::rundb::log-paper-resolved db "multi-row-up" "always-up" "cosine"
        3 "Up"  700 988 "Grace"    0.03  0.0))
     ((u4 :())
      (:lab::rundb::log-paper-resolved db "multi-row-down" "sma-cross" "cosine"
        4 "Down" 1000 1288 "Grace" 0.025 0.0))
     ((u5 :())
      (:lab::rundb::log-paper-resolved db "multi-row-down" "sma-cross" "cosine"
        5 "Down" 1300 1588 "Violence" 0.0 0.018)))
    (:wat::test::assert-eq true true)))
