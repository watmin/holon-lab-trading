;; wat-tests/io/RunDbService.wat — smoke tests for the
;; :lab::rundb::Service CSP wrapper.
;;
;; Three deftests:
;;   1. Single-client batch round-trip — one handle, one batch
;;      of 3 PaperResolved entries, drop, join. No crash = pass.
;;   2. Multi-client fan-in — three workers, three handles,
;;      three distinct run_names. Each worker batches its
;;      entries, drops handle. Driver fans in, commits, exits.
;;   3. Lifecycle on disconnect — pop handles, drop without
;;      logging, join. Driver sees all rxs disconnect, exits
;;      clean.
;;
;; v1 has no in-wat read API — verification beyond "no crash"
;; happens via the sqlite3 CLI on /tmp/rundb-service-test-*.db
;; out of band per arc 027/029 scope. The deftests assert
;; assert-eq true true at the end; the real signal is that
;; (:wat::kernel::join driver) doesn't panic.
;;
;; ── Lifetime discipline (Console multi-writer pattern) ──
;; The driver loop exits only when EVERY ReqRx has disconnected.
;; A ReqTx held in scope keeps its corresponding ReqRx alive in
;; the driver's select loop → join would block forever. Every
;; test below wraps client-side bindings (popped handles, ack
;; channels, worker spawns/joins) in an INNER let* whose scope
;; exits before the outer let*'s `(:wat::kernel::join driver)`.
;; When the inner scope drops, every ReqTx clone disappears, the
;; driver loop converges to empty, exits, and the outer join
;; returns. Same shape as
;; `wat-rs/wat-tests/std/service/Console.wat` test-multi-writer.
;;
;; Per arc 029 BACKLOG slice 2 risk note: the rundb service
;; writes to its own connection (not shared StringIo stdout),
;; so direct deftest with in-process spawn should suffice — no
;; `run-hermetic-ast` wrapping needed.


;; ─── deftest 1 — single client, three-row batch round-trip ────────

