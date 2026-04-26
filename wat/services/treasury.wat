;; wat/services/treasury.wat — :trading::treasury::Service.
;;
;; Lab experiment 008 (2026-04-26). The Treasury runs as a wat
;; program: one driver thread, one Treasury value, N+1 receivers
;; (1 for ticks + N for brokers), per-broker response queues.
;;
;; ── Per Proposal 048 — "the pipe IS the identity" ────────────────
;;
;; Brokers each get their own (ReqTx, RespRx) handle. The driver's
;; select returns (idx, event); the idx tells the driver which
;; response queue to use. NO client-id field in the Event variants
;; — the wiring carries the routing, not the data.
;;
;; Per-channel discipline:
;;   - Tick channel — write-only (no response)
;;   - Broker channels — request/response (per-caller dedicated
;;     pipe; response on resp-txs[idx-1] when broker request fires)
;;
;; ── Per arc 029 + arc 030 slice 1 ────────────────────────────────
;;
;; Treasury emits per-Tick LogEntry::Telemetry batch via the rundb
;; service (one Service/batch-log call per Tick). Per arc 030 Q7,
;; the Tick rhythm IS the rate gate — no separate make-rate-gate.
;;
;; ── Per the kill-the-mailbox direction ──────────────────────────
;;
;; No mailbox proxy thread. Driver owns Vec<Receiver<Event>> and
;; runs :wat::kernel::select inline. Same shape as RunDbService /
;; CacheService / Console.
;;
;; ── Lifecycle ────────────────────────────────────────────────────
;;
;;   1. Caller (Service rundb-req-tx rundb-ack-tx rundb-ack-rx
;;              entry-fee exit-fee initial-balances broker-count)
;;      → returns (HandlePool<BrokerHandle>, TickTx, ProgramHandle).
;;   2. Driver opens nothing; constructs Treasury via Treasury::fresh
;;      inside its own thread; enters select loop.
;;   3. Caller pops BrokerHandles, distributes to brokers, calls
;;      HandlePool::finish.
;;   4. Main loop sends Tick events via tick-tx; brokers send
;;      requests via their req-tx and recv via their resp-rx.
;;   5. Brokers + main loop drop their senders. Last drop disconnects
;;      the driver's last receiver; loop exits; treasury value drops
;;      (no resources held). Caller (join driver) confirms exit.

(:wat::load-file! "../treasury/types.wat")
(:wat::load-file! "../treasury/treasury.wat")
(:wat::load-file! "../io/log/LogEntry.wat")
(:wat::load-file! "../io/log/telemetry.wat")
(:wat::load-file! "../io/RunDbService.wat")


;; ─── Protocol — Event + Response enums ──────────────────────────

;; Single sum type carried by ALL N+1 channels (tick + brokers).
;; Tick variant ONLY arrives on the tick channel; broker request
;; variants ONLY arrive on their own broker channel. The driver's
;; select-idx tells which channel; the variant tells what to do.
;; No client-id field anywhere — the pipe IS the identity.
(:wat::core::enum :trading::treasury::Service::Event
  (Tick (candle :i64) (price :f64))
  (SubmitPaper (from-asset :String) (to-asset :String) (price :f64))
  (SubmitReal  (from-asset :String) (to-asset :String) (price :f64))
  (SubmitExit  (paper-id :i64) (current-price :f64))
  (BatchGetPaperStates (paper-ids :Vec<i64>)))

;; Broker → Treasury: response variants. Each broker request gets
;; exactly one Response back on its dedicated resp-rx (per-caller
;; pipe per Proposal 048). Tick events don't generate responses.
;;
;; Single Response enum (vs one type per request) — keeps the
;; client helper signatures uniform: each Service/<verb> sends an
;; Event variant + recv's a Response variant + matches the expected
;; one out.
(:wat::core::enum :trading::treasury::Service::Response
  (PaperIssued (receipt :trading::treasury::Receipt))
  (RealIssued  (maybe-receipt :Option<trading::treasury::Receipt>))
  (ExitResolved (maybe-verdict :Option<trading::treasury::Verdict>))
  (PaperStates (states :Vec<(i64,Option<trading::treasury::PositionState>)>)))


