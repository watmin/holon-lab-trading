;; :trading::rundb::Service — CSP wrapper over `:trading::rundb::RunDb`.
;;
;; CacheService-style request/reply driver: each request carries a
;; batch of `:trading::log::LogEntry` plus the client's ack-tx; the
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
;;      `:trading::log::all-schemas`, enters the select loop.
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
(:wat::core::typealias :trading::rundb::Service::AckTx
  :rust::crossbeam_channel::Sender<()>)
(:wat::core::typealias :trading::rundb::Service::AckRx
  :rust::crossbeam_channel::Receiver<()>)

;; A Request is one batch of LogEntries + the ack channel the
;; client wants signaled on after commit.
(:wat::core::typealias :trading::rundb::Service::Request
  :(Vec<trading::log::LogEntry>,trading::rundb::Service::AckTx))

(:wat::core::typealias :trading::rundb::Service::ReqTx
  :rust::crossbeam_channel::Sender<trading::rundb::Service::Request>)
(:wat::core::typealias :trading::rundb::Service::ReqRx
  :rust::crossbeam_channel::Receiver<trading::rundb::Service::Request>)

;; The setup-side request channel — what
;; `(:wat::kernel::make-bounded-queue :Service::Request 1)`
;; returns. The `Service` setup function builds N of these,
;; splits txs into the HandlePool and rxs into the driver's
;; select vec.
(:wat::core::typealias :trading::rundb::Service::ReqChannel
  :(trading::rundb::Service::ReqTx,trading::rundb::Service::ReqRx))

;; The pool variant returned alongside the driver-handle. Wraps
;; the N pre-built request senders so callers `pop`/`finish` the
;; standard HandlePool surface.
(:wat::core::typealias :trading::rundb::Service::ReqTxPool
  :wat::kernel::HandlePool<trading::rundb::Service::ReqTx>)

;; What `(:trading::rundb::Service path count)` returns — the
;; (handle-pool-of-request-txs, driver-program-handle) pair the
;; caller distributes + joins. Aliased so the function's signature
;; communicates intent rather than a nested generic.
(:wat::core::typealias :trading::rundb::Service::Spawn
  :(trading::rundb::Service::ReqTxPool,wat::kernel::ProgramHandle<()>))

;; A client's reusable ack channel — what
;; `(:wat::kernel::make-bounded-queue :() 1)` returns when the
;; client sets up its per-batch ack. Held across batches so the
;; recv site is the synchronization point.
(:wat::core::typealias :trading::rundb::Service::AckChannel
  :(trading::rundb::Service::AckTx,trading::rundb::Service::AckRx))


;; ─── Self-heartbeat contract — Stats + MetricsCadence ────────────
;;
;; Per arc 078 the canonical service contract is Reporter +
;; MetricsCadence + null-helpers + typed Report enum. Rundb adopts
;; the cadence half but NOT the Reporter half — when the cadence
;; fires, rundb dispatches its own telemetry rows DIRECTLY through
;; the same `Service/dispatch db entry` path that serves client
;; batches, inside the driver thread that already holds `db`. No
;; queue, no closure-over-self, no deadlock. This is the second
;; documented exception to the canonical contract (the first is
;; Console — when a service IS its own destination, the Reporter
;; injection point becomes redundant).
;;
;; The MetricsCadence pattern stays. Caller picks G; the loop
;; threads gate through every iteration; tick-window advances the
;; gate and (on fire) emits self-telemetry + resets stats.

;; Counters accumulated over a gate window. Reset to zero after
;; each fire.
(:wat::core::struct :trading::rundb::Service::Stats
  (batches :i64)         ;; batch-log requests handled this window
  (entries :i64)         ;; total LogEntry rows committed this window
  (max-batch-size :i64)) ;; largest batch this window (0 if none)

