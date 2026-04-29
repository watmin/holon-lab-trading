;; wat/programs/smoke.wat — first program built on the new logging
;; substrate. Demonstrates the double-write discipline:
;;   - ConsoleLogger (lab-domain Event enum) → runs/<id>.out / .err
;;   - Sqlite/auto-spawn (LogEntry) → runs/<id>.db
;;
;; The producer holds BOTH handles; each emission picks the surface
;; that fits. Console gets occasional human-friendly events; sqlite
;; gets the high-fidelity LogEntry rows that survive the run.
;;
;; Wiring shape (CIRCUIT.md):
;;   :user::main owns the Console + Sqlite drivers (outer scope).
;;   Inner scope opens the per-run files, pops handles, builds the
;;   ConsoleLogger, calls smoke/run with both surfaces wired in.
;;   Inner exits → handles drop → drivers see disconnect → outer
;;   joins cascade.

(:wat::load-file! "run.wat")
(:wat::load-file! "../io/log/LogEntry.wat")
(:wat::load-file! "../io/telemetry/Sqlite.wat")


;; ─── Domain enum for console output ─────────────────────────────
;;
;; Smoke-specific events. Stays light — console lines should read
;; in one glance. The trader's full-fidelity records go to sqlite
;; via the existing `:trading::log::LogEntry` enum.

(:wat::core::enum :trading::smoke::Event
  (Started   (run-name :String))
  (Heartbeat (n :i64))
  (Stopped   (reason :String)))


;; ─── Producer body ──────────────────────────────────────────────
;;
;; Takes both surfaces. Emits a Started event to console, three
;; PaperResolved entries to sqlite (with a Heartbeat to console
;; between each), then a Stopped event to console. Single batch-log
;; call to sqlite at the end — three entries, one ack roundtrip.
;;
;; Real producers (thinkers, treasury, broker) will follow the same
;; pattern: occasional console emissions for live observability;
;; one batch-log per natural rhythm boundary for archival.

(:wat::core::define
  (:trading::smoke/run
    (logger :wat::std::telemetry::ConsoleLogger)
    (sqlite-tx :wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>)
    (ack-tx :wat::std::telemetry::Service::AckTx)
    (ack-rx :wat::std::telemetry::Service::AckRx)
    (run-name :String)
    -> :())
  (:wat::core::let*
    (;; Console: program lifecycle event.
     ((_started :())
      (:wat::std::telemetry::ConsoleLogger/info logger
        (:trading::smoke::Event::Started run-name)))

     ;; Console: heartbeats between sqlite batches.
     ((_h0 :())
      (:wat::std::telemetry::ConsoleLogger/info logger
        (:trading::smoke::Event::Heartbeat 0)))
     ((_h1 :())
      (:wat::std::telemetry::ConsoleLogger/info logger
        (:trading::smoke::Event::Heartbeat 1)))
     ((_h2 :())
      (:wat::std::telemetry::ConsoleLogger/info logger
        (:trading::smoke::Event::Heartbeat 2)))

     ;; Console: a warning + an error to demonstrate stderr routing.
     ((_w :())
      (:wat::std::telemetry::ConsoleLogger/warn logger
        (:trading::smoke::Event::Heartbeat 99)))
     ((_e :())
      (:wat::std::telemetry::ConsoleLogger/error logger
        (:trading::smoke::Event::Stopped "synthetic-error-demo")))

     ;; Sqlite: three high-fidelity LogEntry::PaperResolved rows.
     ;; In a real producer these come from the simulator's outcomes;
     ;; here they're synthetic stand-ins to exercise the pipe.
     ((entries :Vec<trading::log::LogEntry>)
      (:wat::core::vec :trading::log::LogEntry
        (:trading::log::LogEntry::PaperResolved
          run-name "always-up" "cosine" 1 "Up" 100 388 "Grace" 0.04 0.0)
        (:trading::log::LogEntry::PaperResolved
          run-name "always-up" "cosine" 2 "Up" 200 488 "Violence" 0.0 0.12)
        (:trading::log::LogEntry::PaperResolved
          run-name "sma-cross" "cosine" 3 "Down" 300 588 "Grace" 0.07 0.0)))
     ((_log :())
      (:wat::std::telemetry::Service/batch-log
        sqlite-tx ack-tx ack-rx entries))

     ;; Console: program lifecycle close.
     ((_stopped :())
      (:wat::std::telemetry::ConsoleLogger/info logger
        (:trading::smoke::Event::Stopped "smoke complete"))))
    ()))


;; ─── Inner-scope helper — pops handles, builds logger, runs body ─
;;
;; Per SERVICE-PROGRAMS.md Step 9: each driver's lockstep gets its
;; own scope level. Console driver lives in :user::main; sqlite
;; driver also lives in :user::main; this helper owns the inner
;; scope where both pools' handles get popped + dropped.