;; ─── Channel typealiases ────────────────────────────────────────

(:wat::core::typealias :trading::treasury::Service::EventTx
  :rust::crossbeam_channel::Sender<trading::treasury::Service::Event>)
(:wat::core::typealias :trading::treasury::Service::EventRx
  :rust::crossbeam_channel::Receiver<trading::treasury::Service::Event>)
(:wat::core::typealias :trading::treasury::Service::EventChannel
  :(trading::treasury::Service::EventTx,trading::treasury::Service::EventRx))

(:wat::core::typealias :trading::treasury::Service::RespTx
  :rust::crossbeam_channel::Sender<trading::treasury::Service::Response>)
(:wat::core::typealias :trading::treasury::Service::RespRx
  :rust::crossbeam_channel::Receiver<trading::treasury::Service::Response>)
(:wat::core::typealias :trading::treasury::Service::RespChannel
  :(trading::treasury::Service::RespTx,trading::treasury::Service::RespRx))


;; ─── Per-broker handle — what each broker receives from the pool ──
;;
;; Tuple of (req-tx, resp-rx). Broker sends events on req-tx,
;; recvs responses on resp-rx. The corresponding (resp-tx, req-rx)
;; live with the driver — driver routes responses by select-idx.
(:wat::core::typealias :trading::treasury::Service::BrokerHandle
  :(trading::treasury::Service::EventTx,trading::treasury::Service::RespRx))


;; ─── Slot — per-receiver routing identity ───────────────────────
;;
;; Parallel Vec<Slot> tracks WHICH receiver in rxs corresponds to
;; what — kept in lockstep with the Vec<EventRx> the driver selects
;; over. On a `:None` (channel disconnect) we remove BOTH slots[idx]
;; and rxs[idx] together so the parallel mapping stays correct.
;;
;; Tick variant: no response needed. Broker variant: carries the
;; resp-tx so the driver can answer.
(:wat::core::enum :trading::treasury::Service::Slot
  :Tick
  (Broker (resp-tx :trading::treasury::Service::RespTx)))


;; ─── Spawn return type ──────────────────────────────────────────
;;
;; What `(:trading::treasury::Service ...)` returns:
;;   - Pool of N BrokerHandle (req-tx, resp-rx) tuples
;;   - The TickTx (separate; main loop holds this — NOT pooled)
;;   - Driver ProgramHandle (caller (join) on shutdown)
(:wat::core::typealias :trading::treasury::Service::BrokerHandlePool
  :wat::kernel::HandlePool<trading::treasury::Service::BrokerHandle>)

(:wat::core::typealias :trading::treasury::Service::Spawn
  :(trading::treasury::Service::BrokerHandlePool,trading::treasury::Service::EventTx,wat::kernel::ProgramHandle<()>))


;; ─── Telemetry helpers ──────────────────────────────────────────

;; Build the per-Tick telemetry batch — three rows.
;; Mirrors archive's treasury_program.rs metric pattern.
(:wat::core::define
  (:trading::treasury::Service/build-tick-telemetry
    (treasury :trading::treasury::Treasury)
    (candle :i64)
    (ns-tick :i64)
    (ns-emit :i64)
    (timestamp-ns :i64)
    -> :Vec<trading::log::LogEntry>)
  (:wat::core::let*
    (((active :i64)
      (:trading::treasury::Treasury::active-paper-count treasury))
     ((dims :String)
      (:wat::core::string::concat
        "{\"candle\":"
        (:wat::core::string::concat
          (:wat::core::i64::to-string candle) "}")))
     ((id :String)
      (:wat::core::string::concat
        "treasury:tick:" (:wat::core::i64::to-string candle))))
    (:wat::core::vec :trading::log::LogEntry
      (:trading::log::emit-metric
        "treasury" id dims timestamp-ns
        "active_papers" (:wat::core::i64::to-f64 active) "Count")
      (:trading::log::emit-metric
        "treasury" id dims timestamp-ns
        "ns_tick" (:wat::core::i64::to-f64 ns-tick) "Nanoseconds")
      (:trading::log::emit-metric
        "treasury" id dims timestamp-ns
        "ns_emit" (:wat::core::i64::to-f64 ns-emit) "Nanoseconds"))))