;; MetricsCadence<G> — same shape as
;; :wat::holon::lru::HologramCacheService::MetricsCadence<G>. The
;; substrate's service-contract gate; rundb inherits the cadence
;; mechanism and varies only in not having a Reporter (see above).
(:wat::core::struct :trading::rundb::Service::MetricsCadence<G>
  (gate :G)
  (tick :fn(G,trading::rundb::Service::Stats)->(G,bool)))

;; One loop-iteration's outputs: post-dispatch Stats paired with
;; the advanced cadence. Aliased to keep the loop signature flat.
(:wat::core::typealias :trading::rundb::Service::Step<G>
  :(trading::rundb::Service::Stats,trading::rundb::Service::MetricsCadence<G>))

;; null-metrics-cadence — fresh `MetricsCadence<()>` whose tick
;; never fires. Use when self-heartbeat is a deliberate opt-out;
;; rundb operates exactly as it did pre-arc.
(:wat::core::define
  (:trading::rundb::Service/null-metrics-cadence
    -> :trading::rundb::Service::MetricsCadence<()>)
  (:trading::rundb::Service::MetricsCadence/new
    ()
    (:wat::core::lambda
      ((gate :()) (_stats :trading::rundb::Service::Stats) -> :((),bool))
      (:wat::core::tuple gate false))))

;; Fresh zero-counters Stats. Used at startup and after each
;; gate-fire (window-rolling reset).
(:wat::core::define
  (:trading::rundb::Service::Stats/zero -> :trading::rundb::Service::Stats)
  (:trading::rundb::Service::Stats/new 0 0 0))


;; ─── Per-variant dispatcher (wat-side, per Q9) ───────────────────

;; Routes one LogEntry to its typed shim wrapper. Future variants
;; add arms here + new `:trading::rundb::log-<variant>` wat wrapper +
;; new shim method.
(:wat::core::define
  (:trading::rundb::Service/dispatch
    (db :trading::rundb::RunDb)
    (entry :trading::log::LogEntry)
    -> :())
  (:wat::core::match entry -> :()
    ((:trading::log::LogEntry::PaperResolved
        run-name thinker predictor paper-id
        direction opened-at resolved-at
        state residue loss)
      (:trading::rundb::log-paper-resolved
        db run-name thinker predictor paper-id
        direction opened-at resolved-at
        state residue loss))
    ((:trading::log::LogEntry::Telemetry
        namespace id dimensions timestamp-ns
        metric-name metric-value metric-unit)
      (:trading::rundb::log-telemetry
        db namespace id dimensions timestamp-ns
        metric-name metric-value metric-unit))))


