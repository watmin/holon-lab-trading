;; wat/programs/pulse.wat — candle-stream-as-pulse plumbing test.
;;
;; CIRCUIT.md: "the input stream is the pulse." This program reads a
;; bounded BTC candle stream, emits one `LogEntry::Telemetry` row per
;; candle to sqlite (batched), and a `Tick::Heartbeat` to console at
;; each batch boundary. NOTHING IS PROCESSED — no encoding, no
;; observers, no decisions. Pure plumbing: prove that
;;   (parquet → wat candle stream → producer thread →
;;     ConsoleLogger + Sqlite/auto-spawn → runs/<id>.{out,err,db})
;; works end-to-end on real candle data.
;;
;; Each subsequent producer (treasury, observers, gates) plugs into
;; this same shape: per-tick callback, batch-log every N ticks,
;; console heartbeat per batch.

(:wat::load-file! "run.wat")
(:wat::load-file! "../io/CandleStream.wat")
(:wat::load-file! "../io/log/LogEntry.wat")
(:wat::load-file! "../io/telemetry/Sqlite.wat")


;; ─── Domain enum for console output ─────────────────────────────

(:wat::core::enum :trading::pulse::Tick
  (Started   (run-name :String) (planned :i64))
  (Heartbeat (n :i64))
  (Stopped   (n :i64)))


;; ─── Build a Telemetry LogEntry from one candle ──────────────────
;;
;; Namespace = "pulse"; id = run-name (so SQL can filter per run);
;; metric-name = "close"; metric-value = the close price.
;; The candle's ts_us promotes to ns by *1000.

(:wat::core::define
  (:trading::pulse/build-entry
    (run-name :String)
    (ts-us :i64)
    (close :f64)
    -> :trading::log::LogEntry)
  (:trading::log::LogEntry::Telemetry
    "pulse" run-name "{}"
    (:wat::core::* ts-us 1000)
    "close" close "USD"))


