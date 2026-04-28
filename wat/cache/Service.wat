;; :trading::cache::Service — L2 cache as a queue-addressed program.
;;
;; A long-running spawned program that owns a HologramCache and serves
;; cache requests via a request queue. Each client gets a per-client
;; reply channel for Get; Put is fire-and-forget.
;;
;; Slice 1 minimal:
;;   - Request: Get(probe, reply-tx) | Put(key, val)
;;   - State:   HologramCache + Stats (cache + per-window counters)
;;   - Reply:   Option<HolonAST> sent on reply-tx
;;   - Telemetry: caller-supplied (metrics-cadence-fn, telemetry-fn,
;;     initial-gate) triple. Service is non-negotiable: caller must
;;     pass all three. Opt-out is `null-metrics-cadence` (never fires) /
;;     `null-telemetry` (discards) / `()` initial-gate. Construction-
;;     time choice.
;;
;; Pattern mirrors archive's programs/stdlib/cache.rs::cache(can_emit,
;; emit) — same callback-injection idea, lifted to wat's stateful-
;; values-up shape: metrics-cadence is `:fn(G, Stats) -> :(G, bool)` so the
;; user threads time / counters / whatever through the loop without
;; reaching for Mutex.
;;
;; Arc 076 + 077: slot routing inferred from the form's structure
;; (the substrate does it inside HologramCache); no caller-supplied
;; pos. Filter is bound at HologramCache/make time.

;; ─── Reply channel typealiases ──────────────────────────────────

(:wat::core::typealias :trading::cache::GetReplyTx
  :wat::kernel::QueueSender<Option<wat::holon::HolonAST>>)

(:wat::core::typealias :trading::cache::GetReplyRx
  :wat::kernel::QueueReceiver<Option<wat::holon::HolonAST>>)

;; ─── Request enum ───────────────────────────────────────────────

(:wat::core::enum :trading::cache::Request
  (Get
    (probe :wat::holon::HolonAST)
    (reply-tx :trading::cache::GetReplyTx))
  (Put
    (key :wat::holon::HolonAST)
    (val :wat::holon::HolonAST)))

;; ─── Per-broker channel typealiases ─────────────────────────────

(:wat::core::typealias :trading::cache::ReqTx
  :wat::kernel::QueueSender<trading::cache::Request>)

(:wat::core::typealias :trading::cache::ReqRx
  :wat::kernel::QueueReceiver<trading::cache::Request>)

(:wat::core::typealias :trading::cache::ReqTxPool
  :wat::kernel::HandlePool<trading::cache::ReqTx>)

(:wat::core::typealias :trading::cache::Spawn
  :(trading::cache::ReqTxPool,wat::kernel::ProgramHandle<()>))