;; Build the per-Request telemetry — one row.
(:wat::core::define
  (:trading::treasury::Service/build-request-telemetry
    (broker-idx :i64)
    (request-name :String)
    (ns-request :i64)
    (timestamp-ns :i64)
    -> :Vec<trading::log::LogEntry>)
  (:wat::core::let*
    (((dims :String)
      (:wat::core::string::concat
        "{\"broker\":"
        (:wat::core::string::concat
          (:wat::core::i64::to-string broker-idx) "}")))
     ((id :String)
      (:wat::core::string::concat
        "treasury:req:"
        (:wat::core::string::concat
          (:wat::core::i64::to-string broker-idx)
          (:wat::core::string::concat ":" request-name)))))
    (:wat::core::vec :trading::log::LogEntry
      (:trading::log::emit-metric
        "treasury" id dims timestamp-ns
        "ns_request" (:wat::core::i64::to-f64 ns-request) "Nanoseconds"))))


;; ─── Event handlers — one per Event variant ─────────────────────
;;
;; Each takes Treasury + the event payload + the slot's resp-tx
;; (where applicable) + rundb handles for telemetry. Returns the
;; updated Treasury. Telemetry batched + flushed inline.

;; Broker request → handle + send response on resp-tx + emit metric.
(:wat::core::define
  (:trading::treasury::Service/handle-broker-request
    (treasury :trading::treasury::Treasury)
    (event :trading::treasury::Service::Event)
    (resp-tx :trading::treasury::Service::RespTx)
    (broker-idx :i64)
    (rundb-req-tx :trading::rundb::Service::ReqTx)
    (rundb-ack-tx :trading::rundb::Service::AckTx)
    (rundb-ack-rx :trading::rundb::Service::AckRx)
    -> :trading::treasury::Treasury)
  (:wat::core::let*
    (((t-start :wat::time::Instant) (:wat::time::now))
     ((result :(trading::treasury::Treasury,trading::treasury::Service::Response,String))
      (:wat::core::match event
        -> :(trading::treasury::Treasury,trading::treasury::Service::Response,String)
        ((:trading::treasury::Service::Event::SubmitPaper from-asset to-asset price)
          (:wat::core::let*
            (((tup :(trading::treasury::Treasury,trading::treasury::Receipt))
              (:trading::treasury::Treasury::issue-paper
                treasury broker-idx from-asset to-asset price 0 288))
             ;; NB: candle=0 in v1 — Treasury doesn't currently track
             ;; "current candle" between Ticks. 009+ wires this through.
             ((t' :trading::treasury::Treasury) (:wat::core::first tup))
             ((receipt :trading::treasury::Receipt) (:wat::core::second tup))
             ((resp :trading::treasury::Service::Response)
              (:trading::treasury::Service::Response::PaperIssued receipt)))
            (:wat::core::tuple t' resp "submit-paper")))
        ((:trading::treasury::Service::Event::SubmitReal from-asset to-asset price)
          (:wat::core::let*
            (((tup :(trading::treasury::Treasury,Option<trading::treasury::Receipt>))
              (:trading::treasury::Treasury::issue-real
                treasury broker-idx from-asset to-asset price 0 288))
             ((t' :trading::treasury::Treasury) (:wat::core::first tup))
             ((maybe-receipt :Option<trading::treasury::Receipt>) (:wat::core::second tup))
             ((resp :trading::treasury::Service::Response)
              (:trading::treasury::Service::Response::RealIssued maybe-receipt)))
            (:wat::core::tuple t' resp "submit-real")))
        ((:trading::treasury::Service::Event::SubmitExit paper-id current-price)
          (:wat::core::let*
            (((tup :(trading::treasury::Treasury,Option<trading::treasury::Verdict>))
              (:trading::treasury::Treasury::resolve-grace
                treasury paper-id current-price))
             ((t' :trading::treasury::Treasury) (:wat::core::first tup))
             ((maybe-verdict :Option<trading::treasury::Verdict>) (:wat::core::second tup))
             ((resp :trading::treasury::Service::Response)
              (:trading::treasury::Service::Response::ExitResolved maybe-verdict)))
            (:wat::core::tuple t' resp "submit-exit")))
        ((:trading::treasury::Service::Event::BatchGetPaperStates paper-ids)
          (:wat::core::let*
            (((states :Vec<(i64,Option<trading::treasury::PositionState>)>)
              (:wat::core::map paper-ids
                (:wat::core::lambda
                  ((id :i64) -> :(i64,Option<trading::treasury::PositionState>))
                  (:wat::core::tuple id
                    (:wat::core::match
                      (:wat::core::get
                        (:trading::treasury::Treasury/papers treasury) id)
                      -> :Option<trading::treasury::PositionState>
                      ((Some p) (Some (:trading::treasury::Paper/state p)))
                      (:None :None))))))
             ((resp :trading::treasury::Service::Response)
              (:trading::treasury::Service::Response::PaperStates states)))
            (:wat::core::tuple treasury resp "batch-get-paper-states")))
        ;; Tick variant should never reach this handler (slot is Broker).
        ;; Build a sentinel response + return treasury unchanged.
        (_
          (:wat::core::tuple treasury
            (:trading::treasury::Service::Response::PaperStates
              (:wat::core::vec :(i64,Option<trading::treasury::PositionState>)))
            "unknown"))))
     ((t' :trading::treasury::Treasury) (:wat::core::first result))
     ((resp :trading::treasury::Service::Response) (:wat::core::second result))
     ((req-name :String) (:wat::core::third result))
     ;; Send response (best-effort; broker may have raced shutdown).
     ((_send :Option<()>) (:wat::kernel::send resp-tx resp))
     ;; Emit per-request metric.
     ((t-end :wat::time::Instant) (:wat::time::now))
     ((ns-request :i64)
      (:wat::core::- (:wat::time::epoch-nanos t-end)
                     (:wat::time::epoch-nanos t-start)))
     ((ts-ns :i64) (:wat::time::epoch-nanos t-end))
     ((entries :Vec<trading::log::LogEntry>)
      (:trading::treasury::Service/build-request-telemetry
        broker-idx req-name ns-request ts-ns))
     ((_log :())
      (:trading::rundb::Service/batch-log
        rundb-req-tx rundb-ack-tx rundb-ack-rx entries)))
    t'))

;; Tick → check-deadlines + emit batch.
(:wat::core::define
  (:trading::treasury::Service/handle-tick
    (treasury :trading::treasury::Treasury)
    (candle :i64)
    (price :f64)
    (rundb-req-tx :trading::rundb::Service::ReqTx)
    (rundb-ack-tx :trading::rundb::Service::AckTx)
    (rundb-ack-rx :trading::rundb::Service::AckRx)
    -> :trading::treasury::Treasury)
  (:wat::core::let*
    (((t-start :wat::time::Instant) (:wat::time::now))
     ((tup :(trading::treasury::Treasury,trading::treasury::Verdicts))
      (:trading::treasury::Treasury::check-deadlines treasury candle price))
     ((t' :trading::treasury::Treasury) (:wat::core::first tup))
     ;; verdicts vec discarded for v1 — a future arc routes them
     ;; back to the brokers that owned the violenced papers.
     ((_verdicts :trading::treasury::Verdicts) (:wat::core::second tup))
     ((t-after-tick :wat::time::Instant) (:wat::time::now))
     ((ns-tick :i64)
      (:wat::core::- (:wat::time::epoch-nanos t-after-tick)
                     (:wat::time::epoch-nanos t-start)))
     ((ts-ns :i64) (:wat::time::epoch-nanos t-after-tick))
     ((entries :Vec<trading::log::LogEntry>)
      (:trading::treasury::Service/build-tick-telemetry
        t' candle ns-tick 0 ts-ns))
     ;; ns-emit measured AFTER the entries are built so it captures
     ;; the build cost itself; close enough for v1.
     ((_log :())
      (:trading::rundb::Service/batch-log
        rundb-req-tx rundb-ack-tx rundb-ack-rx entries)))
    t'))


;; ─── Driver — recursive select loop ─────────────────────────────
;;
;; Mirrors RunDbService/loop's select-and-remove pattern. Walks
;; rxs + parallel slots in lockstep; on disconnect removes BOTH
;; at the same idx; on Some(event) dispatches by slot variant.
;;
;; broker-idx-of-slot — given a Slot, returns the broker index
;; (for telemetry dimensions). For Tick slots: -1 (sentinel).
(:wat::core::define
  (:trading::treasury::Service/loop
    (treasury :trading::treasury::Treasury)
    (rxs :Vec<trading::treasury::Service::EventRx>)
    (slots :Vec<trading::treasury::Service::Slot>)
    (broker-indices :Vec<i64>)
    (rundb-req-tx :trading::rundb::Service::ReqTx)
    (rundb-ack-tx :trading::rundb::Service::AckTx)
    (rundb-ack-rx :trading::rundb::Service::AckRx)
    -> :())
  (:wat::core::if (:wat::core::empty? rxs) -> :()
    ()
    (:wat::core::let*
      (((chosen :(i64,Option<trading::treasury::Service::Event>))
        (:wat::kernel::select rxs))
       ((idx :i64) (:wat::core::first chosen))
       ((maybe :Option<trading::treasury::Service::Event>)
        (:wat::core::second chosen)))
      (:wat::core::match maybe -> :()
        ((Some event)
          (:wat::core::let*
            (((slot :trading::treasury::Service::Slot)
              (:wat::core::match (:wat::core::get slots idx)
                -> :trading::treasury::Service::Slot
                ((Some s) s)
                ;; Unreachable — slots and rxs maintained in lockstep.
                (:None :trading::treasury::Service::Slot::Tick)))
             ((treasury' :trading::treasury::Treasury)
              (:wat::core::match slot -> :trading::treasury::Treasury
                (:trading::treasury::Service::Slot::Tick
                  (:wat::core::match event -> :trading::treasury::Treasury
                    ((:trading::treasury::Service::Event::Tick candle price)
                      (:trading::treasury::Service/handle-tick
                        treasury candle price
                        rundb-req-tx rundb-ack-tx rundb-ack-rx))
                    ;; Tick slot received non-Tick event — bug; skip.
                    (_ treasury)))
                ((:trading::treasury::Service::Slot::Broker resp-tx)
                  (:wat::core::let*
                    (((broker-idx :i64)
                      (:wat::core::match (:wat::core::get broker-indices idx)
                        -> :i64
                        ((Some i) i)
                        (:None -1))))
                    (:trading::treasury::Service/handle-broker-request
                      treasury event resp-tx broker-idx
                      rundb-req-tx rundb-ack-tx rundb-ack-rx))))))
            (:trading::treasury::Service/loop
              treasury' rxs slots broker-indices
              rundb-req-tx rundb-ack-tx rundb-ack-rx)))
        (:None
          ;; Receiver disconnected — remove the rx + slot + broker-idx
          ;; at this position in lockstep. Recurse on the trimmed vecs.
          (:trading::treasury::Service/loop
            treasury
            (:wat::std::list::remove-at rxs idx)
            (:wat::std::list::remove-at slots idx)
            (:wat::std::list::remove-at broker-indices idx)
            rundb-req-tx rundb-ack-tx rundb-ack-rx))))))


;; ─── Driver entry — constructs Treasury inside its thread ───────
;;
;; Per-thread-owned discipline (LocalCache and similar): the
;; Treasury VALUE itself is just data so it can technically cross
;; threads, but this matches the existing service template
;; (CacheService/loop-entry constructs LocalCache::new inside the
;; driver). Keeps lifecycle uniform.
(:wat::core::define
  (:trading::treasury::Service/loop-entry
    (entry-fee :f64)
    (exit-fee :f64)
    (initial-balances :trading::treasury::Balances)
    (tick-rx :trading::treasury::Service::EventRx)
    (broker-rxs :Vec<trading::treasury::Service::EventRx>)
    (broker-resp-txs :Vec<trading::treasury::Service::RespTx>)
    (rundb-req-tx :trading::rundb::Service::ReqTx)
    (rundb-ack-tx :trading::rundb::Service::AckTx)
    (rundb-ack-rx :trading::rundb::Service::AckRx)
    -> :())
  (:wat::core::let*
    (((treasury :trading::treasury::Treasury)
      (:trading::treasury::Treasury::fresh entry-fee exit-fee initial-balances))
     ;; Build rxs vec with tick at idx 0, brokers at 1..N.
     ((rxs :Vec<trading::treasury::Service::EventRx>)
      (:wat::core::concat
        (:wat::core::vec :trading::treasury::Service::EventRx tick-rx)
        broker-rxs))
     ;; Parallel slots vec.
     ((tick-slot :trading::treasury::Service::Slot)
      :trading::treasury::Service::Slot::Tick)
     ((broker-slots :Vec<trading::treasury::Service::Slot>)
      (:wat::core::map broker-resp-txs
        (:wat::core::lambda
          ((tx :trading::treasury::Service::RespTx)
           -> :trading::treasury::Service::Slot)
          (:trading::treasury::Service::Slot::Broker tx))))
     ((slots :Vec<trading::treasury::Service::Slot>)
      (:wat::core::concat
        (:wat::core::vec :trading::treasury::Service::Slot tick-slot)
        broker-slots))
     ;; Parallel broker-indices vec — idx in rxs → broker index.
     ;; Tick slot has -1 sentinel; brokers are 0..N-1.
     ((n :i64) (:wat::core::length broker-rxs))
     ((broker-indices :Vec<i64>)
      (:wat::core::concat
        (:wat::core::vec :i64 -1)
        (:wat::core::range 0 n))))
    (:trading::treasury::Service/loop
      treasury rxs slots broker-indices
      rundb-req-tx rundb-ack-tx rundb-ack-rx)))


;; ─── Client helpers — broker-side ───────────────────────────────
;;
;; Each broker holds one BrokerHandle (req-tx + resp-rx tuple).
;; These wrappers send the Event variant + recv the Response +
;; pattern-match the expected variant out.

(:wat::core::define
  (:trading::treasury::Service/submit-paper
    (handle :trading::treasury::Service::BrokerHandle)
    (from-asset :String) (to-asset :String) (price :f64)
    -> :Option<trading::treasury::Receipt>)
  (:wat::core::let*
    (((req-tx :trading::treasury::Service::EventTx) (:wat::core::first handle))
     ((resp-rx :trading::treasury::Service::RespRx) (:wat::core::second handle))
     ((event :trading::treasury::Service::Event)
      (:trading::treasury::Service::Event::SubmitPaper from-asset to-asset price))
     ((_send :Option<()>) (:wat::kernel::send req-tx event)))
    (:wat::core::match (:wat::kernel::recv resp-rx)
      -> :Option<trading::treasury::Receipt>
      ((Some (:trading::treasury::Service::Response::PaperIssued r)) (Some r))
      (_ :None))))

(:wat::core::define
  (:trading::treasury::Service/submit-real
    (handle :trading::treasury::Service::BrokerHandle)
    (from-asset :String) (to-asset :String) (price :f64)
    -> :Option<trading::treasury::Receipt>)
  (:wat::core::let*
    (((req-tx :trading::treasury::Service::EventTx) (:wat::core::first handle))
     ((resp-rx :trading::treasury::Service::RespRx) (:wat::core::second handle))
     ((event :trading::treasury::Service::Event)
      (:trading::treasury::Service::Event::SubmitReal from-asset to-asset price))
     ((_send :Option<()>) (:wat::kernel::send req-tx event)))
    (:wat::core::match (:wat::kernel::recv resp-rx)
      -> :Option<trading::treasury::Receipt>
      ((Some (:trading::treasury::Service::Response::RealIssued mr)) mr)
      (_ :None))))

(:wat::core::define
  (:trading::treasury::Service/submit-exit
    (handle :trading::treasury::Service::BrokerHandle)
    (paper-id :i64) (current-price :f64)
    -> :Option<trading::treasury::Verdict>)
  (:wat::core::let*
    (((req-tx :trading::treasury::Service::EventTx) (:wat::core::first handle))
     ((resp-rx :trading::treasury::Service::RespRx) (:wat::core::second handle))
     ((event :trading::treasury::Service::Event)
      (:trading::treasury::Service::Event::SubmitExit paper-id current-price))
     ((_send :Option<()>) (:wat::kernel::send req-tx event)))
    (:wat::core::match (:wat::kernel::recv resp-rx)
      -> :Option<trading::treasury::Verdict>
      ((Some (:trading::treasury::Service::Response::ExitResolved mv)) mv)
      (_ :None))))

(:wat::core::define
  (:trading::treasury::Service/batch-get-paper-states
    (handle :trading::treasury::Service::BrokerHandle)
    (paper-ids :Vec<i64>)
    -> :Vec<(i64,Option<trading::treasury::PositionState>)>)
  (:wat::core::let*
    (((req-tx :trading::treasury::Service::EventTx) (:wat::core::first handle))
     ((resp-rx :trading::treasury::Service::RespRx) (:wat::core::second handle))
     ((event :trading::treasury::Service::Event)
      (:trading::treasury::Service::Event::BatchGetPaperStates paper-ids))
     ((_send :Option<()>) (:wat::kernel::send req-tx event)))
    (:wat::core::match (:wat::kernel::recv resp-rx)
      -> :Vec<(i64,Option<trading::treasury::PositionState>)>
      ((Some (:trading::treasury::Service::Response::PaperStates states)) states)
      (_ (:wat::core::vec :(i64,Option<trading::treasury::PositionState>))))))


;; ─── Setup — spawns the driver, returns Spawn tuple ─────────────
;;
;; Builds: 1 tick channel pair, N broker request channel pairs,
;; N broker response channel pairs, the BrokerHandle pool (zips
;; the broker req-txs with resp-rxs into N tuples), spawns the
;; driver thread with its receiver-side handles + the Treasury
;; constructor params + the rundb telemetry handles.
;;
;; Returns (HandlePool<BrokerHandle>, TickTx, ProgramHandle).
(:wat::core::define
  (:trading::treasury::Service
    (rundb-req-tx :trading::rundb::Service::ReqTx)
    (rundb-ack-tx :trading::rundb::Service::AckTx)
    (rundb-ack-rx :trading::rundb::Service::AckRx)
    (entry-fee :f64)
    (exit-fee :f64)
    (initial-balances :trading::treasury::Balances)
    (broker-count :i64)
    -> :trading::treasury::Service::Spawn)
  (:wat::core::let*
    ;; Tick channel — 1 pair.
    (((tick-pair :trading::treasury::Service::EventChannel)
      (:wat::kernel::make-bounded-queue
        :trading::treasury::Service::Event 1))
     ((tick-tx :trading::treasury::Service::EventTx)
      (:wat::core::first tick-pair))
     ((tick-rx :trading::treasury::Service::EventRx)
      (:wat::core::second tick-pair))

     ;; Broker request channels — N pairs.
     ((req-pairs :Vec<trading::treasury::Service::EventChannel>)
      (:wat::core::map (:wat::core::range 0 broker-count)
        (:wat::core::lambda
          ((_i :i64) -> :trading::treasury::Service::EventChannel)
          (:wat::kernel::make-bounded-queue
            :trading::treasury::Service::Event 1))))
     ((req-txs :Vec<trading::treasury::Service::EventTx>)
      (:wat::core::map req-pairs
        (:wat::core::lambda
          ((p :trading::treasury::Service::EventChannel)
           -> :trading::treasury::Service::EventTx)
          (:wat::core::first p))))
     ((req-rxs :Vec<trading::treasury::Service::EventRx>)
      (:wat::core::map req-pairs
        (:wat::core::lambda
          ((p :trading::treasury::Service::EventChannel)
           -> :trading::treasury::Service::EventRx)
          (:wat::core::second p))))

     ;; Broker response channels — N pairs.
     ((resp-pairs :Vec<trading::treasury::Service::RespChannel>)
      (:wat::core::map (:wat::core::range 0 broker-count)
        (:wat::core::lambda
          ((_i :i64) -> :trading::treasury::Service::RespChannel)
          (:wat::kernel::make-bounded-queue
            :trading::treasury::Service::Response 1))))
     ((resp-txs :Vec<trading::treasury::Service::RespTx>)
      (:wat::core::map resp-pairs
        (:wat::core::lambda
          ((p :trading::treasury::Service::RespChannel)
           -> :trading::treasury::Service::RespTx)
          (:wat::core::first p))))
     ((resp-rxs :Vec<trading::treasury::Service::RespRx>)
      (:wat::core::map resp-pairs
        (:wat::core::lambda
          ((p :trading::treasury::Service::RespChannel)
           -> :trading::treasury::Service::RespRx)
          (:wat::core::second p))))

     ;; Broker handles — zip req-txs + resp-rxs into BrokerHandle tuples.
     ((handles :Vec<trading::treasury::Service::BrokerHandle>)
      (:wat::core::map (:wat::core::range 0 broker-count)
        (:wat::core::lambda
          ((i :i64) -> :trading::treasury::Service::BrokerHandle)
          (:wat::core::tuple
            (:wat::core::match (:wat::core::get req-txs i)
              -> :trading::treasury::Service::EventTx
              ((Some tx) tx)
              ;; Unreachable — i is in range.
              (:None
                (:wat::core::first
                  (:wat::kernel::make-bounded-queue
                    :trading::treasury::Service::Event 1))))
            (:wat::core::match (:wat::core::get resp-rxs i)
              -> :trading::treasury::Service::RespRx
              ((Some rx) rx)
              (:None
                (:wat::core::second
                  (:wat::kernel::make-bounded-queue
                    :trading::treasury::Service::Response 1))))))))

     ((pool :trading::treasury::Service::BrokerHandlePool)
      (:wat::kernel::HandlePool::new "TreasuryService" handles))

     ((driver :wat::kernel::ProgramHandle<()>)
      (:wat::kernel::spawn :trading::treasury::Service/loop-entry
        entry-fee exit-fee initial-balances
        tick-rx req-rxs resp-txs
        rundb-req-tx rundb-ack-tx rundb-ack-rx)))
    (:wat::core::tuple pool tick-tx driver)))
