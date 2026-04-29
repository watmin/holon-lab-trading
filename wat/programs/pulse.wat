;; wat/programs/pulse.wat — candle-stream-as-pulse plumbing test
;; with per-phase timing emitted as Telemetry rows.
;;
;; CIRCUIT.md: "the input stream is the pulse." This program reads a
;; bounded BTC candle stream, emits one `LogEntry::Telemetry` row per
;; candle for the close price, plus one row per phase per batch for
;; timing breakdown. Pure plumbing — no encoding, no observers.
;;
;; Per-batch phase metrics (at batch boundary, all share `batch_ts`):
;;   total_ns       — wall time for the full batch
;;   next_ns        — sum of `next!` time across the batch
;;   build_ns       — sum of `build-entry + concat` time across batch
;;   flush_ns       — time inside `batch-log + ack`
;;   overhead_ns    — total - (next + build + flush) — interpreter cost
;;
;; Then SQL on runs/<id>.db tells you where the bottleneck is:
;;
;;   SELECT metric_name,
;;          ROUND(SUM(metric_value)/1e9, 2) AS total_seconds
;;   FROM telemetry
;;   WHERE namespace = 'pulse.timing'
;;   GROUP BY metric_name
;;   ORDER BY total_seconds DESC;
;;
;; Mirrors the archive's `emit_metric` discipline
;; (archived/pre-wat-native/src/programs/telemetry.rs +
;;  archived/pre-wat-native/src/programs/app/broker_program.rs's
;;  ~25 named phase metrics per candle).

(:wat::load-file! "run.wat")
(:wat::load-file! "../io/CandleStream.wat")
(:wat::load-file! "../io/log/LogEntry.wat")
(:wat::load-file! "../io/telemetry/Sqlite.wat")


;; ─── Domain enum for console output ─────────────────────────────

(:wat::core::enum :trading::pulse::Tick
  (Started   (run-name :String) (planned :i64))
  (Heartbeat (n :i64))
  (Stopped   (n :i64)))


;; ─── Build a single Telemetry row ───────────────────────────────

(:wat::core::define
  (:trading::pulse/metric
    (namespace :String)
    (run-name :String)
    (timestamp-ns :i64)
    (metric-name :String)
    (metric-value :f64)
    (metric-unit :String)
    -> :trading::log::LogEntry)
  (:trading::log::LogEntry::Telemetry
    namespace run-name "{}"
    timestamp-ns metric-name metric-value metric-unit))


;; ─── Build the close-price entry from a candle ──────────────────

(:wat::core::define
  (:trading::pulse/build-entry
    (run-name :String)
    (ts-us :i64)
    (close :f64)
    -> :trading::log::LogEntry)
  (:trading::pulse/metric
    "pulse.candle" run-name (:wat::core::* ts-us 1000)
    "close" close "USD"))


;; ─── Build per-batch phase-timing rows ──────────────────────────

(:wat::core::define
  (:trading::pulse/timing-rows
    (run-name :String)
    (batch-ts-ns :i64)
    (total-ns :i64)
    (next-ns :i64)
    (build-ns :i64)
    (flush-ns :i64)
    -> :Vec<trading::log::LogEntry>)
  (:wat::core::let*
    (((overhead-ns :i64)
      (:wat::core::- total-ns
        (:wat::core::+ next-ns
          (:wat::core::+ build-ns flush-ns)))))
    (:wat::core::vec :trading::log::LogEntry
      (:trading::pulse/metric "pulse.timing" run-name batch-ts-ns
        "total_ns" (:wat::core::i64::to-f64 total-ns) "Nanoseconds")
      (:trading::pulse/metric "pulse.timing" run-name batch-ts-ns
        "next_ns" (:wat::core::i64::to-f64 next-ns) "Nanoseconds")
      (:trading::pulse/metric "pulse.timing" run-name batch-ts-ns
        "build_ns" (:wat::core::i64::to-f64 build-ns) "Nanoseconds")
      (:trading::pulse/metric "pulse.timing" run-name batch-ts-ns
        "flush_ns" (:wat::core::i64::to-f64 flush-ns) "Nanoseconds")
      (:trading::pulse/metric "pulse.timing" run-name batch-ts-ns
        "overhead_ns" (:wat::core::i64::to-f64 overhead-ns) "Nanoseconds"))))


;; ─── Flush the batch through Sqlite (timed) ─────────────────────
;;
;; Returns the ns spent inside batch-log + ack so the walker can
;; charge it to `flush_ns`.

