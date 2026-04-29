;; wat/programs/smoke.wat — first program built on the substrate-Event
;; telemetry surface (arc 091 slice 6).
;;
;; Demonstrates the double-write discipline:
;;   - ConsoleLogger (lab-domain Event enum) → runs/<id>.out / .err
;;   - WorkUnit/make-scope + WorkUnitLog → runs/<id>.db
;;
;; The producer pops both handles. Console gets occasional human-
;; friendly events; sqlite gets one Event::Log row per paper-resolution
;; observation, plus whatever Event::Metric rows the wu accumulates
;; from `incr!` calls inside the scope body.

(:wat::load-file! "run.wat")
(:wat::load-file! "../telemetry/Sqlite.wat")
(:wat::load-file! "../types/paper-resolved.wat")


;; ─── Domain enum for console output ─────────────────────────────

(:wat::core::enum :trading::smoke::Event
  (Started   (run-name :String))
  (Heartbeat (n :i64))
  (Stopped   (reason :String)))


;; ─── Producer body (inside WorkUnit scope) ──────────────────────

(:wat::core::define
  (:trading::smoke/run-body
    (wu :wat::telemetry::WorkUnit)
    (logger :wat::telemetry::ConsoleLogger)
    (wlog :wat::telemetry::WorkUnitLog)
    (run-name :String)
    -> :())
  (:wat::core::let*
    (((_started :())
      (:wat::telemetry::ConsoleLogger/info logger
        (:trading::smoke::Event::Started run-name)))
     ((_l1 :())
      (:wat::telemetry::WorkUnitLog/info wlog wu
        (:wat::core::quasiquote
          (:trading::PaperResolved/new
            ,run-name "always-up" "cosine" 1 "Up" 100 388 "Grace" 0.04 0.0))))
     ((_h1 :())
      (:wat::telemetry::ConsoleLogger/info logger
        (:trading::smoke::Event::Heartbeat 1)))
     ((_l2 :())
      (:wat::telemetry::WorkUnitLog/info wlog wu
        (:wat::core::quasiquote
          (:trading::PaperResolved/new
            ,run-name "always-up" "cosine" 2 "Up" 200 488 "Violence" 0.0 0.12))))
     ((_h2 :())
      (:wat::telemetry::ConsoleLogger/info logger
        (:trading::smoke::Event::Heartbeat 2)))
     ((_l3 :())
      (:wat::telemetry::WorkUnitLog/info wlog wu
        (:wat::core::quasiquote
          (:trading::PaperResolved/new
            ,run-name "sma-cross" "cosine" 3 "Down" 300 588 "Grace" 0.07 0.0))))
     ((_stopped :())
      (:wat::telemetry::ConsoleLogger/info logger
        (:trading::smoke::Event::Stopped "smoke complete"))))
    ()))


;; ─── Inner — pops handles, builds loggers, opens make-scope ─────

(:wat::core::define
  (:trading::smoke/inner
    (con-pool :wat::kernel::HandlePool<wat::std::service::Console::Handle>)
    (sqlite-pool :wat::telemetry::Service::HandlePool<wat::telemetry::Event>)
    (run-name :String)
    -> :())
  (:wat::core::let*
    (((con-handle :wat::std::service::Console::Handle)
      (:wat::kernel::HandlePool::pop con-pool))
     ((_finish-con :()) (:wat::kernel::HandlePool::finish con-pool))
     ((sqlite-handle :wat::telemetry::Service::Handle<wat::telemetry::Event>)
      (:wat::kernel::HandlePool::pop sqlite-pool))
     ((_finish-sqlite :()) (:wat::kernel::HandlePool::finish sqlite-pool))
     ((logger :wat::telemetry::ConsoleLogger)
      (:wat::telemetry::ConsoleLogger/new
        con-handle :smoke
        (:wat::core::lambda ((_u :()) -> :wat::time::Instant)
          (:wat::time::now))
        :wat::telemetry::Console::Format::Edn))
     ((wlog :wat::telemetry::WorkUnitLog)
      (:wat::telemetry::WorkUnitLog/new
        sqlite-handle :smoke
        (:wat::core::lambda ((_u :()) -> :wat::time::Instant)
          (:wat::time::now))))
     ((ns :wat::holon::HolonAST) (:wat::holon::Atom :trading.smoke))
     ((scope :wat::telemetry::WorkUnit::Scope<()>)
      (:wat::telemetry::WorkUnit/make-scope sqlite-handle ns))
     ((tags :wat::telemetry::Tags)
      (:wat::core::assoc
        (:wat::core::HashMap :wat::telemetry::Tag)
        (:wat::holon::Atom :run) (:wat::holon::Atom run-name))))
    (scope tags
      (:wat::core::lambda ((wu :wat::telemetry::WorkUnit) -> :())
        (:trading::smoke/run-body wu logger wlog run-name)))))


;; ─── :user::main wiring ─────────────────────────────────────────

(:wat::core::define
  (:trading::smoke/main
    (_stdin  :wat::io::IOReader)
    (_stdout :wat::io::IOWriter)
    (_stderr :wat::io::IOWriter)
    -> :())
  (:wat::core::let*
    (((paths :trading::run::Paths)
      (:trading::run/paths/make "smoke" (:wat::time::now)))
     ((out-path :String) (:trading::run::Paths/out paths))
     ((err-path :String) (:trading::run::Paths/err paths))
     ((db-path  :String) (:trading::run::Paths/db  paths))
     ((run-name :String) db-path)
     ((out-writer :wat::io::IOWriter)
      (:wat::io::IOWriter/open-file out-path))
     ((err-writer :wat::io::IOWriter)
      (:wat::io::IOWriter/open-file err-path))
     ((con-spawn :wat::std::service::Console::Spawn)
      (:wat::std::service::Console/spawn out-writer err-writer 1))
     ((con-pool :wat::kernel::HandlePool<wat::std::service::Console::Handle>)
      (:wat::core::first con-spawn))
     ((con-driver :wat::kernel::ProgramHandle<()>)
      (:wat::core::second con-spawn))
     ((sqlite-spawn :wat::telemetry::Service::Spawn<wat::telemetry::Event>)
      (:trading::telemetry::Sqlite/spawn db-path 1
        (:wat::telemetry::Service/null-metrics-cadence)))
     ((sqlite-pool :wat::telemetry::Service::HandlePool<wat::telemetry::Event>)
      (:wat::core::first sqlite-spawn))
     ((sqlite-driver :wat::kernel::ProgramHandle<()>)
      (:wat::core::second sqlite-spawn))
     ((_inner :())
      (:trading::smoke/inner con-pool sqlite-pool run-name))
     ((_sqlite-join :()) (:wat::kernel::join sqlite-driver)))
    (:wat::kernel::join con-driver)))