;; ─── Flush the accumulated batch through Sqlite ──────────────────
;;
;; One ack roundtrip per batch. Empty batches are a no-op (the
;; substrate's Service/batch-log handles zero-length cleanly).

(:wat::core::define
  (:trading::pulse/flush
    (sqlite-tx :wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>)
    (ack-tx :wat::std::telemetry::Service::AckTx)
    (ack-rx :wat::std::telemetry::Service::AckRx)
    (batch :Vec<trading::log::LogEntry>)
    -> :())
  (:wat::core::if (:wat::core::empty? batch) -> :()
    ()
    (:wat::std::telemetry::Service/batch-log
      sqlite-tx ack-tx ack-rx batch)))


;; ─── Tail-recursive walker ───────────────────────────────────────
;;
;; Threads (n, batch) — when batch reaches batch-cap, flush +
;; heartbeat + reset. On end-of-stream, final flush + Stopped.
;; Per arc 003 TCO, named-define self-recursion runs in constant
;; stack depth.

(:wat::core::define
  (:trading::pulse/walk
    (logger :wat::std::telemetry::ConsoleLogger)
    (sqlite-tx :wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>)
    (ack-tx :wat::std::telemetry::Service::AckTx)
    (ack-rx :wat::std::telemetry::Service::AckRx)
    (stream :trading::candles::Stream)
    (run-name :String)
    (batch-cap :i64)
    (n :i64)
    (batch :Vec<trading::log::LogEntry>)
    -> :i64)
  (:wat::core::match (:trading::candles::next! stream) -> :i64
    ((Some (ts-us _o _h _l close _v))
      (:wat::core::let*
        (((entry :trading::log::LogEntry)
          (:trading::pulse/build-entry run-name ts-us close))
         ((batch' :Vec<trading::log::LogEntry>)
          (:wat::core::concat batch
            (:wat::core::vec :trading::log::LogEntry entry)))
         ((n' :i64) (:wat::core::+ n 1))
         ((full :bool)
          (:wat::core::>= (:wat::core::length batch') batch-cap)))
        (:wat::core::if full -> :i64
          (:wat::core::let*
            (((_flush :())
              (:trading::pulse/flush sqlite-tx ack-tx ack-rx batch'))
             ((_hb :())
              (:wat::std::telemetry::ConsoleLogger/info logger
                (:trading::pulse::Tick::Heartbeat n'))))
            (:trading::pulse/walk
              logger sqlite-tx ack-tx ack-rx
              stream run-name batch-cap n'
              (:wat::core::vec :trading::log::LogEntry)))
          (:trading::pulse/walk
            logger sqlite-tx ack-tx ack-rx
            stream run-name batch-cap n' batch'))))
    (:None
      (:wat::core::let*
        (((_flush :())
          (:trading::pulse/flush sqlite-tx ack-tx ack-rx batch))
         ((_stopped :())
          (:wat::std::telemetry::ConsoleLogger/info logger
            (:trading::pulse::Tick::Stopped n))))
        n))))


;; ─── Inner scope — pop handles, build logger, run walker ─────────

(:wat::core::define
  (:trading::pulse/inner
    (con-pool :wat::kernel::HandlePool<wat::std::service::Console::Tx>)
    (sqlite-pool :wat::std::telemetry::Service::ReqTxPool<trading::log::LogEntry>)
    (stream :trading::candles::Stream)
    (run-name :String)
    (planned :i64)
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
     ((logger :wat::std::telemetry::ConsoleLogger)
      (:wat::std::telemetry::ConsoleLogger/new
        con-tx :pulse
        (:wat::core::lambda ((_u :()) -> :wat::time::Instant)
          (:wat::time::now))
        :wat::std::telemetry::Console::Format::Edn))
     ((_started :())
      (:wat::std::telemetry::ConsoleLogger/info logger
        (:trading::pulse::Tick::Started run-name planned)))
     ((_n :i64)
      (:trading::pulse/walk
        logger sqlite-tx ack-tx ack-rx
        stream run-name 100 0
        (:wat::core::vec :trading::log::LogEntry))))
    ()))


;; ─── :user::main wiring — outer scope ───────────────────────────

(:wat::core::define
  (:trading::pulse/main
    (_stdin  :wat::io::IOReader)
    (_stdout :wat::io::IOWriter)
    (_stderr :wat::io::IOWriter)
    -> :())
  (:wat::core::let*
    (((paths :trading::run::Paths)
      (:trading::run/paths/make "pulse" (:wat::time::now)))
     ((out-path :String) (:trading::run::Paths/out paths))
     ((err-path :String) (:trading::run::Paths/err paths))
     ((db-path  :String) (:trading::run::Paths/db  paths))
     ((run-name :String) db-path)

     ;; File-backed Console writers.
     ((out-writer :wat::io::IOWriter)
      (:wat::io::IOWriter/open-file out-path))
     ((err-writer :wat::io::IOWriter)
      (:wat::io::IOWriter/open-file err-path))

     ;; Bounded candle stream — first 1000 candles, just to prove
     ;; the wires. Increase or remove the cap when the trader is
     ;; running real backtests.
     ((planned :i64) 1000)
     ((stream :trading::candles::Stream)
      (:trading::candles::open-bounded "data/btc_5m_raw.parquet" planned))

     ;; Spawn Console (count=1) — single producer for now.
     ((con-spawn :wat::std::service::Console::Spawn)
      (:wat::std::service::Console/spawn out-writer err-writer 1))
     ((con-pool :wat::kernel::HandlePool<wat::std::service::Console::Tx>)
      (:wat::core::first con-spawn))
     ((con-driver :wat::kernel::ProgramHandle<()>)
      (:wat::core::second con-spawn))

     ;; Spawn Sqlite/auto-spawn (count=1, null-cadence).
     ((sqlite-spawn :trading::telemetry::Spawn)
      (:trading::telemetry::Sqlite/spawn db-path 1
        (:wat::std::telemetry::Service/null-metrics-cadence)))
     ((sqlite-pool :wat::std::telemetry::Service::ReqTxPool<trading::log::LogEntry>)
      (:wat::core::first sqlite-spawn))
     ((sqlite-driver :wat::kernel::ProgramHandle<()>)
      (:wat::core::second sqlite-spawn))

     ;; Inner runs the walker. On return, all handles drop.
     ((_inner :())
      (:trading::pulse/inner con-pool sqlite-pool stream run-name planned))

     ((_sqlite-join :()) (:wat::kernel::join sqlite-driver)))
    (:wat::kernel::join con-driver)))