;; ─── Reporting contract — non-negotiable ───────────────────────
;;
;; Mirrors the archive's request/reply service contract (treasury-
;; program.rs's TreasuryRequest grew from SubmitPaper alone to five
;; variants as needs arose; same shape here, flipped: the SERVICE is
;; the producer, the user's reporter-fn is the consumer):
;;
;;   1. The service DECLARES the typed messages it emits via the
;;      `:trading::cache::Report` enum. Producer-defined.
;;   2. The user provides a `ReportFn` that match-dispatches the
;;      variants to whatever backend they want (sqlite, CloudWatch,
;;      stdout, /dev/null). Consumer-defined.
;;   3. Producer/consumer agree on the variant set; new variants are
;;      additive — the function signature never changes, only the
;;      match grows arms.
;;
;; Service/spawn DEMANDS three injection points:
;;
;;   1. initial-gate :G              — metrics-cadence's starting state
;;   2. metrics-cadence    :CadenceFn<G>     — (gate, stats) -> (gate', fired?)
;;   3. reporter     :ReportFn         — (Report) -> ()
;;
;; Cadence gates the `Metrics` variant specifically — when it fires,
;; the service emits `(Report::Metrics stats)` and resets stats.
;; Future ungated variants (Error / Evicted / Started / Stopped) ride
;; the same callback whenever the service decides to emit them.
;;
;; The user picks G. Common shapes:
;;
;;   G = :()                   null-metrics-cadence (never fires; metrics never emit)
;;   G = :wat::time::Instant   wall-clock rate gate via tick-gate
;;   G = :i64                  counter-mod-N gate
;;
;; All three injection points are required. Pass `()` / null-metrics-cadence /
;; null-reporter for the explicit "no reporting" choice.

(:wat::core::struct :trading::cache::Stats
  (lookups :i64)        ;; total Gets in this window
  (hits :i64)           ;; Gets returning Some
  (misses :i64)         ;; Gets returning :None
  (puts :i64)           ;; total Puts in this window
  (cache-size :i64))    ;; HologramCache/len at gate-fire time

;; Report — discriminated outbound messages the cache emits.
;; Slice 1 ships ONE variant (Metrics, gated by metrics-cadence). Future
;; variants extend the enum without breaking any consumer:
;;   - lifecycle (Started, Stopped)
;;   - errors    (SendFailed, EncodeFailed)
;;   - evictions (LRUEvicted)
;; Each new variant earns its slot when the service has a concrete
;; reason to communicate it. Producer/consumer agree on the variant
;; set; consumers add an arm to their match when a new one ships.
(:wat::core::enum :trading::cache::Report
  (Metrics (stats :trading::cache::Stats)))

;; MetricsCadence<G> — stateful rate gate. Holds the gate state
;; (G, picked by the user) AND the tick function that advances it.
;; Service/maybe-emit calls (tick gate stats) → (gate', fired?), then
;; rebuilds the cadence with the new gate. Same shape pattern as
;; Reporter (the noun) but with state exposed (the cache threads
;; gate through the loop).
(:wat::core::struct :trading::cache::MetricsCadence<G>
  (gate :G)
  (tick :fn(G,trading::cache::Stats)->(G,bool)))

(:wat::core::typealias :trading::cache::Reporter
  :fn(trading::cache::Report)->())

;; null-metrics-cadence — fresh `MetricsCadence<()>` whose tick
;; never fires. Use when metrics are a deliberate opt-out.
(:wat::core::define
  (:trading::cache::null-metrics-cadence
    -> :trading::cache::MetricsCadence<()>)
  (:trading::cache::MetricsCadence/new
    ()
    (:wat::core::lambda
      ((gate :()) (_stats :trading::cache::Stats) -> :((),bool))
      (:wat::core::tuple gate false))))

;; null-reporter — discards every Report variant.
(:wat::core::define
  (:trading::cache::null-reporter
    (_report :trading::cache::Report) -> :())
  ())

;; Fresh zero-counters Stats. Used at startup and after each
;; gate-fire (window-rolling reset, matching the archive's
;; `stats = CacheStats::default()` after emit).
(:wat::core::define
  (:trading::cache::Stats/zero -> :trading::cache::Stats)
  (:trading::cache::Stats/new 0 0 0 0 0))

;; ─── Service state — cache + running stats ─────────────────────
;;
;; Threaded through Service/loop alongside the metrics-cadence's gate. The
;; cache mutates in place (HologramCache is thread-owned mutable);
;; Stats rebuilds each iteration (values-up). Gate is independent
;; of State — caller-typed.

(:wat::core::struct :trading::cache::State
  (cache :wat::holon::lru::HologramCache)
  (stats :trading::cache::Stats))

;; One loop-step's outputs: the post-dispatch State paired with the
;; advanced MetricsCadence. Service/loop and Service/maybe-emit both
;; thread this shape; the alias caps angle-bracket density at the
;; Service layer.
(:wat::core::typealias :trading::cache::Step<G>
  :(trading::cache::State,trading::cache::MetricsCadence<G>))

;; ─── Per-variant request handler ────────────────────────────────
;;
;; Get: filtered-argmax via HologramCache/get; send Option<AST> on
;;      reply-tx. Stats: lookups++, then hits++ or misses++.
;; Put: insert into HologramCache; no reply. Stats: puts++.
;;
;; Returns the new State (cache pointer unchanged — mutates in
;; place; stats rebuilt).

(:wat::core::define
  (:trading::cache::Service/handle
    (req :trading::cache::Request)
    (state :trading::cache::State)
    -> :trading::cache::State)
  (:wat::core::let*
    (((cache :wat::holon::lru::HologramCache) (:trading::cache::State/cache state))
     ((stats :trading::cache::Stats) (:trading::cache::State/stats state)))
    (:wat::core::match req -> :trading::cache::State
      ((:trading::cache::Request::Get probe reply-tx)
        (:wat::core::let*
          (((result :Option<wat::holon::HolonAST>)
            (:wat::holon::lru::HologramCache/get cache probe))
           ((_send :wat::kernel::Sent)
            (:wat::kernel::send reply-tx result))
           ((hit-delta :i64)
            (:wat::core::match result -> :i64
              ((Some _) 1)
              (:None 0)))
           ((miss-delta :i64)
            (:wat::core::i64::- 1 hit-delta))
           ((stats' :trading::cache::Stats)
            (:trading::cache::Stats/new
              (:wat::core::i64::+ (:trading::cache::Stats/lookups stats) 1)
              (:wat::core::i64::+ (:trading::cache::Stats/hits stats) hit-delta)
              (:wat::core::i64::+ (:trading::cache::Stats/misses stats) miss-delta)
              (:trading::cache::Stats/puts stats)
              (:trading::cache::Stats/cache-size stats))))
          (:trading::cache::State/new cache stats')))
      ((:trading::cache::Request::Put key val)
        (:wat::core::let*
          (((_ :()) (:wat::holon::lru::HologramCache/put cache key val))
           ((stats' :trading::cache::Stats)
            (:trading::cache::Stats/new
              (:trading::cache::Stats/lookups stats)
              (:trading::cache::Stats/hits stats)
              (:trading::cache::Stats/misses stats)
              (:wat::core::i64::+ (:trading::cache::Stats/puts stats) 1)
              (:trading::cache::Stats/cache-size stats))))
          (:trading::cache::State/new cache stats'))))))

;; ─── Tick the metrics window — advance gate, emit+reset on fire ──
;;
;; Always: pull stats from State, tick the cadence (gate → gate'),
;; rebuild the cadence struct with the advanced gate. The cadence
;; never freezes; every call moves it forward.
;;
;; On fire: stamp cache-size onto the stats, send
;; `(Report::Metrics final-stats)` through the reporter, reset the
;; running stats. Returns the post-emit State + advanced cadence.
;;
;; On no-fire: state unchanged, cadence advanced. The window stays
;; open; counters keep accumulating.

(:wat::core::define
  (:trading::cache::Service/tick-window<G>
    (state :trading::cache::State)
    (reporter :trading::cache::Reporter)
    (metrics-cadence :trading::cache::MetricsCadence<G>)
    -> :trading::cache::Step<G>)
  (:wat::core::let*
    (((stats :trading::cache::Stats) (:trading::cache::State/stats state))
     ((gate :G) (:trading::cache::MetricsCadence/gate metrics-cadence))
     ((tick-fn :fn(G,trading::cache::Stats)->(G,bool))
      (:trading::cache::MetricsCadence/tick metrics-cadence))
     ((tick :(G,bool)) (tick-fn gate stats))
     ((gate' :G) (:wat::core::first tick))
     ((fired :bool) (:wat::core::second tick))
     ((cadence' :trading::cache::MetricsCadence<G>)
      (:trading::cache::MetricsCadence/new gate' tick-fn)))
    (:wat::core::if fired -> :trading::cache::Step<G>
      (:wat::core::let*
        (((cache :wat::holon::lru::HologramCache) (:trading::cache::State/cache state))
         ((final-stats :trading::cache::Stats)
          (:trading::cache::Stats/new
            (:trading::cache::Stats/lookups stats)
            (:trading::cache::Stats/hits stats)
            (:trading::cache::Stats/misses stats)
            (:trading::cache::Stats/puts stats)
            (:wat::holon::lru::HologramCache/len cache)))
         ((_ :()) (reporter (:trading::cache::Report::Metrics final-stats)))
         ((state' :trading::cache::State)
          (:trading::cache::State/new cache (:trading::cache::Stats/zero))))
        (:wat::core::tuple state' cadence'))
      (:wat::core::tuple state cadence'))))

;; ─── Driver loop — select + dispatch + gate-check ──────────────
;;
;; Same shape as service-template's Service/loop with metrics-cadence
;; (a stateful MetricsCadence struct) + reporter threaded through.
;; Empty rxs → exit with final state. Otherwise: select; on Some(req)
;; dispatch + maybe-emit + recurse; on :None prune the closed channel
;; and recurse. The cadence's gate updates each iteration via
;; MetricsCadence/new with the new gate value; the tick function
;; itself is invariant across the loop.

(:wat::core::define
  (:trading::cache::Service/loop<G>
    (req-rxs :Vec<trading::cache::ReqRx>)
    (state :trading::cache::State)
    (reporter :trading::cache::Reporter)
    (metrics-cadence :trading::cache::MetricsCadence<G>)
    -> :trading::cache::State)
  (:wat::core::if (:wat::core::empty? req-rxs) -> :trading::cache::State
    state
    (:wat::core::let*
      (((chosen :wat::kernel::Chosen<trading::cache::Request>)
        (:wat::kernel::select req-rxs))
       ((idx :i64) (:wat::core::first chosen))
       ((maybe :Option<trading::cache::Request>) (:wat::core::second chosen)))
      (:wat::core::match maybe -> :trading::cache::State
        ((Some req)
          (:wat::core::let*
            (((after-handle :trading::cache::State)
              (:trading::cache::Service/handle req state))
             ((step :trading::cache::Step<G>)
              (:trading::cache::Service/tick-window
                after-handle reporter metrics-cadence))
             ((next-state :trading::cache::State)
              (:wat::core::first step))
             ((cadence' :trading::cache::MetricsCadence<G>)
              (:wat::core::second step)))
            (:trading::cache::Service/loop
              req-rxs next-state reporter cadence')))
        (:None
          (:trading::cache::Service/loop
            (:wat::std::list::remove-at req-rxs idx)
            state reporter metrics-cadence))))))

;; ─── Worker entry — owns the cache for its full lifetime ──────
;;
;; HologramCache's underlying LocalCache is thread-owned (lives in a
;; ThreadOwnedCell), so the cache MUST stay on the worker thread.
;; Service/run wraps Service/loop so the spawned handle resolves
;; to :() — caller-friendly type.

(:wat::core::define
  (:trading::cache::Service/run<G>
    (req-rxs :Vec<trading::cache::ReqRx>)
    (cap :i64)
    (reporter :trading::cache::Reporter)
    (metrics-cadence :trading::cache::MetricsCadence<G>)
    -> :())
  (:wat::core::let*
    (((cache :wat::holon::lru::HologramCache)
      (:wat::holon::lru::HologramCache/make
        (:wat::holon::filter-coincident)
        cap))
     ((initial :trading::cache::State)
      (:trading::cache::State/new cache (:trading::cache::Stats/zero)))
     ((_final :trading::cache::State)
      (:trading::cache::Service/loop
        req-rxs initial reporter metrics-cadence)))
    ()))

;; ─── Service/spawn — the constructor ─────────────────────────
;;
;; Build N bounded request channels (capacity 1 each — back-pressure
;; under load), pool the senders (HandlePool's orphan detector
;; surfaces over/under-claim at finish), spawn the driver with a
;; fresh HologramCache and the user-supplied (reporter, metrics-cadence)
;; pair.
;;
;; Both injection points are non-negotiable. Pass
;; `(:trading::cache::null-reporter)` and
;; `(:trading::cache::null-metrics-cadence)` for the explicit
;; "no reporting" choice; pass real values for real reporting
;; (e.g., a reporter that match-dispatches Report variants to
;; sqlite / CloudWatch + a tick-gate-shaped MetricsCadence with
;; an Instant gate).

(:wat::core::define
  (:trading::cache::Service/spawn<G>
    (count :i64)
    (cap :i64)
    (reporter :trading::cache::Reporter)
    (metrics-cadence :trading::cache::MetricsCadence<G>)
    -> :trading::cache::Spawn)
  (:wat::core::let*
    (((pairs :Vec<wat::kernel::QueuePair<trading::cache::Request>>)
      (:wat::core::map
        (:wat::core::range 0 count)
        (:wat::core::lambda
          ((_i :i64)
           -> :wat::kernel::QueuePair<trading::cache::Request>)
          (:wat::kernel::make-bounded-queue :trading::cache::Request 1))))
     ((req-txs :Vec<trading::cache::ReqTx>)
      (:wat::core::map pairs
        (:wat::core::lambda
          ((p :wat::kernel::QueuePair<trading::cache::Request>)
           -> :trading::cache::ReqTx)
          (:wat::core::first p))))
     ((req-rxs :Vec<trading::cache::ReqRx>)
      (:wat::core::map pairs
        (:wat::core::lambda
          ((p :wat::kernel::QueuePair<trading::cache::Request>)
           -> :trading::cache::ReqRx)
          (:wat::core::second p))))
     ((pool :trading::cache::ReqTxPool)
      (:wat::kernel::HandlePool::new "trading-cache" req-txs))
     ((driver :wat::kernel::ProgramHandle<()>)
      (:wat::kernel::spawn :trading::cache::Service/run
        req-rxs cap reporter metrics-cadence)))
    (:wat::core::tuple pool driver)))