(:wat::test::deftest :trading::test::io::rundb-service::test-single-client-batch
  ()
  (:wat::core::let*
    (((path :String) "/tmp/rundb-service-test-001.db")
     ((spawn :lab::rundb::Service::Spawn) (:lab::rundb::Service path 1))
     ((pool :lab::rundb::Service::ReqTxPool) (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<()>) (:wat::core::second spawn))
     ;; Inner let*: every client-side ReqTx lives only here. When
     ;; this scope exits, the ReqTx drops → driver's last rx
     ;; disconnects → loop exits → outer `(join driver)` unblocks.
     ((_inner :())
      (:wat::core::let*
        (((req-tx :lab::rundb::Service::ReqTx)
          (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))
         ((ack-channel :lab::rundb::Service::AckChannel)
          (:wat::kernel::make-bounded-queue :() 1))
         ((ack-tx :lab::rundb::Service::AckTx) (:wat::core::first ack-channel))
         ((ack-rx :lab::rundb::Service::AckRx) (:wat::core::second ack-channel))
         ((entries :Vec<lab::log::LogEntry>)
          (:wat::core::vec :lab::log::LogEntry
            (:lab::log::LogEntry::PaperResolved
              "single-batch" "always-up" "cosine"
              1 "Up" 100 388 "Grace" 0.04 0.0)
            (:lab::log::LogEntry::PaperResolved
              "single-batch" "always-up" "cosine"
              2 "Up" 400 688 "Violence" 0.0 0.02)
            (:lab::log::LogEntry::PaperResolved
              "single-batch" "always-up" "cosine"
              3 "Up" 700 988 "Grace" 0.03 0.0))))
        (:lab::rundb::Service/batch-log req-tx ack-tx ack-rx entries)))
     ((_join :()) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))


;; ─── deftest 2 — three workers, three handles, fan-in ─────────────

;; A worker takes one handle, builds its own ack channel, batch-
;; logs one entry under its own run_name, drops at return.
;; Defined in the deftest's prelude (second arg) — top-level
;; defines aren't visible inside the deftest's sandboxed body
;; (per `:wat::test::deftest` hermetic-by-default semantics).
(:wat::test::deftest :trading::test::io::rundb-service::test-multi-client-fan-in
  ((:wat::core::define
     (:trading::test::io::rundb-service::worker
       (req-tx :lab::rundb::Service::ReqTx)
       (run-name :String)
       (paper-id :i64)
       -> :())
     (:wat::core::let*
       (((ack-channel :lab::rundb::Service::AckChannel)
         (:wat::kernel::make-bounded-queue :() 1))
        ((ack-tx :lab::rundb::Service::AckTx) (:wat::core::first ack-channel))
        ((ack-rx :lab::rundb::Service::AckRx) (:wat::core::second ack-channel))
        ((entries :Vec<lab::log::LogEntry>)
         (:wat::core::vec :lab::log::LogEntry
           (:lab::log::LogEntry::PaperResolved
             run-name "always-up" "cosine"
             paper-id "Up" 100 388 "Grace" 0.04 0.0))))
       (:lab::rundb::Service/batch-log req-tx ack-tx ack-rx entries))))
  (:wat::core::let*
    (((path :String) "/tmp/rundb-service-test-002.db")
     ((spawn :lab::rundb::Service::Spawn) (:lab::rundb::Service path 3))
     ((pool :lab::rundb::Service::ReqTxPool) (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<()>) (:wat::core::second spawn))
     ;; Inner scope owns all popped ReqTxs. Spawn moves a clone
     ;; into each worker; the parent's local bindings drop here
     ;; at inner-let* exit. When all workers join (their clones
     ;; drop on return), the driver's rxs disconnect.
     ((_inner :())
      (:wat::core::let*
        (((tx-a :lab::rundb::Service::ReqTx) (:wat::kernel::HandlePool::pop pool))
         ((tx-b :lab::rundb::Service::ReqTx) (:wat::kernel::HandlePool::pop pool))
         ((tx-c :lab::rundb::Service::ReqTx) (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))
         ((wa :wat::kernel::ProgramHandle<()>)
          (:wat::kernel::spawn :trading::test::io::rundb-service::worker tx-a "fan-in-a" 11))
         ((wb :wat::kernel::ProgramHandle<()>)
          (:wat::kernel::spawn :trading::test::io::rundb-service::worker tx-b "fan-in-b" 12))
         ((wc :wat::kernel::ProgramHandle<()>)
          (:wat::kernel::spawn :trading::test::io::rundb-service::worker tx-c "fan-in-c" 13))
         ((_ja :()) (:wat::kernel::join wa))
         ((_jb :()) (:wat::kernel::join wb)))
        (:wat::kernel::join wc)))
     ((_jdrv :()) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))


;; ─── deftest 3 — lifecycle on disconnect ──────────────────────────

;; Pop both handles, drop without logging anything. Driver sees
;; both rxs disconnect, loop exits cleanly, join confirms no panic.
(:wat::test::deftest :trading::test::io::rundb-service::test-disconnect-clean-exit
  ()
  (:wat::core::let*
    (((path :String) "/tmp/rundb-service-test-003.db")
     ((spawn :lab::rundb::Service::Spawn) (:lab::rundb::Service path 2))
     ((pool :lab::rundb::Service::ReqTxPool) (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<()>) (:wat::core::second spawn))
     ;; Inner scope: pop both handles, finish pool, do nothing.
     ;; Both ReqTx bindings drop at inner-let* exit; driver loop
     ;; sees all rxs disconnect; exits.
     ((_inner :())
      (:wat::core::let*
        (((tx-a :lab::rundb::Service::ReqTx) (:wat::kernel::HandlePool::pop pool))
         ((tx-b :lab::rundb::Service::ReqTx) (:wat::kernel::HandlePool::pop pool)))
        (:wat::kernel::HandlePool::finish pool)))
     ((_join :()) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))