(:wat::core::define
  (:trading::smoke/inner
    (con-pool :wat::kernel::HandlePool<wat::std::service::Console::Tx>)
    (sqlite-pool :wat::std::telemetry::Service::ReqTxPool<trading::log::LogEntry>)
    (run-name :String)
    -> :())
  (:wat::core::let*
    (((con-tx :wat::std::service::Console::Tx)
      (:wat::kernel::HandlePool::pop con-pool))
     ((_finish-con :()) (:wat::kernel::HandlePool::finish con-pool))
     ((sqlite-tx :wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>)
      (:wat::kernel::HandlePool::pop sqlite-pool))
     ((_finish-sqlite :()) (:wat::kernel::HandlePool::finish sqlite-pool))
     ((ack-pair :wat::std::telemetry::Service::AckChannel)
      (:wat::kernel::make-bounded-queue :() 1))
     ((ack-tx :wat::std::telemetry::Service::AckTx)
      (:wat::core::first ack-pair))
     ((ack-rx :wat::std::telemetry::Service::AckRx)
      (:wat::core::second ack-pair))
     ;; Build the ConsoleLogger. Production clock; Edn format
     ;; (round-trip-safe per arcs 086 + 087); caller identity is
     ;; :smoke for this program.
     ((logger :wat::std::telemetry::ConsoleLogger)
      (:wat::std::telemetry::ConsoleLogger/new
        con-tx :smoke
        (:wat::core::lambda ((_u :()) -> :wat::time::Instant)
          (:wat::time::now))
        :wat::std::telemetry::Console::Format::Edn)))
    (:trading::smoke/run logger sqlite-tx ack-tx ack-rx run-name)))


;; ─── :user::main wiring — outer scope. CIRCUIT.md ───────────────
;;
;; Constructs per-run paths, opens the .out / .err file writers,
;; spawns Console (using THOSE writers, not the parent process's
;; stdout/stderr), spawns Sqlite/auto-spawn against the .db path,
;; runs the inner producer, joins both drivers in cascade.
;;
;; The .out / .err files are owned by the Console driver thread;
;; they get closed when Console's loop exits at disconnect.

(:wat::core::define
  (:trading::smoke/main
    (_stdin  :wat::io::IOReader)
    (_stdout :wat::io::IOWriter)
    (_stderr :wat::io::IOWriter)
    -> :())
  (:wat::core::let*
    (;; Per-run identity.
     ((paths :trading::run::Paths)
      (:trading::run/paths/make "smoke" (:wat::time::now)))
     ((out-path :String) (:trading::run::Paths/out paths))
     ((err-path :String) (:trading::run::Paths/err paths))
     ((db-path  :String) (:trading::run::Paths/db  paths))
     ;; The run-name baked into PaperResolved rows so post-hoc SQL
     ;; queries can filter by run.
     ((run-name :String) db-path)

     ;; File-backed IOWriters — Console writes here, not to the
     ;; parent process's stdio.
     ((out-writer :wat::io::IOWriter)
      (:wat::io::IOWriter/open-file out-path))
     ((err-writer :wat::io::IOWriter)
      (:wat::io::IOWriter/open-file err-path))

     ;; Spawn Console — count=1 (single producer in this smoke).
     ((con-spawn :wat::std::service::Console::Spawn)
      (:wat::std::service::Console/spawn out-writer err-writer 1))
     ((con-pool :wat::kernel::HandlePool<wat::std::service::Console::Tx>)
      (:wat::core::first con-spawn))
     ((con-driver :wat::kernel::ProgramHandle<()>)
      (:wat::core::second con-spawn))

     ;; Spawn Sqlite/auto-spawn — count=1, null-cadence (no
     ;; substrate self-heartbeat for this smoke).
     ((sqlite-spawn :trading::telemetry::Spawn)
      (:trading::telemetry::Sqlite/spawn db-path 1
        (:wat::std::telemetry::Service/null-metrics-cadence)))
     ((sqlite-pool :wat::std::telemetry::Service::ReqTxPool<trading::log::LogEntry>)
      (:wat::core::first sqlite-spawn))
     ((sqlite-driver :wat::kernel::ProgramHandle<()>)
      (:wat::core::second sqlite-spawn))

     ;; Inner runs the producer. On return, all handles drop;
     ;; Console + Sqlite drivers see disconnect; loops exit.
     ((_inner :())
      (:trading::smoke/inner con-pool sqlite-pool run-name))

     ;; Join sqlite first, then console — order doesn't matter for
     ;; correctness (both drivers are unblocked by the inner-scope
     ;; sender drops).
     ((_sqlite-join :()) (:wat::kernel::join sqlite-driver)))
    (:wat::kernel::join con-driver)))
