;; wat/programs/pulse.wat — minimal showcase for the substrate-Event
;; telemetry wires.
;;
;; Slice 6 (arc 091): pulse is intentionally thin — its job is to
;; prove that the wat-telemetry surface ships rows end-to-end through
;; Service<Event,_> + Sqlite/auto-spawn against a real DB. The
;; per-phase batch timings the pre-slice-6 pulse maintained were
;; bottleneck-bisection scaffolding; with WorkUnit/make-scope wrapping
;; the walk, those metrics emerge naturally from `incr!` + `timed`
;; without bespoke construction.
;;
;; Each run:
;;   - opens a bounded candle stream
;;   - opens a make-scope closure over the sqlite handle + namespace
;;   - inside the scope body: walks the stream, bumps `:candle`
;;     counter per ohlcv; the substrate ships one Event::Metric row
;;     at scope-close with the total count
;;
;; SQL on runs/<id>.db then shows the metric table populated with
;; one row whose metric_name == ":candle" and metric_value == N.

(:wat::load-file! "run.wat")
(:wat::load-file! "../io/CandleStream.wat")
(:wat::load-file! "../telemetry/Sqlite.wat")


;; ─── Console heartbeat enum ─────────────────────────────────────

(:wat::core::enum :trading::pulse::Tick
  (Started (run-name :String) (planned :i64))
  (Stopped (n :i64)))


;; ─── Pulse summary form — Event::Log payload ───────────────────
;;
;; Slice 6's "both tables joinable via uuid" verification. The wu
;; running through walk-step bumps :candle (one Event::Metric row at
;; scope-close); before scope-close we also emit ONE Event::Log row
;; carrying this RunSummary. Both rows share the wu's uuid; SQL can
;; cross-join via `metric.uuid = log.uuid`.
(:wat::core::struct :trading::pulse::RunSummary
  (run-name :String)
  (planned  :i64)
  (walked   :i64))


;; ─── Walker — tail-recursive count over the stream ──────────────

(:wat::core::define
  (:trading::pulse/walk-step
    (wu :wat::telemetry::WorkUnit)
    (stream :trading::candles::Stream)
    (n :i64)
    -> :i64)
  (:wat::core::match (:trading::candles::next! stream) -> :i64
    ((Some _candle)
      (:wat::core::let*
        (((_ :()) (:wat::telemetry::WorkUnit/incr! wu (:wat::holon::Atom :candle))))
        (:trading::pulse/walk-step wu stream (:wat::core::+ n 1))))
    (:None n)))




;; ─── Inner — make-scope around the walk; substrate ships at close ─

(:wat::core::define
  (:trading::pulse/inner
    (con-pool :wat::kernel::HandlePool<wat::std::service::Console::Handle>)
    (sqlite-pool :wat::telemetry::Service::HandlePool<wat::telemetry::Event>)
    (stream :trading::candles::Stream)
    (run-name :String)
    (planned :i64)
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
        con-handle :pulse
        (:wat::core::lambda ((_u :()) -> :wat::time::Instant)
          (:wat::time::now))
        :wat::telemetry::Console::Format::Edn))
     ((wlog :wat::telemetry::WorkUnitLog)
      (:wat::telemetry::WorkUnitLog/new
        sqlite-handle :pulse
        (:wat::core::lambda ((_u :()) -> :wat::time::Instant)
          (:wat::time::now))))
     ((_started :())
      (:wat::telemetry::ConsoleLogger/info logger
        (:trading::pulse::Tick::Started run-name planned)))
     ((ns :wat::holon::HolonAST) (:wat::holon::Atom :trading.pulse))
     ((scope :wat::telemetry::WorkUnit::Scope<i64>)
      (:wat::telemetry::WorkUnit/make-scope sqlite-handle ns))
     ((tags :wat::telemetry::Tags)
      (:wat::core::assoc
        (:wat::core::HashMap :wat::telemetry::Tag)
        (:wat::holon::Atom :run) (:wat::holon::Atom run-name)))
     ((n :i64)
      (scope tags
        (:wat::core::lambda ((wu :wat::telemetry::WorkUnit) -> :i64)
          (:wat::core::let*
            (((walked :i64) (:trading::pulse/walk-step wu stream 0))
             ((summary :trading::pulse::RunSummary)
              (:trading::pulse::RunSummary/new run-name planned walked))
             ((_log :())
              (:wat::telemetry::WorkUnitLog/info wlog wu
                (:wat::core::struct->form summary))))
            walked))))
     ((_stopped :())
      (:wat::telemetry::ConsoleLogger/info logger
        (:trading::pulse::Tick::Stopped n))))
    ()))


;; ─── :user::main wiring ─────────────────────────────────────────

(:wat::core::define
  (:trading::pulse/main
    (_stdin  :wat::io::IOReader)
    (_stdout :wat::io::IOWriter)
    (_stderr :wat::io::IOWriter)
    -> :())
  (:wat::core::let*
    (((paths :trading::run::Paths)
      (:trading::run/paths/make "pulse" (:wat::time::now)))
     ((out-writer :wat::io::IOWriter)
      (:wat::io::IOWriter/open-file (:trading::run::Paths/out paths)))
     ((err-writer :wat::io::IOWriter)
      (:wat::io::IOWriter/open-file (:trading::run::Paths/err paths)))
     ((db-path  :String) (:trading::run::Paths/db paths))
     ((run-name :String) db-path)
     ((planned :i64) 1000)
     ((stream :trading::candles::Stream)
      (:trading::candles::open-bounded "data/btc_5m_raw.parquet" planned))
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
      (:trading::pulse/inner con-pool sqlite-pool stream run-name planned))
     ((_sqlite-join :()) (:wat::kernel::join sqlite-driver)))
    (:wat::kernel::join con-driver)))
