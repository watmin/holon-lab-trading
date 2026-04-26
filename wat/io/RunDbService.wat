;; :lab::rundb::Service — CSP wrapper over `:lab::rundb::RunDb`.
;;
;; CacheService-style request/reply driver: each request carries a
;; batch of `:lab::log::LogEntry` plus the client's ack-tx; the
;; driver dispatches each entry to its per-variant shim wrapper,
;; then signals ack. One thread owns the connection; N clients
;; each get a request-Tx + a personal ack channel pair.
;;
;; Lifecycle (mirrors Console + CacheService):
;;   1. Caller `(Service path count)` — spawns the driver, returns
;;      `(HandlePool<ReqTx>, ProgramHandle<()>)`.
;;   2. Driver `Service/loop-entry` opens the RunDb in its own
;;      thread (per-thread-owned discipline; can't pass an open
;;      Connection across threads), installs every schema in
;;      `:lab::log::all-schemas`, enters the select loop.
;;   3. Caller pops handles, distributes them to clients, calls
;;      `HandlePool::finish` once distribution is complete.
;;   4. Each client `(Service/batch-log req-tx ack-tx ack-rx
;;      entries)` — sends the batch + ack-tx, blocks on ack-rx
;;      until the driver commits.
;;   5. Clients drop their handles. Last drop disconnects the
;;      driver's last receiver; loop's `select` returns `:None`,
;;      the rxs vec drains, loop exits, RunDb drops, file handle
;;      closes.
;;   6. Caller `(join driver)` — confirms clean exit; surfaces
;;      driver-thread panics as RuntimeError.
;;
;; Per arc 029 Q9 — variant dispatch is wat-side. The service
;; loop is generic over `LogEntry`; future variants land as wat
;; arms in `Service/dispatch` + new shim wrappers, no service
;; restructure.
;;
;; Per arc 029 Q10 — batch-log is the ONLY client primitive.
;; Single-entry callers wrap in a one-element vec. Confirmed
;; back-pressure (each batch blocks on its own ack channel) is
;; the contract; sugar that hides this would obscure the
;; semantics callers need to reason about.
;;
;; Per arc 029 Q3 (and reaffirmed in Q10): v1 ships without
;; explicit BEGIN/COMMIT around the batch foldl. SQLite auto-
;; commits each statement. A future perf arc adds transaction
;; wrapping once measurement shows commit overhead is the
;; bottleneck. For the lab's current write volume (~340 inserts
;; per proof) the simpler shape wins.

(:wat::load-file! "RunDb.wat")
(:wat::load-file! "log/LogEntry.wat")
(:wat::load-file! "log/schema.wat")


;; ─── Protocol typealiases ────────────────────────────────────────

;; Per-request ack channel. Driver `send`s `()` after committing
;; the batch; client `recv`s to unblock its `batch-log` call.
(:wat::core::typealias :lab::rundb::Service::AckTx
  :rust::crossbeam_channel::Sender<()>)
(:wat::core::typealias :lab::rundb::Service::AckRx
  :rust::crossbeam_channel::Receiver<()>)

;; A Request is one batch of LogEntries + the ack channel the
;; client wants signaled on after commit.
(:wat::core::typealias :lab::rundb::Service::Request
  :(Vec<lab::log::LogEntry>,lab::rundb::Service::AckTx))

(:wat::core::typealias :lab::rundb::Service::ReqTx
  :rust::crossbeam_channel::Sender<lab::rundb::Service::Request>)
(:wat::core::typealias :lab::rundb::Service::ReqRx
  :rust::crossbeam_channel::Receiver<lab::rundb::Service::Request>)

;; The pool variant returned alongside the driver-handle. Wraps
;; the N pre-built request senders so callers `pop`/`finish` the
;; standard HandlePool surface.
(:wat::core::typealias :lab::rundb::Service::ReqTxPool
  :wat::kernel::HandlePool<lab::rundb::Service::ReqTx>)

;; What `(:lab::rundb::Service path count)` returns — the
;; (handle-pool-of-request-txs, driver-program-handle) pair the
;; caller distributes + joins. Aliased so the function's signature
;; communicates intent rather than a nested generic.
(:wat::core::typealias :lab::rundb::Service::Spawn
  :(lab::rundb::Service::ReqTxPool,wat::kernel::ProgramHandle<()>))

;; A client's reusable ack channel — what
;; `(:wat::kernel::make-bounded-queue :() 1)` returns when the
;; client sets up its per-batch ack. Held across batches so the
;; recv site is the synchronization point.
(:wat::core::typealias :lab::rundb::Service::AckChannel
  :(lab::rundb::Service::AckTx,lab::rundb::Service::AckRx))


;; ─── Per-variant dispatcher (wat-side, per Q9) ───────────────────

;; Routes one LogEntry to its typed shim wrapper. Future variants
;; add arms here + new `:lab::rundb::log-<variant>` wat wrapper +
;; new shim method.
(:wat::core::define
  (:lab::rundb::Service/dispatch
    (db :lab::rundb::RunDb)
    (entry :lab::log::LogEntry)
    -> :())
  (:wat::core::match entry -> :()
    ((:lab::log::LogEntry::PaperResolved
        run-name thinker predictor paper-id
        direction opened-at resolved-at
        state residue loss)
      (:lab::rundb::log-paper-resolved
        db run-name thinker predictor paper-id
        direction opened-at resolved-at
        state residue loss))))


;; ─── Driver entry — opens, installs schemas, enters loop ─────────

