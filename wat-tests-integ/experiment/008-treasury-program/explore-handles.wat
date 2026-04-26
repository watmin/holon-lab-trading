;; wat-tests-integ/experiment/008-treasury-program/explore-handles.wat
;;
;; Build the Treasury experiment up from the smallest pieces. Each
;; step adds ONE new concept; check-pointed by running before adding
;; the next. The path is the architecture; the coordinates reveal
;; themselves as we walk it.
;;
;; Step 1 — spawn + join-result (Ok happy path)
;; Step 2 — spawn + join-result (Err Panic round-trip)
;; Step 3 — channel: send N msgs, drop tx, worker reads-loop returns count
;; Step 4 — round-trip: req on one channel, resp on another
;; Step 5 — multi-channel select; explicit drop closes each in sequence
;; Step 6 — secondary write surface (telemetry-shape)
;; Step 7 — full Treasury skeleton with placeholder bodies
;; Step 8+ — replace placeholders one at a time
;;
;; Steps 1-2 don't need types.wat / treasury.wat / services/treasury.wat
;; — they exercise pure substrate. Loads start at step 7.

(:wat::test::make-deftest :deftest
  (;; Channel-pair shape lands as `:wat::kernel::QueuePair<T>` —
   ;; substrate alias from wat/kernel/queue.wat (registered at startup
   ;; with the rest of the stdlib). Used everywhere make-bounded-queue
   ;; appears below.

   ;; Step 8 type — Tally is a two-field struct the recv-loop carries
   ;; as accumulator. Each iteration constructs a NEW Tally (values
   ;; discipline — no in-place mutation); the worker returns the final
   ;; Tally on disconnect, and the test asserts on its fields. Mirrors
   ;; the AtrWindow/push shape (read accessors, build new via /new).
   (:wat::core::struct :trading::test::experiment::008::handles::Tally
     (count :i64)
     (sum   :i64))

   ;; Step 1 helper — trivial fn that returns a known constant.
   (:wat::core::define
     (:trading::test::experiment::008::handles::return-42 -> :i64) 42)

   ;; Step 2 helper — fn that panics with a known message.
   (:wat::core::define
     (:trading::test::experiment::008::handles::boom -> :())
     (:wat::kernel::assertion-failed! "intentional panic" :None :None))

   ;; Step 3 helpers — counted-recv loop.
   ;;
   ;; count-recv: tail-recursive read loop. recv → Some → recurse + 1;
   ;; recv → None → return acc. The :None arm fires when ALL senders
   ;; have dropped (the channel is fully closed). This is the lockstep:
   ;; we own the tx side; explicit drop of tx is the close signal.
   (:wat::core::define
     (:trading::test::experiment::008::handles::count-recv
       (rx :wat::kernel::QueueReceiver<i64>)
       (acc :i64)
       -> :i64)
     (:wat::core::match (:wat::kernel::recv rx) -> :i64
       ((Some _v)
         (:trading::test::experiment::008::handles::count-recv rx (:wat::core::+ acc 1)))
       (:None acc)))

   ;; Spawn entry — start the count at 0.
   (:wat::core::define
     (:trading::test::experiment::008::handles::run-counter
       (rx :wat::kernel::QueueReceiver<i64>)
       -> :i64)
     (:trading::test::experiment::008::handles::count-recv rx 0))

   ;; Step 4 helper — req/resp round-trip worker.
   ;;
   ;; Recv-loop on req-rx; for each Some(n), send (n*2) on resp-tx;
   ;; on :None (req-tx dropped by client) return (). The send returns
   ;; :Option<()>; we ignore the variant — if the client dropped resp-rx
   ;; before we could ack, that's its problem (fire-and-forget arm).
   (:wat::core::define
     (:trading::test::experiment::008::handles::doubler-loop
       (req-rx :wat::kernel::QueueReceiver<i64>)
       (resp-tx :wat::kernel::QueueSender<i64>)
       -> :())
     (:wat::core::match (:wat::kernel::recv req-rx) -> :()
       ((Some n)
         (:wat::core::let*
           (((_ack :Option<()>) (:wat::kernel::send resp-tx (:wat::core::* n 2))))
           (:trading::test::experiment::008::handles::doubler-loop req-rx resp-tx)))
       (:None ())))

   ;; Step 5 helpers — multi-channel select, count-and-prune.
   ;;
   ;; select returns (idx, Option<msg>). On Some, increment acc and
   ;; recurse over the same Vec. On :None, that one rx has all senders
   ;; dropped — remove it from the Vec and recurse. Exit when Vec is
   ;; empty (all upstream channels closed). This is the Console pattern
   ;; lifted into a counter — proves we can drive N receivers from one
   ;; loop and shut down cleanly under scope-based close.
   (:wat::core::define
     (:trading::test::experiment::008::handles::select-loop-step
       (rxs :Vec<wat::kernel::QueueReceiver<i64>>)
       (acc :i64)
       -> :i64)
     (:wat::core::if (:wat::core::empty? rxs) -> :i64
       acc
       (:wat::core::let*
         (((chosen :wat::kernel::Chosen<i64>) (:wat::kernel::select rxs))
          ((idx :i64) (:wat::core::first chosen))
          ((maybe :Option<i64>) (:wat::core::second chosen)))
         (:wat::core::match maybe -> :i64
           ((Some _v)
             (:trading::test::experiment::008::handles::select-loop-step
               rxs (:wat::core::+ acc 1)))
           (:None
             (:trading::test::experiment::008::handles::select-loop-step
               (:wat::std::list::remove-at rxs idx) acc))))))

   (:wat::core::define
     (:trading::test::experiment::008::handles::run-selector
       (rxs :Vec<wat::kernel::QueueReceiver<i64>>)
       -> :i64)
     (:trading::test::experiment::008::handles::select-loop-step rxs 0))

   ;; Step 6 helper — req/resp PLUS telemetry shadow.
   ;;
   ;; Each request: emit to resp-tx (caller's reply) AND telem-tx
   ;; (side surface, RunDb-shaped). Mirrors the Treasury pattern where
   ;; the program owes its caller a response AND owes the run ledger a
   ;; telemetry event. Both happen inside the same recv handler so the
   ;; client sees a single coherent step.
   (:wat::core::define
     (:trading::test::experiment::008::handles::telemetry-loop
       (req-rx :wat::kernel::QueueReceiver<i64>)
       (resp-tx :wat::kernel::QueueSender<i64>)
       (telem-tx :wat::kernel::QueueSender<i64>)
       -> :())
     (:wat::core::match (:wat::kernel::recv req-rx) -> :()
       ((Some n)
         (:wat::core::let*
           (((_r :Option<()>) (:wat::kernel::send resp-tx (:wat::core::* n 2)))
            ((_t :Option<()>) (:wat::kernel::send telem-tx n)))
           (:trading::test::experiment::008::handles::telemetry-loop
             req-rx resp-tx telem-tx)))
       (:None ())))

   ;; Step 7 helpers — fan-in summer over Vec<Receiver>.
   ;;
   ;; Cousin of select-loop-step (step 5), but accumulates the running
   ;; sum instead of a count — proves the same prune-on-disconnect
   ;; pattern carries domain data. Treasury's tick + per-broker request
   ;; shape will reuse this exact loop with a richer payload type.
   (:wat::core::define
     (:trading::test::experiment::008::handles::sum-loop-step
       (rxs :Vec<wat::kernel::QueueReceiver<i64>>)
       (acc :i64)
       -> :i64)
     (:wat::core::if (:wat::core::empty? rxs) -> :i64
       acc
       (:wat::core::let*
         (((chosen :wat::kernel::Chosen<i64>) (:wat::kernel::select rxs))
          ((idx :i64) (:wat::core::first chosen))
          ((maybe :Option<i64>) (:wat::core::second chosen)))
         (:wat::core::match maybe -> :i64
           ((Some v)
             (:trading::test::experiment::008::handles::sum-loop-step
               rxs (:wat::core::+ acc v)))
           (:None
             (:trading::test::experiment::008::handles::sum-loop-step
               (:wat::std::list::remove-at rxs idx) acc))))))

   (:wat::core::define
     (:trading::test::experiment::008::handles::run-summer
       (rxs :Vec<wat::kernel::QueueReceiver<i64>>)
       -> :i64)
     (:trading::test::experiment::008::handles::sum-loop-step rxs 0))

   ;; Step 8 helpers — stateful recv-loop, struct accumulator.
   ;;
   ;; Each Some(v): construct a NEW Tally with count+1 and sum+v
   ;; (read old via /count + /sum accessors, build via /new — the
   ;; AtrWindow::push idiom). On :None: return the final Tally.
   ;; The whole struct rides through join-result; caller reads its
   ;; fields to verify both the count of messages AND the running sum.
   (:wat::core::define
     (:trading::test::experiment::008::handles::tally-loop
       (rx :wat::kernel::QueueReceiver<i64>)
       (tally :trading::test::experiment::008::handles::Tally)
       -> :trading::test::experiment::008::handles::Tally)
     (:wat::core::match (:wat::kernel::recv rx)
       -> :trading::test::experiment::008::handles::Tally
       ((Some v)
         (:wat::core::let*
           (((next :trading::test::experiment::008::handles::Tally)
             (:trading::test::experiment::008::handles::Tally/new
               (:wat::core::+ (:trading::test::experiment::008::handles::Tally/count tally) 1)
               (:wat::core::+ (:trading::test::experiment::008::handles::Tally/sum tally) v))))
           (:trading::test::experiment::008::handles::tally-loop rx next)))
       (:None tally)))

   ;; Spawn entry — start with a fresh-zero Tally.
   (:wat::core::define
     (:trading::test::experiment::008::handles::run-tally
       (rx :wat::kernel::QueueReceiver<i64>)
       -> :trading::test::experiment::008::handles::Tally)
     (:trading::test::experiment::008::handles::tally-loop
       rx
       (:trading::test::experiment::008::handles::Tally/new 0 0)))))


;; ─── Step 1 — spawn + join-result happy path ───────────────────
;;
;; Spawns a function that returns 42. join-result returns Ok(42).
;; Match Ok specifically; any other arm is a failure with diagnostic.
;; This proves the substrate's spawn machinery + arc-060 join-result
;; round-trip the value end-to-end. Nothing else.

(:deftest :trading::test::experiment::008::handles::step-1-spawn-and-join
  (:wat::core::let*
    (((handle :wat::kernel::ProgramHandle<i64>)
      (:wat::kernel::spawn :trading::test::experiment::008::handles::return-42)))
    (:wat::core::match (:wat::kernel::join-result handle) -> :()
      ((Ok 42) ())
      ((Ok n)
        (:wat::test::assert-eq
          (:wat::core::string::concat
            "expected 42, got "
            (:wat::core::i64::to-string n))
          ""))
      ((Err _) (:wat::test::assert-eq "spawn-died" "")))))


;; ─── Step 2 — death-as-data round-trip ────────────────────────
;;
;; Spawns a function that panics. join-result should return
;; Err(Panic "intentional panic"). Verifies: (a) the substrate
;; captures the panic and routes it through the Result channel
;; rather than unwinding the test thread, (b) the message survives
;; the round-trip, (c) the variant is Panic specifically (not
;; RuntimeError or ChannelDisconnected).

(:deftest :trading::test::experiment::008::handles::step-2-spawn-panic
  (:wat::core::let*
    (((handle :wat::kernel::ProgramHandle<()>)
      (:wat::kernel::spawn :trading::test::experiment::008::handles::boom)))
    (:wat::core::match (:wat::kernel::join-result handle) -> :()
      ((Ok _) (:wat::test::assert-eq "expected-panic-not-ok" ""))
      ((Err (:wat::kernel::ThreadDiedError::Panic msg))
        (:wat::test::assert-eq msg "intentional panic"))
      ((Err _) (:wat::test::assert-eq "wrong-error-variant" "")))))


;; ─── Step 3 — channel: send N, drop tx by scope, worker returns count ──
;;
;; Lockstep we OWN: every send → one recv. The worker exits its read
;; loop only when ALL Sender clones have dropped. `:wat::kernel::drop`
;; is documented as a *no-op readability marker* — close is scope-based
;; (see runtime.rs eval_kernel_drop). The proven pattern (Console,
;; CacheService): nest two let*. The OUTER scope holds only what must
;; survive the channel's life — here, the ProgramHandle. The INNER
;; scope owns pair / tx / rx and does all sends. When inner returns,
;; every Sender Arc in this thread drops; the worker's pending recv
;; returns None; count-recv returns acc=3; run-counter returns 3; the
;; spawn machinery routes Ok(3) to outer join-result.

(:deftest :trading::test::experiment::008::handles::step-3-channel-count
  (:wat::core::let*
    (;; Inner scope: owns the channel for its full life. Returns the
     ;; ProgramHandle so the outer scope can join it AFTER pair/tx/rx
     ;; have dropped here at end-of-let*.
     ((handle :wat::kernel::ProgramHandle<i64>)
      (:wat::core::let*
        (((pair :wat::kernel::QueuePair<i64>)
          (:wat::kernel::make-bounded-queue :i64 1))
         ((tx :wat::kernel::QueueSender<i64>) (:wat::core::first pair))
         ((rx :wat::kernel::QueueReceiver<i64>) (:wat::core::second pair))

         ;; Spawn worker; it gets its own rx clone.
         ((h :wat::kernel::ProgramHandle<i64>)
          (:wat::kernel::spawn
            :trading::test::experiment::008::handles::run-counter rx))

         ;; bounded(1) backpressures — each send blocks until worker recv.
         ((_s1 :Option<()>) (:wat::kernel::send tx 10))
         ((_s2 :Option<()>) (:wat::kernel::send tx 20))
         ((_s3 :Option<()>) (:wat::kernel::send tx 30)))
        ;; let* body: yield the ProgramHandle. pair/tx/rx drop right here.
        h)))
    ;; By this point: zero local Senders. Worker's next recv → None.
    (:wat::core::match (:wat::kernel::join-result handle) -> :()
      ((Ok 3) ())
      ((Ok n)
        (:wat::test::assert-eq
          (:wat::core::string::concat
            "expected 3, got "
            (:wat::core::i64::to-string n))
          ""))
      ((Err _) (:wat::test::assert-eq "worker-died" "")))))


;; ─── Step 4 — request/response round-trip on two channels ─────
;;
;; Two channels: req-tx → worker recv → worker send → resp-rx.
;; Test sends 21 on req, expects 42 back on resp. Then inner scope
;; exits, req-tx drops, worker's recv-loop sees None, worker returns ().
;; Outer join-result returns Ok(()) — proven shutdown without explicit drop.
;;
;; Single round-trip is enough to prove the pattern; counts come later.

(:deftest :trading::test::experiment::008::handles::step-4-roundtrip
  (:wat::core::let*
    (((handle :wat::kernel::ProgramHandle<()>)
      (:wat::core::let*
        (((req-pair :wat::kernel::QueuePair<i64>)
          (:wat::kernel::make-bounded-queue :i64 1))
         ((req-tx :wat::kernel::QueueSender<i64>) (:wat::core::first req-pair))
         ((req-rx :wat::kernel::QueueReceiver<i64>) (:wat::core::second req-pair))

         ((resp-pair :wat::kernel::QueuePair<i64>)
          (:wat::kernel::make-bounded-queue :i64 1))
         ((resp-tx :wat::kernel::QueueSender<i64>) (:wat::core::first resp-pair))
         ((resp-rx :wat::kernel::QueueReceiver<i64>) (:wat::core::second resp-pair))

         ((h :wat::kernel::ProgramHandle<()>)
          (:wat::kernel::spawn
            :trading::test::experiment::008::handles::doubler-loop
            req-rx resp-tx))

         ;; Round-trip: send 21, recv 42.
         ((_s :Option<()>) (:wat::kernel::send req-tx 21))
         ((got :Option<i64>) (:wat::kernel::recv resp-rx))
         ((_check :())
          (:wat::core::match got -> :()
            ((Some 42) ())
            ((Some n)
              (:wat::test::assert-eq
                (:wat::core::string::concat
                  "expected 42, got "
                  (:wat::core::i64::to-string n))
                ""))
            (:None (:wat::test::assert-eq "no-response" "")))))
        h)))
    ;; All Senders/Receivers from inner scope are dropped here.
    ;; Worker's req-rx now disconnected → recv None → returns ().
    (:wat::core::match (:wat::kernel::join-result handle) -> :()
      ((Ok _) ())
      ((Err _) (:wat::test::assert-eq "worker-died" "")))))


;; ─── Step 5 — multi-channel select; per-channel close cascade ─
;;
;; Two channels, one worker. Worker holds Vec<Receiver>; selects;
;; counts Some; on :None for any rx, removes it from the Vec and
;; recurses; exits when Vec empty.
;;
;; Test sends 2 on ch1, 3 on ch2 → expects worker to return 5. Inner
;; scope exits → BOTH txs drop → both rxs disconnect → worker prunes
;; both → loop exits. Proves: select primitive works; remove-at
;; preserves loop liveness as one channel dies before another.

(:deftest :trading::test::experiment::008::handles::step-5-multi-select
  (:wat::core::let*
    (((handle :wat::kernel::ProgramHandle<i64>)
      (:wat::core::let*
        (((p1 :wat::kernel::QueuePair<i64>)
          (:wat::kernel::make-bounded-queue :i64 1))
         ((tx1 :wat::kernel::QueueSender<i64>) (:wat::core::first p1))
         ((rx1 :wat::kernel::QueueReceiver<i64>) (:wat::core::second p1))

         ((p2 :wat::kernel::QueuePair<i64>)
          (:wat::kernel::make-bounded-queue :i64 1))
         ((tx2 :wat::kernel::QueueSender<i64>) (:wat::core::first p2))
         ((rx2 :wat::kernel::QueueReceiver<i64>) (:wat::core::second p2))

         ((rxs :Vec<wat::kernel::QueueReceiver<i64>>)
          (:wat::core::conj
            (:wat::core::conj (:wat::core::vec :wat::kernel::QueueReceiver<i64>) rx1)
            rx2))

         ((h :wat::kernel::ProgramHandle<i64>)
          (:wat::kernel::spawn
            :trading::test::experiment::008::handles::run-selector rxs))

         ;; 2 on tx1, 3 on tx2 — total 5. bounded(1) keeps backpressure
         ;; honest; worker must keep up.
         ((_a1 :Option<()>) (:wat::kernel::send tx1 1))
         ((_a2 :Option<()>) (:wat::kernel::send tx1 2))
         ((_b1 :Option<()>) (:wat::kernel::send tx2 10))
         ((_b2 :Option<()>) (:wat::kernel::send tx2 20))
         ((_b3 :Option<()>) (:wat::kernel::send tx2 30)))
        h)))
    (:wat::core::match (:wat::kernel::join-result handle) -> :()
      ((Ok 5) ())
      ((Ok n)
        (:wat::test::assert-eq
          (:wat::core::string::concat
            "expected 5, got "
            (:wat::core::i64::to-string n))
          ""))
      ((Err _) (:wat::test::assert-eq "selector-died" "")))))


;; ─── Step 6 — secondary write surface (telemetry shape) ───────
;;
;; Worker holds req-rx + resp-tx + telem-tx. For each request: respond
;; on resp-tx, ALSO emit telemetry on telem-tx. Test reads both per
;; iteration (bounded(1) demands it; unread telem would block the
;; worker on its next telem send).
;;
;; Single round-trip is enough — proves three-handle wiring + the
;; shutdown cascade survives an extra Sender. Multi-iteration patterns
;; show up later when Treasury wires real per-Request + per-Tick logs.

(:deftest :trading::test::experiment::008::handles::step-6-telemetry-shape
  (:wat::core::let*
    (((handle :wat::kernel::ProgramHandle<()>)
      (:wat::core::let*
        (((req-pair :wat::kernel::QueuePair<i64>)
          (:wat::kernel::make-bounded-queue :i64 1))
         ((req-tx :wat::kernel::QueueSender<i64>) (:wat::core::first req-pair))
         ((req-rx :wat::kernel::QueueReceiver<i64>) (:wat::core::second req-pair))

         ((resp-pair :wat::kernel::QueuePair<i64>)
          (:wat::kernel::make-bounded-queue :i64 1))
         ((resp-tx :wat::kernel::QueueSender<i64>) (:wat::core::first resp-pair))
         ((resp-rx :wat::kernel::QueueReceiver<i64>) (:wat::core::second resp-pair))

         ((telem-pair :wat::kernel::QueuePair<i64>)
          (:wat::kernel::make-bounded-queue :i64 1))
         ((telem-tx :wat::kernel::QueueSender<i64>) (:wat::core::first telem-pair))
         ((telem-rx :wat::kernel::QueueReceiver<i64>) (:wat::core::second telem-pair))

         ((h :wat::kernel::ProgramHandle<()>)
          (:wat::kernel::spawn
            :trading::test::experiment::008::handles::telemetry-loop
            req-rx resp-tx telem-tx))

         ((_s :Option<()>) (:wat::kernel::send req-tx 21))
         ((got-resp :Option<i64>) (:wat::kernel::recv resp-rx))
         ((got-telem :Option<i64>) (:wat::kernel::recv telem-rx))
         ((_check-resp :())
          (:wat::core::match got-resp -> :()
            ((Some 42) ())
            ((Some n)
              (:wat::test::assert-eq
                (:wat::core::string::concat
                  "expected resp 42, got "
                  (:wat::core::i64::to-string n))
                ""))
            (:None (:wat::test::assert-eq "no-resp" ""))))
         ((_check-telem :())
          (:wat::core::match got-telem -> :()
            ((Some 21) ())
            ((Some n)
              (:wat::test::assert-eq
                (:wat::core::string::concat
                  "expected telem 21, got "
                  (:wat::core::i64::to-string n))
                ""))
            (:None (:wat::test::assert-eq "no-telem" "")))))
        h)))
    (:wat::core::match (:wat::kernel::join-result handle) -> :()
      ((Ok _) ())
      ((Err _) (:wat::test::assert-eq "worker-died" "")))))


;; ─── Step 7 — HandlePool fan-in: N senders, claim-or-panic, one summer ──
;;
;; Treasury shape preview: many clients each hold their OWN sender into
;; one selecting worker. HandlePool is the orphan-detector — pop N
;; handles, finish() to assert pool empty, distribute to N callers.
;; Each caller owns exactly one Sender; when their let* exits, that
;; one Sender Arc drops; worker's select sees that channel disconnect,
;; prunes it, keeps polling the rest. When the last channel disconnects,
;; the loop exits with the running sum.
;;
;; This step uses 3 channels with all sends issued from ONE inner scope
;; (no separate client threads) — same shutdown story, simpler test
;; surface. Multi-thread clients are a later step if needed.

(:deftest :trading::test::experiment::008::handles::step-7-handlepool-fanin
  (:wat::core::let*
    (((handle :wat::kernel::ProgramHandle<i64>)
      (:wat::core::let*
        (;; Build 3 channels. Vec<QueuePair> is the natural carrier;
         ;; map peels senders into one Vec, receivers into another.
         ((pairs :Vec<wat::kernel::QueuePair<i64>>)
          (:wat::core::map
            (:wat::core::range 0 3)
            (:wat::core::lambda ((_i :i64) -> :wat::kernel::QueuePair<i64>)
              (:wat::kernel::make-bounded-queue :i64 1))))

         ((txs :Vec<wat::kernel::QueueSender<i64>>)
          (:wat::core::map pairs
            (:wat::core::lambda ((p :wat::kernel::QueuePair<i64>)
                                 -> :wat::kernel::QueueSender<i64>)
              (:wat::core::first p))))

         ((rxs :Vec<wat::kernel::QueueReceiver<i64>>)
          (:wat::core::map pairs
            (:wat::core::lambda ((p :wat::kernel::QueuePair<i64>)
                                 -> :wat::kernel::QueueReceiver<i64>)
              (:wat::core::second p))))

         ;; Pool the senders. The handle pool is the explicit
         ;; bookkeeping — pop returns one, finish() panics on orphans.
         ((pool :wat::kernel::HandlePool<wat::kernel::QueueSender<i64>>)
          (:wat::kernel::HandlePool::new "step-7-summer" txs))

         ;; Spawn the summer with the receivers Vec.
         ((h :wat::kernel::ProgramHandle<i64>)
          (:wat::kernel::spawn
            :trading::test::experiment::008::handles::run-summer rxs))

         ;; Pop all 3 handles (claim-or-panic) then finish the pool.
         ((tx-a :wat::kernel::QueueSender<i64>) (:wat::kernel::HandlePool::pop pool))
         ((tx-b :wat::kernel::QueueSender<i64>) (:wat::kernel::HandlePool::pop pool))
         ((tx-c :wat::kernel::QueueSender<i64>) (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))

         ;; Each "client" sends one value. Sum should be 100+200+300 = 600.
         ((_a :Option<()>) (:wat::kernel::send tx-a 100))
         ((_b :Option<()>) (:wat::kernel::send tx-b 200))
         ((_c :Option<()>) (:wat::kernel::send tx-c 300)))
        h)))
    ;; Inner scope exit: pairs, txs, rxs (local clones), pool, tx-a/b/c
    ;; all drop. Worker's three rxs all see disconnect → prune all →
    ;; loop exits → returns 600.
    (:wat::core::match (:wat::kernel::join-result handle) -> :()
      ((Ok 600) ())
      ((Ok n)
        (:wat::test::assert-eq
          (:wat::core::string::concat
            "expected 600, got "
            (:wat::core::i64::to-string n))
          ""))
      ((Err _) (:wat::test::assert-eq "summer-died" "")))))


;; ─── Step 8 — stateful recv-loop with struct accumulator ──────
;;
;; Worker holds a Tally — two i64 fields, count and sum. Every recv
;; constructs a NEW Tally (values discipline; no in-place mutation).
;; Send 5+10+15+20 → expect count=4, sum=50. Inner scope exits, tx
;; drops, worker recv returns :None, returns the final Tally; outer
;; join-result yields Ok(tally); test asserts on both fields.
;;
;; Treasury preview: this is the same shape its select-loop will use
;; — the loop's "state" is a struct that accumulates papers, the loop
;; rebuilds it each iteration, the struct flows out at shutdown.

(:deftest :trading::test::experiment::008::handles::step-8-struct-accumulator
  (:wat::core::let*
    (((handle :wat::kernel::ProgramHandle<trading::test::experiment::008::handles::Tally>)
      (:wat::core::let*
        (((pair :wat::kernel::QueuePair<i64>)
          (:wat::kernel::make-bounded-queue :i64 1))
         ((tx :wat::kernel::QueueSender<i64>) (:wat::core::first pair))
         ((rx :wat::kernel::QueueReceiver<i64>) (:wat::core::second pair))

         ((h :wat::kernel::ProgramHandle<trading::test::experiment::008::handles::Tally>)
          (:wat::kernel::spawn
            :trading::test::experiment::008::handles::run-tally rx))

         ((_s1 :Option<()>) (:wat::kernel::send tx 5))
         ((_s2 :Option<()>) (:wat::kernel::send tx 10))
         ((_s3 :Option<()>) (:wat::kernel::send tx 15))
         ((_s4 :Option<()>) (:wat::kernel::send tx 20)))
        h)))
    (:wat::core::match (:wat::kernel::join-result handle) -> :()
      ((Ok tally)
        (:wat::core::let*
          (((count :i64) (:trading::test::experiment::008::handles::Tally/count tally))
           ((sum :i64)   (:trading::test::experiment::008::handles::Tally/sum tally))
           ((_check-count :())
            (:wat::core::if (:wat::core::= count 4) -> :()
              ()
              (:wat::test::assert-eq
                (:wat::core::string::concat
                  "expected count 4, got "
                  (:wat::core::i64::to-string count))
                ""))))
          (:wat::core::if (:wat::core::= sum 50) -> :()
            ()
            (:wat::test::assert-eq
              (:wat::core::string::concat
                "expected sum 50, got "
                (:wat::core::i64::to-string sum))
              ""))))
      ((Err _) (:wat::test::assert-eq "tally-died" "")))))