(:wat::core::define
  (:trading::pulse/flush
    (sqlite-tx :wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>)
    (ack-tx :wat::std::telemetry::Service::AckTx)
    (ack-rx :wat::std::telemetry::Service::AckRx)
    (batch :Vec<trading::log::LogEntry>)
    -> :i64)
  (:wat::core::let*
    (((t0 :wat::time::Instant) (:wat::time::now))
     ((_log :())
      (:wat::core::if (:wat::core::empty? batch) -> :()
        ()
        (:wat::std::telemetry::Service/batch-log
          sqlite-tx ack-tx ack-rx batch)))
     ((t1 :wat::time::Instant) (:wat::time::now)))
    (:wat::core::- (:wat::time::epoch-nanos t1)
                   (:wat::time::epoch-nanos t0))))


;; ─── Tail-recursive walker with phase-timing accumulators ───────
;;
;; Threads (n, batch, batch-start, t-next-ns, t-build-ns) through
;; the recursion. At batch boundary: emit close-rows + timing-rows
;; in one batch-log call; reset accumulators.

(:wat::core::define
  (:trading::pulse/walk
    (sqlite-tx :wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>)
    (ack-tx :wat::std::telemetry::Service::AckTx)
    (ack-rx :wat::std::telemetry::Service::AckRx)
    (logger :wat::std::telemetry::ConsoleLogger)
    (stream :trading::candles::Stream)
    (run-name :String)
    (batch-cap :i64)
    (n :i64)
    (batch :Vec<trading::log::LogEntry>)
    (batch-start :wat::time::Instant)
    (t-next-ns :i64)
    (t-build-ns :i64)
    -> :i64)
  (:wat::core::let*
    (;; Phase: next! the candle.
     ((t-n0 :wat::time::Instant) (:wat::time::now))
     ((maybe :Option<(i64,f64,f64,f64,f64,f64)>)
      (:trading::candles::next! stream))
     ((t-n1 :wat::time::Instant) (:wat::time::now))
     ((dt-next :i64)
      (:wat::core::- (:wat::time::epoch-nanos t-n1)
                     (:wat::time::epoch-nanos t-n0)))
     ((t-next-ns' :i64) (:wat::core::+ t-next-ns dt-next)))
    (:wat::core::match maybe -> :i64
      ((Some (ts-us _o _h _l close _v))
        (:wat::core::let*
          (;; Phase: build entry + Vec concat.
           ((t-b0 :wat::time::Instant) (:wat::time::now))
           ((entry :trading::log::LogEntry)
            (:trading::pulse/build-entry run-name ts-us close))
           ((batch' :Vec<trading::log::LogEntry>)
            (:wat::core::concat batch
              (:wat::core::vec :trading::log::LogEntry entry)))
           ((t-b1 :wat::time::Instant) (:wat::time::now))
           ((dt-build :i64)
            (:wat::core::- (:wat::time::epoch-nanos t-b1)
                           (:wat::time::epoch-nanos t-b0)))
           ((t-build-ns' :i64) (:wat::core::+ t-build-ns dt-build))
           ((n' :i64) (:wat::core::+ n 1))
           ((full :bool)
            (:wat::core::>= (:wat::core::length batch') batch-cap)))
          (:wat::core::if full -> :i64
            (:trading::pulse/walk-flush
              sqlite-tx ack-tx ack-rx logger stream run-name
              batch-cap n' batch'
              batch-start t-next-ns' t-build-ns')
            (:trading::pulse/walk
              sqlite-tx ack-tx ack-rx logger stream run-name
              batch-cap n' batch'
              batch-start t-next-ns' t-build-ns'))))
      (:None
        (:trading::pulse/walk-finalize
          sqlite-tx ack-tx ack-rx logger run-name
          n batch
          batch-start t-next-ns' t-build-ns)))))


;; ─── Mid-walk batch flush ───────────────────────────────────────
;;
;; Called when batch hits cap mid-stream. Flushes close-rows +
;; phase-timing rows; resets accumulators; recurses into walk.

(:wat::core::define
  (:trading::pulse/walk-flush
    (sqlite-tx :wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>)
    (ack-tx :wat::std::telemetry::Service::AckTx)
    (ack-rx :wat::std::telemetry::Service::AckRx)
    (logger :wat::std::telemetry::ConsoleLogger)
    (stream :trading::candles::Stream)
    (run-name :String)
    (batch-cap :i64)
    (n :i64)
    (batch :Vec<trading::log::LogEntry>)
    (batch-start :wat::time::Instant)
    (t-next-ns :i64)
    (t-build-ns :i64)
    -> :i64)
  (:wat::core::let*
    (((dt-flush :i64)
      (:trading::pulse/flush sqlite-tx ack-tx ack-rx batch))
     ((t-end :wat::time::Instant) (:wat::time::now))
     ((batch-ts-ns :i64) (:wat::time::epoch-nanos t-end))
     ((total-ns :i64)
      (:wat::core::- batch-ts-ns
                     (:wat::time::epoch-nanos batch-start)))
     ((timing :Vec<trading::log::LogEntry>)
      (:trading::pulse/timing-rows run-name batch-ts-ns
        total-ns t-next-ns t-build-ns dt-flush))
     ((dt-flush-2 :i64)
      (:trading::pulse/flush sqlite-tx ack-tx ack-rx timing))
     ((_hb :())
      (:wat::std::telemetry::ConsoleLogger/info logger
        (:trading::pulse::Tick::Heartbeat n))))
    (:trading::pulse/walk
      sqlite-tx ack-tx ack-rx logger stream run-name batch-cap n
      (:wat::core::vec :trading::log::LogEntry)
      t-end 0 0)))


;; ─── End-of-stream finalize ─────────────────────────────────────
;;
;; Flush remaining batch + final timing row + Stopped event.

(:wat::core::define
  (:trading::pulse/walk-finalize
    (sqlite-tx :wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>)
    (ack-tx :wat::std::telemetry::Service::AckTx)
    (ack-rx :wat::std::telemetry::Service::AckRx)
    (logger :wat::std::telemetry::ConsoleLogger)
    (run-name :String)
    (n :i64)
    (batch :Vec<trading::log::LogEntry>)
    (batch-start :wat::time::Instant)
    (t-next-ns :i64)
    (t-build-ns :i64)
    -> :i64)
  (:wat::core::let*
    (((dt-flush :i64)
      (:trading::pulse/flush sqlite-tx ack-tx ack-rx batch))
     ((t-end :wat::time::Instant) (:wat::time::now))
     ((batch-ts-ns :i64) (:wat::time::epoch-nanos t-end))
     ((total-ns :i64)
      (:wat::core::- batch-ts-ns
                     (:wat::time::epoch-nanos batch-start)))
     ((timing :Vec<trading::log::LogEntry>)
      (:trading::pulse/timing-rows run-name batch-ts-ns
        total-ns t-next-ns t-build-ns dt-flush))
     ((_2 :i64)
      (:trading::pulse/flush sqlite-tx ack-tx ack-rx timing))
     ((_stopped :())
      (:wat::std::telemetry::ConsoleLogger/info logger
        (:trading::pulse::Tick::Stopped n))))
    n))


;; ─── Inner scope ─────────────────────────────────────────────────

(:wat::core::define
  (:trading::pulse/inner
    (con-pool :wat::kernel::HandlePool<wat::std::service::Console::Handle>)
    (sqlite-pool :wat::std::telemetry::Service::ReqTxPool<trading::log::LogEntry>)
    (stream :trading::candles::Stream)
    (run-name :String)
    (planned :i64)
    -> :())
  (:wat::core::let*
    (((con-handle :wat::std::service::Console::Handle)
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
     ((logger :wat::std::telemetry::ConsoleLogger)
      (:wat::std::telemetry::ConsoleLogger/new
        con-handle :pulse
        (:wat::core::lambda ((_u :()) -> :wat::time::Instant)
          (:wat::time::now))
        :wat::std::telemetry::Console::Format::Edn))
     ((_started :())
      (:wat::std::telemetry::ConsoleLogger/info logger
        (:trading::pulse::Tick::Started run-name planned)))
     ((t-start :wat::time::Instant) (:wat::time::now))
     ((_n :i64)
      (:trading::pulse/walk
        sqlite-tx ack-tx ack-rx logger stream run-name 100 0
        (:wat::core::vec :trading::log::LogEntry)
        t-start 0 0)))
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
     ((sqlite-spawn :trading::telemetry::Spawn)
      (:trading::telemetry::Sqlite/spawn db-path 1
        (:wat::std::telemetry::Service/null-metrics-cadence)))
     ((sqlite-pool :wat::std::telemetry::Service::ReqTxPool<trading::log::LogEntry>)
      (:wat::core::first sqlite-spawn))
     ((sqlite-driver :wat::kernel::ProgramHandle<()>)
      (:wat::core::second sqlite-spawn))
     ((_inner :())
      (:trading::pulse/inner con-pool sqlite-pool stream run-name planned))
     ((_sqlite-join :()) (:wat::kernel::join sqlite-driver)))
    (:wat::kernel::join con-driver)))