;; ─── Tick the heartbeat window — fire emits self-telemetry ───────
;;
;; Always: tick the cadence (gate → gate'); rebuild the cadence
;; struct with the advanced gate. The cadence never freezes; every
;; call moves it forward.
;;
;; On fire: build 3 LogEntry::Telemetry rows from the current
;; stats (batches / entries / max-batch-size), dispatch each
;; INLINE through Service/dispatch on the driver-owned db, return
;; reset stats + advanced cadence.
;;
;; On no-fire: stats unchanged; cadence advanced.

(:wat::core::define
  (:trading::rundb::Service/tick-window<G>
    (db :trading::rundb::RunDb)
    (stats :trading::rundb::Service::Stats)
    (metrics-cadence :trading::rundb::Service::MetricsCadence<G>)
    -> :trading::rundb::Service::Step<G>)
  (:wat::core::let*
    (((gate :G)
      (:trading::rundb::Service::MetricsCadence/gate metrics-cadence))
     ((tick-fn :fn(G,trading::rundb::Service::Stats)->(G,bool))
      (:trading::rundb::Service::MetricsCadence/tick metrics-cadence))
     ((tick :(G,bool)) (tick-fn gate stats))
     ((gate' :G) (:wat::core::first tick))
     ((fired :bool) (:wat::core::second tick))
     ((cadence' :trading::rundb::Service::MetricsCadence<G>)
      (:trading::rundb::Service::MetricsCadence/new gate' tick-fn)))
    (:wat::core::if fired -> :trading::rundb::Service::Step<G>
      (:wat::core::let*
        (((ts :i64) (:wat::time::epoch-millis (:wat::time::now)))
         ((dimensions :String) "{\"service\":\"rundb\"}")
         ((entries :Vec<trading::log::LogEntry>)
          (:wat::core::vec :trading::log::LogEntry
            (:trading::log::emit-metric
              "rundb" "self" dimensions ts
              "batches"
              (:wat::core::i64::to-f64
                (:trading::rundb::Service::Stats/batches stats))
              "Count")
            (:trading::log::emit-metric
              "rundb" "self" dimensions ts
              "entries"
              (:wat::core::i64::to-f64
                (:trading::rundb::Service::Stats/entries stats))
              "Count")
            (:trading::log::emit-metric
              "rundb" "self" dimensions ts
              "max-batch-size"
              (:wat::core::i64::to-f64
                (:trading::rundb::Service::Stats/max-batch-size stats))
              "Count")))
         ;; Inline dispatch — same path client batches take.
         ((_dispatch :())
          (:wat::core::foldl entries ()
            (:wat::core::lambda
              ((acc :()) (e :trading::log::LogEntry) -> :())
              (:trading::rundb::Service/dispatch db e)))))
        (:wat::core::tuple
          (:trading::rundb::Service::Stats/zero) cadence'))
      (:wat::core::tuple stats cadence'))))


;; ─── Driver entry — opens, installs schemas, enters loop ─────────

;; Per CacheService precedent: RunDb is `thread_owned`, so `open`
;; MUST happen in the driver's thread. Setup never touches a
;; RunDb; it just builds queues + spawns the entry below.
(:wat::core::define
  (:trading::rundb::Service/loop-entry<G>
    (path :String)
    (rxs :Vec<trading::rundb::Service::ReqRx>)
    (metrics-cadence :trading::rundb::Service::MetricsCadence<G>)
    -> :())
  (:wat::core::let*
    (((db :trading::rundb::RunDb) (:trading::rundb::open path))
     ;; Install every known schema. CREATE TABLE IF NOT EXISTS
     ;; makes this idempotent vs the auto-schema-on-open path.
     ((_install :())
      (:wat::core::foldl (:trading::log::all-schemas) ()
        (:wat::core::lambda
          ((acc :()) (ddl :String) -> :())
          (:trading::rundb::execute-ddl db ddl)))))
    (:trading::rundb::Service/loop
      db rxs
      (:trading::rundb::Service::Stats/zero)
      metrics-cadence)))


;; ─── Recursive select loop with confirmed batch + ack + heartbeat
;;
;; Per-iteration order:
;;   1. select; on Some(req): dispatch the batch's entries
;;   2. ack the client (release their batch-log call ASAP)
;;   3. update Stats with this batch's contribution
;;   4. tick-window — advance cadence; on fire, emit self-telemetry
;;      + reset stats
;;   5. recurse with (stats', cadence')
;;
;; On :None: prune the disconnected receiver, recurse with stats +
;; cadence unchanged. Loop exits when rxs is empty.
(:wat::core::define
  (:trading::rundb::Service/loop<G>
    (db :trading::rundb::RunDb)
    (rxs :Vec<trading::rundb::Service::ReqRx>)
    (stats :trading::rundb::Service::Stats)
    (metrics-cadence :trading::rundb::Service::MetricsCadence<G>)
    -> :())
  (:wat::core::if (:wat::core::empty? rxs) -> :()
    ()
    (:wat::core::let*
      (((chosen :(i64,Option<trading::rundb::Service::Request>))
        (:wat::kernel::select rxs))
       ((idx :i64) (:wat::core::first chosen))
       ((maybe :Option<trading::rundb::Service::Request>)
        (:wat::core::second chosen)))
      (:wat::core::match maybe -> :()
        ((Some req)
          (:wat::core::let*
            (((entries :Vec<trading::log::LogEntry>)
              (:wat::core::first req))
             ((ack-tx :trading::rundb::Service::AckTx)
              (:wat::core::second req))
             ;; Apply each entry. Auto-commit per statement
             ;; (v1; future perf arc wraps in BEGIN/COMMIT).
             ((_apply :())
              (:wat::core::foldl entries ()
                (:wat::core::lambda
                  ((acc :()) (e :trading::log::LogEntry) -> :())
                  (:trading::rundb::Service/dispatch db e))))
             ;; Ack first — release client's batch-log call before
             ;; running the heartbeat tick.
             ((_ack :Option<()>) (:wat::kernel::send ack-tx ()))
             ;; Update Stats with this batch's contribution.
             ((batch-size :i64) (:wat::core::length entries))
             ((stats' :trading::rundb::Service::Stats)
              (:trading::rundb::Service::Stats/new
                (:wat::core::+
                  (:trading::rundb::Service::Stats/batches stats) 1)
                (:wat::core::+
                  (:trading::rundb::Service::Stats/entries stats) batch-size)
                (:wat::core::if
                  (:wat::core::> batch-size
                    (:trading::rundb::Service::Stats/max-batch-size stats))
                  -> :i64
                  batch-size
                  (:trading::rundb::Service::Stats/max-batch-size stats))))
             ;; Tick window — advance cadence; fire emits self-rows.
             ((step :trading::rundb::Service::Step<G>)
              (:trading::rundb::Service/tick-window
                db stats' metrics-cadence))
             ((stats'' :trading::rundb::Service::Stats)
              (:wat::core::first step))
             ((cadence' :trading::rundb::Service::MetricsCadence<G>)
              (:wat::core::second step)))
            (:trading::rundb::Service/loop db rxs stats'' cadence')))
        (:None
          (:trading::rundb::Service/loop
            db
            (:wat::std::list::remove-at rxs idx)
            stats metrics-cadence))))))


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
  (:trading::rundb::Service/batch-log
    (req-tx :trading::rundb::Service::ReqTx)
    (ack-tx :trading::rundb::Service::AckTx)
    (ack-rx :trading::rundb::Service::AckRx)
    (entries :Vec<trading::log::LogEntry>)
    -> :())
  (:wat::core::let*
    (((req :trading::rundb::Service::Request)
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
  (:trading::rundb::Service<G>
    (path :String)
    (count :i64)
    (metrics-cadence :trading::rundb::Service::MetricsCadence<G>)
    -> :trading::rundb::Service::Spawn)
  (:wat::core::let*
    (((pairs :Vec<trading::rundb::Service::ReqChannel>)
      (:wat::core::map
        (:wat::core::range 0 count)
        (:wat::core::lambda
          ((_i :i64) -> :trading::rundb::Service::ReqChannel)
          (:wat::kernel::make-bounded-queue
            :trading::rundb::Service::Request 1))))
     ((req-txs :Vec<trading::rundb::Service::ReqTx>)
      (:wat::core::map pairs
        (:wat::core::lambda
          ((p :trading::rundb::Service::ReqChannel) -> :trading::rundb::Service::ReqTx)
          (:wat::core::first p))))
     ((req-rxs :Vec<trading::rundb::Service::ReqRx>)
      (:wat::core::map pairs
        (:wat::core::lambda
          ((p :trading::rundb::Service::ReqChannel) -> :trading::rundb::Service::ReqRx)
          (:wat::core::second p))))
     ((pool :trading::rundb::Service::ReqTxPool)
      (:wat::kernel::HandlePool::new "RunDbService" req-txs))
     ((driver :wat::kernel::ProgramHandle<()>)
      (:wat::kernel::spawn :trading::rundb::Service/loop-entry
        path req-rxs metrics-cadence)))
    (:wat::core::tuple pool driver)))