;; Per CacheService precedent: RunDb is `thread_owned`, so `open`
;; MUST happen in the driver's thread. Setup never touches a
;; RunDb; it just builds queues + spawns the entry below.
(:wat::core::define
  (:lab::rundb::Service/loop-entry
    (path :String)
    (rxs :Vec<lab::rundb::Service::ReqRx>)
    -> :())
  (:wat::core::let*
    (((db :lab::rundb::RunDb) (:lab::rundb::open path))
     ;; Install every known schema. CREATE TABLE IF NOT EXISTS
     ;; makes this idempotent vs the auto-schema-on-open path.
     ((_install :())
      (:wat::core::foldl (:lab::log::all-schemas) ()
        (:wat::core::lambda
          ((acc :()) (ddl :String) -> :())
          (:lab::rundb::execute-ddl db ddl)))))
    (:lab::rundb::Service/loop db rxs)))


;; ─── Recursive select loop with confirmed batch + ack ────────────

;; Mirrors Console's select-and-remove pattern. On `Some(req)`,
;; foldl-dispatch the batch then send ack; on `:None`,
;; `remove-at` drops the disconnected receiver and recurses on
;; the trimmed vec. Loop exits when the vec is empty (every
;; client has dropped its sender).
(:wat::core::define
  (:lab::rundb::Service/loop
    (db :lab::rundb::RunDb)
    (rxs :Vec<lab::rundb::Service::ReqRx>)
    -> :())
  (:wat::core::if (:wat::core::empty? rxs) -> :()
    ()
    (:wat::core::let*
      (((chosen :(i64,Option<lab::rundb::Service::Request>))
        (:wat::kernel::select rxs))
       ((idx :i64) (:wat::core::first chosen))
       ((maybe :Option<lab::rundb::Service::Request>)
        (:wat::core::second chosen)))
      (:wat::core::match maybe -> :()
        ((Some req)
          (:wat::core::let*
            (((entries :Vec<lab::log::LogEntry>)
              (:wat::core::first req))
             ((ack-tx :lab::rundb::Service::AckTx)
              (:wat::core::second req))
             ;; Apply each entry. Auto-commit per statement
             ;; (v1; future perf arc wraps in BEGIN/COMMIT).
             ((_apply :())
              (:wat::core::foldl entries ()
                (:wat::core::lambda
                  ((acc :()) (e :lab::log::LogEntry) -> :())
                  (:lab::rundb::Service/dispatch db e))))
             ;; Ack — driver-side `send` swallows :None if the
             ;; client dropped its ack-rx mid-batch.
             ((_ack :Option<()>) (:wat::kernel::send ack-tx ())))
            (:lab::rundb::Service/loop db rxs)))
        (:None
          (:lab::rundb::Service/loop
            db
            (:wat::std::list::remove-at rxs idx)))))))


;; ─── Client helper — single primitive, batch-only (per Q10) ──────

;; Sends the batch + ack-tx on req-tx, blocks on ack-rx until the
;; driver signals commit. Single-entry callers wrap in a
;; one-element vec — no fire-and-forget shortcut, by design (the
;; back-pressure semantics matter at every scale).
;;
;; If the driver is gone (caller raced shutdown), the send returns
;; :None and the recv returns :None; both are discarded — same
;; silent-late-lifecycle posture as Console/out.
(:wat::core::define
  (:lab::rundb::Service/batch-log
    (req-tx :lab::rundb::Service::ReqTx)
    (ack-tx :lab::rundb::Service::AckTx)
    (ack-rx :lab::rundb::Service::AckRx)
    (entries :Vec<lab::log::LogEntry>)
    -> :())
  (:wat::core::let*
    (((req :lab::rundb::Service::Request)
      (:wat::core::tuple entries ack-tx))
     ((_send :Option<()>) (:wat::kernel::send req-tx req))
     ((_recv :Option<()>) (:wat::kernel::recv ack-rx)))
    ()))


;; ─── Setup — spawns the driver, returns (HandlePool, driver) ─────

;; Builds N bounded(1) queues for requests, wraps the senders in
;; a HandlePool, spawns one driver thread that fans in all
;; receivers and dispatches per LogEntry variant, returns
;; (pool, driver-handle).
;;
;; The returned tuple is the honest shutdown contract: caller
;; pops N handles, distributes to clients, calls
;; HandlePool::finish, lets clients work + drop handles, then
;; calls `(join driver)` to confirm clean exit.
(:wat::core::define
  (:lab::rundb::Service
    (path :String)
    (count :i64)
    -> :lab::rundb::Service::Spawn)
  (:wat::core::let*
    (((pairs :Vec<(lab::rundb::Service::ReqTx,lab::rundb::Service::ReqRx)>)
      (:wat::core::map
        (:wat::core::range 0 count)
        (:wat::core::lambda
          ((_i :i64) -> :(lab::rundb::Service::ReqTx,lab::rundb::Service::ReqRx))
          (:wat::kernel::make-bounded-queue
            :lab::rundb::Service::Request 1))))
     ((req-txs :Vec<lab::rundb::Service::ReqTx>)
      (:wat::core::map pairs
        (:wat::core::lambda
          ((p :(lab::rundb::Service::ReqTx,lab::rundb::Service::ReqRx)) -> :lab::rundb::Service::ReqTx)
          (:wat::core::first p))))
     ((req-rxs :Vec<lab::rundb::Service::ReqRx>)
      (:wat::core::map pairs
        (:wat::core::lambda
          ((p :(lab::rundb::Service::ReqTx,lab::rundb::Service::ReqRx)) -> :lab::rundb::Service::ReqRx)
          (:wat::core::second p))))
     ((pool :lab::rundb::Service::ReqTxPool)
      (:wat::kernel::HandlePool::new "RunDbService" req-txs))
     ((driver :wat::kernel::ProgramHandle<()>)
      (:wat::kernel::spawn :lab::rundb::Service/loop-entry path req-rxs)))
    (:wat::core::tuple pool driver)))
