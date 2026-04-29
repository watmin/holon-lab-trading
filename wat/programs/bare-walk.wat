;; wat/programs/bare-walk.wat — minimum pulse for bottleneck bisection.
;;
;; Walks the candle stream in pure wat. NO build-entry. NO Vec concat.
;; NO batch-log. NO console heartbeat. Just `next!` + tail-recurse +
;; counter. Emits one Stopped event at end.
;;
;; Runtime delta vs. pulse.wat at the same N tells us how much time
;; goes into "everything other than walking the stream":
;;   bare_t      = next! + match + tail-recurse  (minimum)
;;   pulse_t     = bare_t + build-entry + Vec concat + batch-log + console
;;   pulse - bare = the cost of accumulation + logging per candle

(:wat::load-file! "run.wat")
(:wat::load-file! "../io/CandleStream.wat")
(:wat::load-file! "../io/log/LogEntry.wat")
(:wat::load-file! "../io/telemetry/Sqlite.wat")


(:wat::core::enum :trading::bare::Tick
  (Started   (run-name :String) (planned :i64))
  (Stopped   (n :i64)))


;; Bare walk — pure tail recursion over next!. Counter only.
(:wat::core::define
  (:trading::bare/walk
    (stream :trading::candles::Stream)
    (n :i64)
    -> :i64)
  (:wat::core::match (:trading::candles::next! stream) -> :i64
    ((Some _candle)
      (:trading::bare/walk stream (:wat::core::+ n 1)))
    (:None n)))


(:wat::core::define
  (:trading::bare/inner
    (con-pool :wat::kernel::HandlePool<wat::std::service::Console::Handle>)
    (stream :trading::candles::Stream)
    (run-name :String)
    (planned :i64)
    -> :())
  (:wat::core::let*
    (((con-handle :wat::std::service::Console::Handle)
      (:wat::kernel::HandlePool::pop con-pool))
     ((_finish-con :()) (:wat::kernel::HandlePool::finish con-pool))
     ((logger :wat::std::telemetry::ConsoleLogger)
      (:wat::std::telemetry::ConsoleLogger/new
        con-handle :bare
        (:wat::core::lambda ((_u :()) -> :wat::time::Instant)
          (:wat::time::now))
        :wat::std::telemetry::Console::Format::Edn))
     ((_started :())
      (:wat::std::telemetry::ConsoleLogger/info logger
        (:trading::bare::Tick::Started run-name planned)))
     ((t-start :wat::time::Instant) (:wat::time::now))
     ((n :i64) (:trading::bare/walk stream 0))
     ((t-end :wat::time::Instant) (:wat::time::now))
     ((wall-ns :i64)
      (:wat::core::- (:wat::time::epoch-nanos t-end)
                     (:wat::time::epoch-nanos t-start)))
     ((_stopped :())
      (:wat::std::telemetry::ConsoleLogger/info logger
        (:trading::bare::Tick::Stopped n))))
    ;; Print wall_ns to stdout via console for visibility.
    (:wat::std::service::Console/out con-handle
      (:wat::core::string::concat
        "BARE WALK: " (:wat::core::string::concat
          (:wat::core::i64::to-string n)
          (:wat::core::string::concat
            " candles in "
            (:wat::core::string::concat
              (:wat::core::i64::to-string wall-ns)
              " ns\n")))))))


(:wat::core::define
  (:trading::bare/main
    (_stdin  :wat::io::IOReader)
    (_stdout :wat::io::IOWriter)
    (_stderr :wat::io::IOWriter)
    -> :())
  (:wat::core::let*
    (((paths :trading::run::Paths)
      (:trading::run/paths/make "bare" (:wat::time::now)))
     ((out-writer :wat::io::IOWriter)
      (:wat::io::IOWriter/open-file (:trading::run::Paths/out paths)))
     ((err-writer :wat::io::IOWriter)
      (:wat::io::IOWriter/open-file (:trading::run::Paths/err paths)))
     ((planned :i64) 1000)
     ((stream :trading::candles::Stream)
      (:trading::candles::open-bounded "data/btc_5m_raw.parquet" planned))
     ((con-spawn :wat::std::service::Console::Spawn)
      (:wat::std::service::Console/spawn out-writer err-writer 1))
     ((con-pool :wat::kernel::HandlePool<wat::std::service::Console::Handle>)
      (:wat::core::first con-spawn))
     ((con-driver :wat::kernel::ProgramHandle<()>)
      (:wat::core::second con-spawn))
     ((_inner :())
      (:trading::bare/inner con-pool stream
        (:trading::run::Paths/db paths)
        planned)))
    (:wat::kernel::join con-driver)))
