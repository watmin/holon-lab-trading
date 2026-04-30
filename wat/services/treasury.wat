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
;; ── Slice-6 telemetry shape (arc 091) ────────────────────────────
;;
;; Driver closes over a `:wat::telemetry::Service::Handle<wat::telemetry::Event>` (a
;; Service::Handle<wat::telemetry::Event> tuple from arc 095) plus a
;; pre-built scope-fn (from `WorkUnit/make-scope` over the same
;; handle and a `:trading.treasury` namespace). Each Tick + each
;; broker-request opens a fresh wu via the captured scope-fn:
;;
;;   - `timed wu :check-deadlines body` records the duration of
;;     blocking work as a duration sample on the wu; substrate emits
;;     one Event::Metric row at scope-close per sample.
;;   - `WorkUnitLog/info wlog wu (:trading.treasury.tick {...})`
;;     records state observations (active-paper count, tick info)
;;     as Event::Log rows during the scope.
;;   - At scope-close make-scope's wrapper ships any accumulated
;;     metrics + the body's return value flows back.
;;
;; Per arc 091's metric/log discipline:
;;   - Counter (per-event bump):     incr! wu :ticks (one Metric row at close)
;;   - Duration (per-call timing):   timed wu :check-deadlines body
;;   - Snapshot (state observation): WorkUnitLog/info wlog wu data
;;
;; The pre-slice-6 `build-tick-telemetry` / `build-request-telemetry`
;; helpers retired with the `:trading::log::LogEntry` enum.
;;
;; ── Per the kill-the-mailbox direction ──────────────────────────
;;
;; No mailbox proxy thread. Driver owns Vec<Receiver<Event>> and
;; runs :wat::kernel::select inline.
;;
;; ── Lifecycle ────────────────────────────────────────────────────
;;
;;   1. Caller (Service sqlite-handle entry-fee exit-fee initial-balances
;;              broker-count) → returns (HandlePool<BrokerHandle>,
;;                                       TickTx, ProgramHandle).
;;   2. Driver opens nothing; constructs Treasury + WorkUnitLog +
;;      scope-fn inside its own thread; enters select loop.
;;   3. Caller pops BrokerHandles, distributes to brokers, calls
;;      HandlePool::finish.
;;   4. Main loop sends Tick events via tick-tx; brokers send
;;      requests via their req-tx and recv via their resp-rx.
;;   5. Brokers + main loop drop their senders. Last drop disconnects
;;      the driver's last receiver; loop exits; treasury value drops
;;      (no resources held). Caller (join driver) confirms exit.

(:wat::load-file! "../treasury/types.wat")
(:wat::load-file! "../treasury/treasury.wat")
(:wat::load-file! "../telemetry/Sqlite.wat")


;; ─── Protocol — Event + Response enums ──────────────────────────

(:wat::core::enum :trading::treasury::Service::Event
  (Tick (candle :wat::core::i64) (price :wat::core::f64))
  (SubmitPaper (from-asset :wat::core::String) (to-asset :wat::core::String) (price :wat::core::f64))
  (SubmitReal  (from-asset :wat::core::String) (to-asset :wat::core::String) (price :wat::core::f64))
  (SubmitExit  (paper-id :wat::core::i64) (current-price :wat::core::f64))
  (BatchGetPaperStates (paper-ids :Vec<i64>)))

(:wat::core::enum :trading::treasury::Service::Response
  (PaperIssued (receipt :trading::treasury::Receipt))
  (RealIssued  (maybe-receipt :Option<trading::treasury::Receipt>))
  (ExitResolved (maybe-verdict :Option<trading::treasury::Verdict>))
  (PaperStates (states :trading::treasury::Service::PaperStateEntries)))


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


;; ─── Response payload aliases (chapter 76) ──────────────────────
;;
;; PaperStates response is a Vec of (paper-id, maybe-state) tuples.
;; The tuple shape recurs at every access site — alias the entry
;; shape so the Vec spelling reads `Vec<PaperStateEntry>` rather
;; than the verbose nested form.
(:wat::core::typealias :trading::treasury::Service::PaperStateEntry
  :(i64,Option<trading::treasury::PositionState>))
(:wat::core::typealias :trading::treasury::Service::PaperStateEntries
  :Vec<trading::treasury::Service::PaperStateEntry>)


;; ─── Per-broker handle — what each broker receives from the pool ──

(:wat::core::typealias :trading::treasury::Service::BrokerHandle
  :(trading::treasury::Service::EventTx,trading::treasury::Service::RespRx))


;; ─── Slot — per-receiver routing identity ───────────────────────

