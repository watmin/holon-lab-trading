;; wat-tests-integ/experiment/008-treasury-program/explore-treasury.wat
;;
;; Treasury skeleton, built up from the smallest pieces. explore-handles.wat
;; proved the substrate (spawn/join, channels, scope-based close, select,
;; HandlePool, struct accumulator). This file builds the Treasury domain
;; on top of that proven foundation, one step at a time.
;;
;; Namespace: `:exp::*`. Experiments are a reference for future code, not
;; a production registration — keep names short so future readers grok
;; the SHAPE without being buried in the path.
;;
;; T1 — empty Service shell with single-variant Request enum (Ping)
;;      and ack-only handler. Proves: Service constructor returns
;;      (pool, driver); driver routes by variant; per-request reply-tx
;;      idiom round-trips ack; nested-scope shutdown still works.
;; T2 — add a second variant (Tick — fire-and-forget; no reply).
;; T3 — add the State struct accumulator.
;; T4+ — replace Ping/Tick with real Treasury verbs (SubmitPaper,
;;       SubmitExit, Tick-with-state-mutation), filling in bodies
;;       one at a time.

(:wat::test::make-deftest :deftest
  (;; State — what the Service driver carries between iterations.
   ;; Each handler returns a NEW State (values discipline; no in-place
   ;; mutation, per the AtrWindow::push idiom). The worker returns the
   ;; final State at shutdown so callers can verify counts via
   ;; join-result. Two fields for T3 — placeholder counts that prove
   ;; both reply-bearing and fire-and-forget variants update state.
   ;; Paper — a virtual position the Treasury has opened. T6 is the
   ;; first real Treasury domain struct. Just (id, amount) for now;
   ;; future fields: entry-price, deadline, exit-target, etc.
   (:wat::core::struct :exp::Paper
     (id :i64)
     (amount :i64))

   ;;
   ;; T1-T4a established the SHAPE with two placeholder counters.
   ;; T5 added `last-price` (real Treasury field — tracks most recent Tick).
   ;; T6 adds `open-papers` (the papers themselves) and `next-paper-id`
   ;; (monotonic ID source — next ID to hand out).
   ;;
   ;; State::fresh absorbs new fields — existing deftests that only
   ;; check counters keep working unchanged.
   (:wat::core::struct :exp::State
     (tick-count    :i64)
     (ping-count    :i64)
     (last-price    :Option<f64>)
     (open-papers   :Vec<exp::Paper>)
     (next-paper-id :i64))

   ;; Convenience constructor — zero counts, no observed price, no
   ;; open papers, ID counter starts at 0.
   (:wat::core::define
     (:exp::State::fresh -> :exp::State)
     (:exp::State/new 0 0 :None (:wat::core::vec :exp::Paper) 0))

   ;; Reply channel — for T1 the worker only needs to ack receipt.
   ;; T4+ will swap () for real Verdict / PositionReceipt types.
   (:wat::core::typealias :exp::ReplyTx :wat::kernel::QueueSender<()>)
   (:wat::core::typealias :exp::ReplyRx :wat::kernel::QueueReceiver<()>)

   ;; Request — enum variants embed their own reply-tx so the driver
   ;; can route responses without a sender-index map. CacheService
   ;; uses this exact shape in wat-rs/crates/wat-lru/wat/lru/CacheService.wat.
   ;;
   ;; Three reply shapes prove the dispatch table can hold any
   ;; combination — every in-memory request/reply service is some
   ;; permutation of these three:
   ;;   Ping(reply-tx)     — request/response with unit ack
   ;;   Tick(price)        — fire-and-forget; no reply channel
   ;;   Snapshot(reply-tx) — read-only state query; reply carries the
   ;;                        full domain state struct
   ;;
   ;; Treasury's real verbs will follow the same split: SubmitPaper /
   ;; SubmitExit carry reply-tx for receipts; Tick is the silent clock;
   ;; an inspect/get-treasury verb will follow the Snapshot pattern.
   (:wat::core::enum :exp::Request
     (Ping      (reply-tx :exp::ReplyTx))
     (Tick      (price :f64))
     (Snapshot  (reply-tx :wat::kernel::QueueSender<exp::State>))
     (OpenPaper (amount :i64)
                (reply-tx :wat::kernel::QueueSender<i64>)))

   ;; Per-broker request channel typealiases.
   (:wat::core::typealias :exp::ReqTx :wat::kernel::QueueSender<exp::Request>)
   (:wat::core::typealias :exp::ReqRx :wat::kernel::QueueReceiver<exp::Request>)
   (:wat::core::typealias :exp::ReqTxPool :wat::kernel::HandlePool<exp::ReqTx>)
   ;; Spawn — what the constructor returns. The driver's ProgramHandle
   ;; is parameterized by State (T3 lift): join-result yields the
   ;; final State so callers can read its fields.
   (:wat::core::typealias :exp::Spawn
     :(exp::ReqTxPool,wat::kernel::ProgramHandle<exp::State>))


   ;; ─── Service driver loop ─────────────────────────────────────
   ;;
   ;; select over Vec<ReqRx>; on Some(req) match the Request variant
   ;; and dispatch — handler returns a NEW state that carries forward
   ;; into the next iteration. On :None for any rx, prune that channel
   ;; and recurse with state unchanged. Exit when the Vec is empty;
   ;; return the final state via the spawn-thread's return value, so
   ;; callers reading via join-result can verify what happened.
   (:wat::core::define
     (:exp::Service/loop
       (req-rxs :Vec<exp::ReqRx>)
       (state :exp::State)
       -> :exp::State)
     (:wat::core::if (:wat::core::empty? req-rxs) -> :exp::State
       state
       (:wat::core::let*
         (((chosen :wat::kernel::Chosen<exp::Request>) (:wat::kernel::select req-rxs))
          ((idx :i64) (:wat::core::first chosen))
          ((maybe :Option<exp::Request>) (:wat::core::second chosen)))
         (:wat::core::match maybe -> :exp::State
           ((Some req)
             (:wat::core::let*
               (((next :exp::State) (:exp::Service/handle req state)))
               (:exp::Service/loop req-rxs next)))
           (:None
             (:exp::Service/loop (:wat::std::list::remove-at req-rxs idx) state))))))

   ;; Per-request dispatch — match the Request variant, do its work,
   ;; return the new state. Lives as a separate define so each variant's
   ;; body grows independently as we fill them in.
   ;;
   ;; T1 added Ping → ack on embedded reply-tx.
   ;; T2 added Tick → no-op (silent integration).
   ;; T3 lifted both arms to return a NEW state with a counter bumped.
   ;; T4a adds Snapshot → send the current state on reply-tx and
   ;; return state UNCHANGED (read-only verb; the read does not bump
   ;; any counter).
   (:wat::core::define
     (:exp::Service/handle
       (req :exp::Request)
       (state :exp::State)
       -> :exp::State)
     (:wat::core::match req -> :exp::State
       ((:exp::Request::Ping reply-tx)
         (:wat::core::let*
           (((_ack :wat::kernel::Sent) (:wat::kernel::send reply-tx ())))
           (:exp::State/new
             (:exp::State/tick-count state)
             (:wat::core::+ (:exp::State/ping-count state) 1)
             (:exp::State/last-price state)
             (:exp::State/open-papers state)
             (:exp::State/next-paper-id state))))
       ;; T5: Tick now does real work — store the price as last-price
       ;; alongside bumping tick-count. This is the first placeholder
       ;; field that became domain.
       ((:exp::Request::Tick price)
         (:exp::State/new
           (:wat::core::+ (:exp::State/tick-count state) 1)
           (:exp::State/ping-count state)
           (Some price)
           (:exp::State/open-papers state)
           (:exp::State/next-paper-id state)))
       ((:exp::Request::Snapshot reply-tx)
         (:wat::core::let*
           (((_send :wat::kernel::Sent) (:wat::kernel::send reply-tx state)))
           state))
       ;; T6: OpenPaper — first real Treasury verb.
       ;;   - Mint a new id from next-paper-id (state-as-ID-source)
       ;;   - Build a Paper, append to open-papers (Vec immutable update via conj)
       ;;   - Send the new id back on reply-tx (caller now holds the handle to this paper)
       ;;   - Increment next-paper-id so the next OpenPaper gets a fresh id
       ((:exp::Request::OpenPaper amount reply-tx)
         (:wat::core::let*
           (((id :i64) (:exp::State/next-paper-id state))
            ((paper :exp::Paper) (:exp::Paper/new id amount))
            ((papers' :Vec<exp::Paper>)
             (:wat::core::conj (:exp::State/open-papers state) paper))
            ((_send :wat::kernel::Sent) (:wat::kernel::send reply-tx id)))
           (:exp::State/new
             (:exp::State/tick-count state)
             (:exp::State/ping-count state)
             (:exp::State/last-price state)
             papers'
             (:wat::core::+ id 1))))))

   ;; ─── Service constructor ─────────────────────────────────────
   ;;
   ;; Build N request channels, pool the senders (orphan detector at
   ;; construction), spawn the driver with the receivers Vec, return
   ;; (pool, driver). This is the canonical service-program shape per
   ;; SERVICE-PROGRAMS.md "the full service template".
   (:wat::core::define
     (:exp::Service (count :i64) -> :exp::Spawn)
     (:wat::core::let*
       (((pairs :Vec<wat::kernel::QueuePair<exp::Request>>)
         (:wat::core::map
           (:wat::core::range 0 count)
           (:wat::core::lambda ((_i :i64) -> :wat::kernel::QueuePair<exp::Request>)
             (:wat::kernel::make-bounded-queue :exp::Request 1))))

        ((req-txs :Vec<exp::ReqTx>)
         (:wat::core::map pairs
           (:wat::core::lambda ((p :wat::kernel::QueuePair<exp::Request>) -> :exp::ReqTx)
             (:wat::core::first p))))

        ((req-rxs :Vec<exp::ReqRx>)
         (:wat::core::map pairs
           (:wat::core::lambda ((p :wat::kernel::QueuePair<exp::Request>) -> :exp::ReqRx)
             (:wat::core::second p))))

        ((pool :exp::ReqTxPool)
         (:wat::kernel::HandlePool::new "treasury" req-txs))

        ((driver :wat::kernel::ProgramHandle<exp::State>)
         (:wat::kernel::spawn :exp::Service/loop req-rxs (:exp::State::fresh))))
       (:wat::core::tuple pool driver)))))


;; ─── T1 — single Ping round-trip through the Service ──────────
;;
;; Smallest end-to-end Treasury proof: spawn the Service with one
;; broker handle, pop it, send a Ping (carrying our own reply-rx side),
;; recv the ack, exit. Outer scope holds the driver handle; inner scope
;; owns the popped req-tx + the reply-pair. When inner exits, every
;; client-side Sender drops; the driver's last rx disconnects; the
;; loop exits; the outer join unblocks.

(:deftest :exp::t1-ping-roundtrip
  (:wat::core::let*
    (((spawn :exp::Spawn) (:exp::Service 1))
     ((pool :exp::ReqTxPool) (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<exp::State>) (:wat::core::second spawn))

     ;; Inner scope owns the popped handle and the reply channel.
     ;; All client-side Senders die when this scope exits.
     ((_inner :())
      (:wat::core::let*
        (((req-tx :exp::ReqTx) (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))

         ((reply-pair :wat::kernel::QueuePair<()>)
          (:wat::kernel::make-bounded-queue :() 1))
         ((reply-tx :exp::ReplyTx) (:wat::core::first reply-pair))
         ((reply-rx :exp::ReplyRx) (:wat::core::second reply-pair))

         ;; Send Ping carrying our reply-tx; driver acks; we recv.
         ((_send :wat::kernel::Sent)
          (:wat::kernel::send req-tx (:exp::Request::Ping reply-tx)))
         ((got :wat::kernel::Sent) (:wat::kernel::recv reply-rx))
         ((_check :())
          (:wat::core::match got -> :()
            ((Some _) ())
            (:None (:wat::test::assert-eq "no-ack" "")))))
        ()))

     ;; Inner scope exited → req-tx + reply-tx dropped → driver's only
     ;; ReqRx disconnected → Service/loop pruned the rx, Vec empty,
     ;; loop exited. join is the bookend.
     ((_join :exp::State) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))


;; ─── T2 — Tick interleaved with Ping (mixed-shape variants) ───
;;
;; Send Tick (no reply expected), then Ping (recv ack), then Tick
;; again. Proves the dispatch table holds variants of different reply
;; shapes — fire-and-forget interleaved with request/response — and
;; that the Tick arm doesn't accidentally try to use a reply channel
;; that isn't there. Same shutdown story as T1.

(:deftest :exp::t2-tick-interleaved
  (:wat::core::let*
    (((spawn :exp::Spawn) (:exp::Service 1))
     ((pool :exp::ReqTxPool) (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<exp::State>) (:wat::core::second spawn))

     ((_inner :())
      (:wat::core::let*
        (((req-tx :exp::ReqTx) (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))

         ((reply-pair :wat::kernel::QueuePair<()>)
          (:wat::kernel::make-bounded-queue :() 1))
         ((reply-tx :exp::ReplyTx) (:wat::core::first reply-pair))
         ((reply-rx :exp::ReplyRx) (:wat::core::second reply-pair))

         ;; Tick first — no reply channel, no recv. Worker silently
         ;; consumes. bounded(1) means this send returns once the
         ;; worker has dequeued.
         ((_t1 :wat::kernel::Sent)
          (:wat::kernel::send req-tx (:exp::Request::Tick 100.0)))

         ;; Ping — reply round-trip.
         ((_p :wat::kernel::Sent)
          (:wat::kernel::send req-tx (:exp::Request::Ping reply-tx)))
         ((got :wat::kernel::Sent) (:wat::kernel::recv reply-rx))
         ((_check :())
          (:wat::core::match got -> :()
            ((Some _) ())
            (:None (:wat::test::assert-eq "no-ack" ""))))

         ;; Tick again — proves the dispatch returns to a clean state
         ;; after a reply-bearing variant.
         ((_t2 :wat::kernel::Sent)
          (:wat::kernel::send req-tx (:exp::Request::Tick 101.0))))
        ()))

     ((_join :exp::State) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))


;; ─── T3 — state struct accumulator: counts survive shutdown ───
;;
;; Send 3 Ticks + 2 Pings. Use join-result instead of join so we can
;; read the final State and assert on its fields. Expect:
;;   tick-count = 3
;;   ping-count = 2
;;
;; Same nested-scope shutdown story; the only new thing is that the
;; spawn-thread's return value is the carry-along State, observable
;; once all client-side Senders have dropped.

(:deftest :exp::t3-state-accumulator
  (:wat::core::let*
    (((spawn :exp::Spawn) (:exp::Service 1))
     ((pool :exp::ReqTxPool) (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<exp::State>) (:wat::core::second spawn))

     ((_inner :())
      (:wat::core::let*
        (((req-tx :exp::ReqTx) (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))

         ((reply-pair :wat::kernel::QueuePair<()>)
          (:wat::kernel::make-bounded-queue :() 1))
         ((reply-tx :exp::ReplyTx) (:wat::core::first reply-pair))
         ((reply-rx :exp::ReplyRx) (:wat::core::second reply-pair))

         ;; 3 Ticks (fire-and-forget — bumps tick-count each time).
         ((_t1 :wat::kernel::Sent) (:wat::kernel::send req-tx (:exp::Request::Tick 100.0)))
         ((_t2 :wat::kernel::Sent) (:wat::kernel::send req-tx (:exp::Request::Tick 101.0)))
         ((_t3 :wat::kernel::Sent) (:wat::kernel::send req-tx (:exp::Request::Tick 102.0)))

         ;; 2 Pings — each acks AND bumps ping-count. Recv ack between
         ;; sends so reply-tx isn't backpressuring.
         ((_p1 :wat::kernel::Sent) (:wat::kernel::send req-tx (:exp::Request::Ping reply-tx)))
         ((_a1 :wat::kernel::Sent) (:wat::kernel::recv reply-rx))
         ((_p2 :wat::kernel::Sent) (:wat::kernel::send req-tx (:exp::Request::Ping reply-tx)))
         ((_a2 :wat::kernel::Sent) (:wat::kernel::recv reply-rx)))
        ()))

     ;; Inner exited; client Senders dropped; loop returned final State.
     ((result :Result<exp::State,wat::kernel::ThreadDiedError>)
      (:wat::kernel::join-result driver)))
    (:wat::core::match result -> :()
      ((Ok state)
        (:wat::core::let*
          (((tc :i64) (:exp::State/tick-count state))
           ((pc :i64) (:exp::State/ping-count state))
           ((_check-tc :())
            (:wat::core::if (:wat::core::= tc 3) -> :()
              ()
              (:wat::test::assert-eq
                (:wat::core::string::concat
                  "expected tick-count 3, got "
                  (:wat::core::i64::to-string tc))
                ""))))
          (:wat::core::if (:wat::core::= pc 2) -> :()
            ()
            (:wat::test::assert-eq
              (:wat::core::string::concat
                "expected ping-count 2, got "
                (:wat::core::i64::to-string pc))
              ""))))
      ((Err _) (:wat::test::assert-eq "driver-died" "")))))


;; ─── T4a — state-reading verb (Snapshot reply carries the State) ─
;;
;; Drive state to a known shape (1 Tick, 1 Ping), then ask for a
;; Snapshot — the reply rides back as a full :exp::State struct.
;; Assert the snapshot fields match. Then issue another Tick and
;; another Snapshot — the second snapshot should reflect the bump,
;; proving Snapshot reads LIVE state (not a frozen capture).
;;
;; New shape this proves: a reply channel whose payload is a domain
;; struct, not just () or a scalar. The caller's reply-pair carries
;; :exp::State end-to-end. Pattern lifts directly to Treasury verbs
;; that hand back PositionReceipt / Verdict / TreasuryRecord.

(:deftest :exp::t4a-snapshot
  (:wat::core::let*
    (((spawn :exp::Spawn) (:exp::Service 1))
     ((pool :exp::ReqTxPool) (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<exp::State>) (:wat::core::second spawn))

     ((_inner :())
      (:wat::core::let*
        (((req-tx :exp::ReqTx) (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))

         ;; Ack channel for Ping.
         ((ack-pair :wat::kernel::QueuePair<()>)
          (:wat::kernel::make-bounded-queue :() 1))
         ((ack-tx :exp::ReplyTx) (:wat::core::first ack-pair))
         ((ack-rx :exp::ReplyRx) (:wat::core::second ack-pair))

         ;; Snapshot channel — carries the full State.
         ((snap-pair :wat::kernel::QueuePair<exp::State>)
          (:wat::kernel::make-bounded-queue :exp::State 1))
         ((snap-tx :wat::kernel::QueueSender<exp::State>)
          (:wat::core::first snap-pair))
         ((snap-rx :wat::kernel::QueueReceiver<exp::State>)
          (:wat::core::second snap-pair))

         ;; Drive state: 1 Tick + 1 Ping.
         ((_t1 :wat::kernel::Sent) (:wat::kernel::send req-tx (:exp::Request::Tick 100.0)))
         ((_p1 :wat::kernel::Sent) (:wat::kernel::send req-tx (:exp::Request::Ping ack-tx)))
         ((_a1 :wat::kernel::Sent) (:wat::kernel::recv ack-rx))

         ;; First Snapshot — expect (tick=1, ping=1).
         ((_s1 :wat::kernel::Sent) (:wat::kernel::send req-tx (:exp::Request::Snapshot snap-tx)))
         ((snap1 :Option<exp::State>) (:wat::kernel::recv snap-rx))
         ((_check1 :())
          (:wat::core::match snap1 -> :()
            ((Some s)
              (:wat::core::let*
                (((tc :i64) (:exp::State/tick-count s))
                 ((pc :i64) (:exp::State/ping-count s))
                 ((_t :())
                  (:wat::core::if (:wat::core::= tc 1) -> :()
                    ()
                    (:wat::test::assert-eq "snap1 tick != 1" ""))))
                (:wat::core::if (:wat::core::= pc 1) -> :()
                  ()
                  (:wat::test::assert-eq "snap1 ping != 1" ""))))
            (:None (:wat::test::assert-eq "no snap1" ""))))

         ;; One more Tick, then Snapshot again — expect (tick=2, ping=1).
         ;; Confirms Snapshot reads LIVE state, not a frozen value.
         ((_t2 :wat::kernel::Sent) (:wat::kernel::send req-tx (:exp::Request::Tick 101.0)))
         ((_s2 :wat::kernel::Sent) (:wat::kernel::send req-tx (:exp::Request::Snapshot snap-tx)))
         ((snap2 :Option<exp::State>) (:wat::kernel::recv snap-rx))
         ((_check2 :())
          (:wat::core::match snap2 -> :()
            ((Some s)
              (:wat::core::let*
                (((tc :i64) (:exp::State/tick-count s))
                 ((pc :i64) (:exp::State/ping-count s))
                 ((_t :())
                  (:wat::core::if (:wat::core::= tc 2) -> :()
                    ()
                    (:wat::test::assert-eq "snap2 tick != 2" ""))))
                (:wat::core::if (:wat::core::= pc 1) -> :()
                  ()
                  (:wat::test::assert-eq "snap2 ping != 1" ""))))
            (:None (:wat::test::assert-eq "no snap2" "")))))
        ()))

     ((_join :exp::State) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))


;; ─── T5 — first real domain field: last-price ─────────────────
;;
;; Tick handler now meaningfully uses its `price` arg — stores it as
;; the State's `last-price` field. Send three Ticks at distinct prices,
;; Snapshot in between, verify last-price tracks the most recent.
;;
;; This is the first placeholder-to-real transition: counters stay for
;; the existing assertions, but a real Treasury field lives alongside.
;; T6+ continues the pattern — replace placeholder fields with real
;; ones, replace placeholder verbs with Treasury verbs.

(:deftest :exp::t5-last-price-tracking
  (:wat::core::let*
    (((spawn :exp::Spawn) (:exp::Service 1))
     ((pool :exp::ReqTxPool) (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<exp::State>) (:wat::core::second spawn))

     ((_inner :())
      (:wat::core::let*
        (((req-tx :exp::ReqTx) (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))

         ((snap-pair :wat::kernel::QueuePair<exp::State>)
          (:wat::kernel::make-bounded-queue :exp::State 1))
         ((snap-tx :wat::kernel::QueueSender<exp::State>)
          (:wat::core::first snap-pair))
         ((snap-rx :wat::kernel::QueueReceiver<exp::State>)
          (:wat::core::second snap-pair))

         ;; Pre-Tick: Snapshot should reveal last-price = :None.
         ((_g0 :wat::kernel::Sent)
          (:wat::kernel::send req-tx (:exp::Request::Snapshot snap-tx)))
         ((snap0 :Option<exp::State>) (:wat::kernel::recv snap-rx))
         ((_check0 :())
          (:wat::core::match snap0 -> :()
            ((Some s)
              (:wat::core::match (:exp::State/last-price s) -> :()
                (:None ())
                ((Some _) (:wat::test::assert-eq "snap0 should be :None" ""))))
            (:None (:wat::test::assert-eq "no snap0" ""))))

         ;; Tick at 100.0; Snapshot; expect Some 100.0.
         ((_t1 :wat::kernel::Sent)
          (:wat::kernel::send req-tx (:exp::Request::Tick 100.0)))
         ((_g1 :wat::kernel::Sent)
          (:wat::kernel::send req-tx (:exp::Request::Snapshot snap-tx)))
         ((snap1 :Option<exp::State>) (:wat::kernel::recv snap-rx))
         ((_check1 :())
          (:wat::core::match snap1 -> :()
            ((Some s)
              (:wat::core::match (:exp::State/last-price s) -> :()
                ((Some p)
                  (:wat::core::if (:wat::core::f64::= p 100.0) -> :()
                    ()
                    (:wat::test::assert-eq "snap1 last-price != 100.0" "")))
                (:None (:wat::test::assert-eq "snap1 last-price is None" ""))))
            (:None (:wat::test::assert-eq "no snap1" ""))))

         ;; Two more Ticks at 101.0 and 102.0; final Snapshot; expect 102.0.
         ((_t2 :wat::kernel::Sent)
          (:wat::kernel::send req-tx (:exp::Request::Tick 101.0)))
         ((_t3 :wat::kernel::Sent)
          (:wat::kernel::send req-tx (:exp::Request::Tick 102.0)))
         ((_g2 :wat::kernel::Sent)
          (:wat::kernel::send req-tx (:exp::Request::Snapshot snap-tx)))
         ((snap2 :Option<exp::State>) (:wat::kernel::recv snap-rx))
         ((_check2 :())
          (:wat::core::match snap2 -> :()
            ((Some s)
              (:wat::core::match (:exp::State/last-price s) -> :()
                ((Some p)
                  (:wat::core::if (:wat::core::f64::= p 102.0) -> :()
                    ()
                    (:wat::test::assert-eq "snap2 last-price != 102.0" "")))
                (:None (:wat::test::assert-eq "snap2 last-price is None" ""))))
            (:None (:wat::test::assert-eq "no snap2" "")))))
        ()))

     ((_join :exp::State) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))


;; ─── T6 — first real Treasury verb: OpenPaper ─────────────────
;;
;; OpenPaper(amount, reply-tx) mints a fresh paper-id, builds a Paper,
;; appends to open-papers, sends the id back. Three patterns surface
;; that recur in any registry-shaped service:
;;   - state-as-ID-source (next-paper-id counter in State)
;;   - Vec<DomainStruct> immutable update (conj papers new-paper)
;;   - reply type that's a generated scalar (PaperId), not state echo
;;
;; Send three OpenPaper calls; expect IDs 0, 1, 2 in order. Snapshot;
;; verify open-papers length = 3 and next-paper-id = 3.

(:deftest :exp::t6-open-paper
  (:wat::core::let*
    (((spawn :exp::Spawn) (:exp::Service 1))
     ((pool :exp::ReqTxPool) (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<exp::State>) (:wat::core::second spawn))

     ((_inner :())
      (:wat::core::let*
        (((req-tx :exp::ReqTx) (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))

         ;; OpenPaper's reply channel — carries the new paper-id.
         ((id-pair :wat::kernel::QueuePair<i64>)
          (:wat::kernel::make-bounded-queue :i64 1))
         ((id-tx :wat::kernel::QueueSender<i64>) (:wat::core::first id-pair))
         ((id-rx :wat::kernel::QueueReceiver<i64>) (:wat::core::second id-pair))

         ;; Snapshot channel — to verify final state shape.
         ((snap-pair :wat::kernel::QueuePair<exp::State>)
          (:wat::kernel::make-bounded-queue :exp::State 1))
         ((snap-tx :wat::kernel::QueueSender<exp::State>)
          (:wat::core::first snap-pair))
         ((snap-rx :wat::kernel::QueueReceiver<exp::State>)
          (:wat::core::second snap-pair))

         ;; Three OpenPaper calls — expect IDs 0, 1, 2 in order.
         ((_o1 :wat::kernel::Sent)
          (:wat::kernel::send req-tx (:exp::Request::OpenPaper 100 id-tx)))
         ((id1 :Option<i64>) (:wat::kernel::recv id-rx))
         ((_check1 :())
          (:wat::core::match id1 -> :()
            ((Some 0) ())
            ((Some n)
              (:wat::test::assert-eq
                (:wat::core::string::concat
                  "expected first id 0, got "
                  (:wat::core::i64::to-string n))
                ""))
            (:None (:wat::test::assert-eq "no id1" ""))))

         ((_o2 :wat::kernel::Sent)
          (:wat::kernel::send req-tx (:exp::Request::OpenPaper 200 id-tx)))
         ((id2 :Option<i64>) (:wat::kernel::recv id-rx))
         ((_check2 :())
          (:wat::core::match id2 -> :()
            ((Some 1) ())
            ((Some n)
              (:wat::test::assert-eq
                (:wat::core::string::concat
                  "expected second id 1, got "
                  (:wat::core::i64::to-string n))
                ""))
            (:None (:wat::test::assert-eq "no id2" ""))))

         ((_o3 :wat::kernel::Sent)
          (:wat::kernel::send req-tx (:exp::Request::OpenPaper 300 id-tx)))
         ((id3 :Option<i64>) (:wat::kernel::recv id-rx))
         ((_check3 :())
          (:wat::core::match id3 -> :()
            ((Some 2) ())
            ((Some n)
              (:wat::test::assert-eq
                (:wat::core::string::concat
                  "expected third id 2, got "
                  (:wat::core::i64::to-string n))
                ""))
            (:None (:wat::test::assert-eq "no id3" ""))))

         ;; Snapshot — verify open-papers length = 3 and next-paper-id = 3.
         ((_g :wat::kernel::Sent)
          (:wat::kernel::send req-tx (:exp::Request::Snapshot snap-tx)))
         ((snap :Option<exp::State>) (:wat::kernel::recv snap-rx))
         ((_check-snap :())
          (:wat::core::match snap -> :()
            ((Some s)
              (:wat::core::let*
                (((papers :Vec<exp::Paper>) (:exp::State/open-papers s))
                 ((len :i64) (:wat::core::length papers))
                 ((next-id :i64) (:exp::State/next-paper-id s))
                 ((_ :())
                  (:wat::core::if (:wat::core::= len 3) -> :()
                    ()
                    (:wat::test::assert-eq
                      (:wat::core::string::concat
                        "expected 3 papers, got "
                        (:wat::core::i64::to-string len))
                      ""))))
                (:wat::core::if (:wat::core::= next-id 3) -> :()
                  ()
                  (:wat::test::assert-eq
                    (:wat::core::string::concat
                      "expected next-paper-id 3, got "
                      (:wat::core::i64::to-string next-id))
                    ""))))
            (:None (:wat::test::assert-eq "no snap" "")))))
        ()))

     ((_join :exp::State) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))