(:wat::core::enum :trading::treasury::Service::Slot
  :Tick
  (Broker (resp-tx :trading::treasury::Service::RespTx)))


;; ─── Spawn return type ──────────────────────────────────────────

(:wat::core::typealias :trading::treasury::Service::BrokerHandlePool
  :wat::kernel::HandlePool<trading::treasury::Service::BrokerHandle>)

(:wat::core::typealias :trading::treasury::Service::Spawn
  :(trading::treasury::Service::BrokerHandlePool,trading::treasury::Service::EventTx,wat::kernel::ProgramHandle<()>))


;; ─── Tick snapshot — payload for Event::Log data ────────────────
;;
;; Slice 6: per-Tick state observation. Carries the candle the tick
;; observed, the resulting active-paper count, the f64 price. The
;; struct gets lifted to HolonAST + wrapped Tagged so downstream
;; SQL parsers read back the typed fields.

(:wat::core::struct :trading::treasury::TickSnapshot
  (candle        :wat::core::i64)
  (price         :wat::core::f64)
  (active-papers :wat::core::i64))


;; ─── handle-tick — open scope, time the work, log the snapshot ──

(:wat::core::define
  (:trading::treasury::Service/handle-tick
    (treasury :trading::treasury::Treasury)
    (candle :wat::core::i64)
    (price :wat::core::f64)
    (scope :wat::telemetry::WorkUnit::Scope<trading::treasury::Treasury>)
    (wlog  :wat::telemetry::WorkUnitLog)
    -> :trading::treasury::Treasury)
  (:wat::core::let*
    (((tags :wat::telemetry::Tags)
      (:wat::core::assoc
        (:wat::core::assoc
          (:wat::core::HashMap :wat::telemetry::Tag)
          (:wat::holon::Atom :verb) (:wat::holon::Atom :tick))
        (:wat::holon::Atom :candle) (:wat::holon::Atom candle))))
    (scope tags
      (:wat::core::lambda
        ((wu :wat::telemetry::WorkUnit) -> :trading::treasury::Treasury)
        (:wat::core::let*
          (((tup :(trading::treasury::Treasury,trading::treasury::Verdicts))
            (:wat::telemetry::WorkUnit/timed wu
              (:wat::holon::Atom :check-deadlines)
              (:wat::core::lambda
                (-> :(trading::treasury::Treasury,trading::treasury::Verdicts))
                (:trading::treasury::Treasury::check-deadlines treasury candle price))))
           ((t' :trading::treasury::Treasury) (:wat::core::first tup))
           ((_verdicts :trading::treasury::Verdicts) (:wat::core::second tup))
           ((active :wat::core::i64) (:trading::treasury::Treasury::active-paper-count t'))
           ((snap :trading::treasury::TickSnapshot)
            (:trading::treasury::TickSnapshot/new candle price active))
           ((_obs :())
            (:wat::telemetry::WorkUnitLog/info wlog wu
              (:wat::core::struct->form snap))))
          t')))))


;; ─── handle-broker-request — open scope, time the work, route response ──

(:wat::core::define
  (:trading::treasury::Service/handle-broker-request
    (treasury :trading::treasury::Treasury)
    (event :trading::treasury::Service::Event)
    (resp-tx :trading::treasury::Service::RespTx)
    (broker-idx :wat::core::i64)
    (scope :wat::telemetry::WorkUnit::Scope<trading::treasury::Treasury>)
    (wlog  :wat::telemetry::WorkUnitLog)
    -> :trading::treasury::Treasury)
  (:wat::core::let*
    (((tags :wat::telemetry::Tags)
      (:wat::core::assoc
        (:wat::core::assoc
          (:wat::core::HashMap :wat::telemetry::Tag)
          (:wat::holon::Atom :verb) (:wat::holon::Atom :broker-request))
        (:wat::holon::Atom :broker) (:wat::holon::Atom broker-idx))))
    (scope tags
      (:wat::core::lambda
        ((wu :wat::telemetry::WorkUnit) -> :trading::treasury::Treasury)
        (:wat::core::let*
          (((result :(trading::treasury::Treasury,trading::treasury::Service::Response))
            (:wat::telemetry::WorkUnit/timed wu
              (:wat::holon::Atom :handle-request)
              (:wat::core::lambda
                (-> :(trading::treasury::Treasury,trading::treasury::Service::Response))
                (:wat::core::match event
                  -> :(trading::treasury::Treasury,trading::treasury::Service::Response)
                  ((:trading::treasury::Service::Event::SubmitPaper from-asset to-asset price)
                    (:wat::core::let*
                      (((tup :(trading::treasury::Treasury,trading::treasury::Receipt))
                        (:trading::treasury::Treasury::issue-paper
                          treasury broker-idx from-asset to-asset price 0 288))
                       ((t' :trading::treasury::Treasury) (:wat::core::first tup))
                       ((receipt :trading::treasury::Receipt) (:wat::core::second tup)))
                      (:wat::core::tuple t'
                        (:trading::treasury::Service::Response::PaperIssued receipt))))
                  ((:trading::treasury::Service::Event::SubmitReal from-asset to-asset price)
                    (:wat::core::let*
                      (((tup :(trading::treasury::Treasury,Option<trading::treasury::Receipt>))
                        (:trading::treasury::Treasury::issue-real
                          treasury broker-idx from-asset to-asset price 0 288))
                       ((t' :trading::treasury::Treasury) (:wat::core::first tup))
                       ((maybe-receipt :Option<trading::treasury::Receipt>) (:wat::core::second tup)))
                      (:wat::core::tuple t'
                        (:trading::treasury::Service::Response::RealIssued maybe-receipt))))
                  ((:trading::treasury::Service::Event::SubmitExit paper-id current-price)
                    (:wat::core::let*
                      (((tup :(trading::treasury::Treasury,Option<trading::treasury::Verdict>))
                        (:trading::treasury::Treasury::resolve-grace
                          treasury paper-id current-price))
                       ((t' :trading::treasury::Treasury) (:wat::core::first tup))
                       ((maybe-verdict :Option<trading::treasury::Verdict>) (:wat::core::second tup)))
                      (:wat::core::tuple t'
                        (:trading::treasury::Service::Response::ExitResolved maybe-verdict))))
                  ((:trading::treasury::Service::Event::BatchGetPaperStates paper-ids)
                    (:wat::core::let*
                      (((states :trading::treasury::Service::PaperStateEntries)
                        (:wat::core::map paper-ids
                          (:wat::core::lambda
                            ((id :wat::core::i64) -> :trading::treasury::Service::PaperStateEntry)
                            (:wat::core::tuple id
                              (:wat::core::match
                                (:wat::core::get
                                  (:trading::treasury::Treasury/papers treasury) id)
                                -> :Option<trading::treasury::PositionState>
                                ((Some p) (Some (:trading::treasury::Paper/state p)))
                                (:None :None)))))))
                      (:wat::core::tuple treasury
                        (:trading::treasury::Service::Response::PaperStates states))))
                  (_
                    (:wat::core::tuple treasury
                      (:trading::treasury::Service::Response::PaperStates
                        (:wat::core::vec :trading::treasury::Service::PaperStateEntry))))))))
           ((t' :trading::treasury::Treasury) (:wat::core::first result))
           ((resp :trading::treasury::Service::Response) (:wat::core::second result))
           ((_send :())
            (:wat::core::result::expect -> :()
              (:wat::kernel::send resp-tx resp)
              "treasury/handle-broker-request: resp-tx disconnected — broker died?")))
          t')))))


;; ─── Driver — recursive select loop ─────────────────────────────

(:wat::core::define
  (:trading::treasury::Service/loop
    (treasury :trading::treasury::Treasury)
    (rxs :Vec<trading::treasury::Service::EventRx>)
    (slots :Vec<trading::treasury::Service::Slot>)
    (broker-indices :Vec<i64>)
    (scope :wat::telemetry::WorkUnit::Scope<trading::treasury::Treasury>)
    (wlog  :wat::telemetry::WorkUnitLog)
    -> :())
  (:wat::core::if (:wat::core::empty? rxs) -> :()
    ()
    (:wat::core::let*
      (((chosen :wat::kernel::Chosen<trading::treasury::Service::Event>)
        (:wat::kernel::select rxs))
       ((idx :wat::core::i64) (:wat::core::first chosen))
       ((maybe :wat::kernel::CommResult<trading::treasury::Service::Event>)
        (:wat::core::second chosen)))
      (:wat::core::match maybe -> :()
        ((Ok (Some event))
          (:wat::core::let*
            (((slot :trading::treasury::Service::Slot)
              (:wat::core::match (:wat::core::get slots idx)
                -> :trading::treasury::Service::Slot
                ((Some s) s)
                (:None :trading::treasury::Service::Slot::Tick)))
             ((treasury' :trading::treasury::Treasury)
              (:wat::core::match slot -> :trading::treasury::Treasury
                (:trading::treasury::Service::Slot::Tick
                  (:wat::core::match event -> :trading::treasury::Treasury
                    ((:trading::treasury::Service::Event::Tick candle price)
                      (:trading::treasury::Service/handle-tick
                        treasury candle price scope wlog))
                    (_ treasury)))
                ((:trading::treasury::Service::Slot::Broker resp-tx)
                  (:wat::core::let*
                    (((broker-idx :wat::core::i64)
                      (:wat::core::match (:wat::core::get broker-indices idx)
                        -> :wat::core::i64
                        ((Some i) i)
                        (:None -1))))
                    (:trading::treasury::Service/handle-broker-request
                      treasury event resp-tx broker-idx scope wlog))))))
            (:trading::treasury::Service/loop
              treasury' rxs slots broker-indices scope wlog)))
        ((Ok :None)
          (:trading::treasury::Service/loop
            treasury
            (:wat::std::list::remove-at rxs idx)
            (:wat::std::list::remove-at slots idx)
            (:wat::std::list::remove-at broker-indices idx)
            scope wlog))
        ((Err _died) ())))))


;; ─── Driver entry — constructs Treasury + telemetry inside thread ─

(:wat::core::define
  (:trading::treasury::Service/loop-entry
    (entry-fee :wat::core::f64)
    (exit-fee :wat::core::f64)
    (initial-balances :trading::treasury::Balances)
    (tick-rx :trading::treasury::Service::EventRx)
    (broker-rxs :Vec<trading::treasury::Service::EventRx>)
    (broker-resp-txs :Vec<trading::treasury::Service::RespTx>)
    (sqlite-handle :wat::telemetry::Service::Handle<wat::telemetry::Event>)
    -> :())
  (:wat::core::let*
    (((treasury :trading::treasury::Treasury)
      (:trading::treasury::Treasury::fresh entry-fee exit-fee initial-balances))
     ((ns :wat::holon::HolonAST) (:wat::holon::Atom :trading.treasury))
     ((scope :wat::telemetry::WorkUnit::Scope<trading::treasury::Treasury>)
      (:wat::telemetry::WorkUnit/make-scope sqlite-handle ns))
     ((wlog :wat::telemetry::WorkUnitLog)
      (:wat::telemetry::WorkUnitLog/new
        sqlite-handle :treasury
        (:wat::core::lambda ((_u :()) -> :wat::time::Instant)
          (:wat::time::now))))
     ((rxs :Vec<trading::treasury::Service::EventRx>)
      (:wat::core::concat
        (:wat::core::vec :trading::treasury::Service::EventRx tick-rx)
        broker-rxs))
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
     ((n :wat::core::i64) (:wat::core::length broker-rxs))
     ((broker-indices :Vec<i64>)
      (:wat::core::concat
        (:wat::core::vec :wat::core::i64 -1)
        (:wat::core::range 0 n))))
    (:trading::treasury::Service/loop
      treasury rxs slots broker-indices scope wlog)))


;; ─── Client helpers — broker-side ───────────────────────────────

(:wat::core::define
  (:trading::treasury::Service/submit-paper
    (handle :trading::treasury::Service::BrokerHandle)
    (from-asset :wat::core::String) (to-asset :wat::core::String) (price :wat::core::f64)
    -> :Option<trading::treasury::Receipt>)
  (:wat::core::let*
    (((req-tx :trading::treasury::Service::EventTx) (:wat::core::first handle))
     ((resp-rx :trading::treasury::Service::RespRx) (:wat::core::second handle))
     ((event :trading::treasury::Service::Event)
      (:trading::treasury::Service::Event::SubmitPaper from-asset to-asset price))
     ((_send :())
      (:wat::core::result::expect -> :()
        (:wat::kernel::send req-tx event)
        "treasury/submit-paper: req-tx disconnected — driver died?")))
    (:wat::core::match (:wat::kernel::recv resp-rx)
      -> :Option<trading::treasury::Receipt>
      ((Ok (Some (:trading::treasury::Service::Response::PaperIssued r))) (Some r))
      ((Ok _) :None)
      ((Err _died) :None)))

(:wat::core::define
  (:trading::treasury::Service/submit-real
    (handle :trading::treasury::Service::BrokerHandle)
    (from-asset :wat::core::String) (to-asset :wat::core::String) (price :wat::core::f64)
    -> :Option<trading::treasury::Receipt>)
  (:wat::core::let*
    (((req-tx :trading::treasury::Service::EventTx) (:wat::core::first handle))
     ((resp-rx :trading::treasury::Service::RespRx) (:wat::core::second handle))
     ((event :trading::treasury::Service::Event)
      (:trading::treasury::Service::Event::SubmitReal from-asset to-asset price))
     ((_send :())
      (:wat::core::result::expect -> :()
        (:wat::kernel::send req-tx event)
        "treasury/submit-real: req-tx disconnected — driver died?")))
    (:wat::core::match (:wat::kernel::recv resp-rx)
      -> :Option<trading::treasury::Receipt>
      ((Ok (Some (:trading::treasury::Service::Response::RealIssued mr))) mr)
      ((Ok _) :None)
      ((Err _died) :None)))

(:wat::core::define
  (:trading::treasury::Service/submit-exit
    (handle :trading::treasury::Service::BrokerHandle)
    (paper-id :wat::core::i64) (current-price :wat::core::f64)
    -> :Option<trading::treasury::Verdict>)
  (:wat::core::let*
    (((req-tx :trading::treasury::Service::EventTx) (:wat::core::first handle))
     ((resp-rx :trading::treasury::Service::RespRx) (:wat::core::second handle))
     ((event :trading::treasury::Service::Event)
      (:trading::treasury::Service::Event::SubmitExit paper-id current-price))
     ((_send :())
      (:wat::core::result::expect -> :()
        (:wat::kernel::send req-tx event)
        "treasury/submit-exit: req-tx disconnected — driver died?")))
    (:wat::core::match (:wat::kernel::recv resp-rx)
      -> :Option<trading::treasury::Verdict>
      ((Ok (Some (:trading::treasury::Service::Response::ExitResolved mv))) mv)
      ((Ok _) :None)
      ((Err _died) :None)))

(:wat::core::define
  (:trading::treasury::Service/batch-get-paper-states
    (handle :trading::treasury::Service::BrokerHandle)
    (paper-ids :Vec<i64>)
    -> :trading::treasury::Service::PaperStateEntries)
  (:wat::core::let*
    (((req-tx :trading::treasury::Service::EventTx) (:wat::core::first handle))
     ((resp-rx :trading::treasury::Service::RespRx) (:wat::core::second handle))
     ((event :trading::treasury::Service::Event)
      (:trading::treasury::Service::Event::BatchGetPaperStates paper-ids))
     ((_send :())
      (:wat::core::result::expect -> :()
        (:wat::kernel::send req-tx event)
        "treasury/batch-get-paper-states: req-tx disconnected — driver died?")))
    (:wat::core::match (:wat::kernel::recv resp-rx)
      -> :trading::treasury::Service::PaperStateEntries
      ((Ok (Some (:trading::treasury::Service::Response::PaperStates states))) states)
      ((Ok _) (:wat::core::vec :trading::treasury::Service::PaperStateEntry))
      ((Err _died) (:wat::core::vec :trading::treasury::Service::PaperStateEntry)))))


;; ─── Setup — spawns the driver, returns Spawn tuple ─────────────

(:wat::core::define
  (:trading::treasury::Service
    (sqlite-handle :wat::telemetry::Service::Handle<wat::telemetry::Event>)
    (entry-fee :wat::core::f64)
    (exit-fee :wat::core::f64)
    (initial-balances :trading::treasury::Balances)
    (broker-count :wat::core::i64)
    -> :trading::treasury::Service::Spawn)
  (:wat::core::let*
    (((tick-pair :trading::treasury::Service::EventChannel)
      (:wat::kernel::make-bounded-queue
        :trading::treasury::Service::Event 1))
     ((tick-tx :trading::treasury::Service::EventTx)
      (:wat::core::first tick-pair))
     ((tick-rx :trading::treasury::Service::EventRx)
      (:wat::core::second tick-pair))

     ((req-pairs :Vec<trading::treasury::Service::EventChannel>)
      (:wat::core::map (:wat::core::range 0 broker-count)
        (:wat::core::lambda
          ((_i :wat::core::i64) -> :trading::treasury::Service::EventChannel)
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

     ((resp-pairs :Vec<trading::treasury::Service::RespChannel>)
      (:wat::core::map (:wat::core::range 0 broker-count)
        (:wat::core::lambda
          ((_i :wat::core::i64) -> :trading::treasury::Service::RespChannel)
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

     ((handles :Vec<trading::treasury::Service::BrokerHandle>)
      (:wat::core::map (:wat::core::range 0 broker-count)
        (:wat::core::lambda
          ((i :wat::core::i64) -> :trading::treasury::Service::BrokerHandle)
          (:wat::core::tuple
            (:wat::core::match (:wat::core::get req-txs i)
              -> :trading::treasury::Service::EventTx
              ((Some tx) tx)
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
        tick-rx req-rxs resp-txs sqlite-handle)))
    (:wat::core::tuple pool tick-tx driver)))
