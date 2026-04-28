;; wat-tests/cache/L2-spawn.wat — :trading::cache::L2/spawn tests.
;;
;; Verifies the paired L2 cache spawner: cache-next + cache-terminal
;; come up, accept Put + Get round-trips on each, and shut down
;; cleanly when the client scope drops the popped handles.
;;
;; Same nested-let* shape as Service.wat's step5 multi-client test —
;; outer holds the two drivers; inner owns the popped per-cache
;; handles + reply channels.

(:wat::test::make-deftest :deftest-hermetic
  ((:wat::load-file! "wat/cache/Service.wat")
   (:wat::load-file! "wat/cache/L2-spawn.wat")))

;; ─── L2 spawn + put/get round-trip on each cache ────────────────

(:deftest-hermetic :trading::test::cache::L2-spawn::test-paired-spawn-roundtrip
  (:wat::core::let*
    (((drivers :(wat::kernel::ProgramHandle<()>,wat::kernel::ProgramHandle<()>))
      (:wat::core::let*
        (((l2 :trading::cache::L2)
          (:trading::cache::L2/spawn 1 16))
         ((next-pool :trading::cache::ReqTxPool)
          (:trading::cache::L2/next-pool l2))
         ((next-driver :wat::kernel::ProgramHandle<()>)
          (:trading::cache::L2/next-driver l2))
         ((terminal-pool :trading::cache::ReqTxPool)
          (:trading::cache::L2/terminal-pool l2))
         ((terminal-driver :wat::kernel::ProgramHandle<()>)
          (:trading::cache::L2/terminal-driver l2))

         ;; Pop one client handle from each pool; finish to assert
         ;; no orphans (count=1 means exactly one handle each).
         ((next-tx :trading::cache::ReqTx)
          (:wat::kernel::HandlePool::pop next-pool))
         ((_finish-next :()) (:wat::kernel::HandlePool::finish next-pool))
         ((terminal-tx :trading::cache::ReqTx)
          (:wat::kernel::HandlePool::pop terminal-pool))
         ((_finish-terminal :()) (:wat::kernel::HandlePool::finish terminal-pool))

         ;; Reply channels — one per cache, single-shot for the test.
         ((reply-pair-n :wat::kernel::QueuePair<Option<wat::holon::HolonAST>>)
          (:wat::kernel::make-bounded-queue :Option<wat::holon::HolonAST> 1))
         ((reply-tx-n :trading::cache::GetReplyTx)
          (:wat::core::first reply-pair-n))
         ((reply-rx-n :trading::cache::GetReplyRx)
          (:wat::core::second reply-pair-n))

         ((reply-pair-t :wat::kernel::QueuePair<Option<wat::holon::HolonAST>>)
          (:wat::kernel::make-bounded-queue :Option<wat::holon::HolonAST> 1))
         ((reply-tx-t :trading::cache::GetReplyTx)
          (:wat::core::first reply-pair-t))
         ((reply-rx-t :trading::cache::GetReplyRx)
          (:wat::core::second reply-pair-t))

         ((kn :wat::holon::HolonAST) (:wat::holon::leaf :next-key))
         ((vn :wat::holon::HolonAST) (:wat::holon::leaf :next-val))
         ((kt :wat::holon::HolonAST) (:wat::holon::leaf :term-key))
         ((vt :wat::holon::HolonAST) (:wat::holon::leaf :term-val))

         ;; cache-next: Put + Get
         ((_pn :wat::kernel::Sent)
          (:wat::kernel::send next-tx
            (:trading::cache::Request::Put kn vn)))
         ((_gn :wat::kernel::Sent)
          (:wat::kernel::send next-tx
            (:trading::cache::Request::Get kn reply-tx-n)))
         ((reply-n :Option<Option<wat::holon::HolonAST>>)
          (:wat::kernel::recv reply-rx-n))
         ((_check-n :())
          (:wat::core::match reply-n -> :()
            ((Some inner)
              (:wat::core::match inner -> :()
                ((Some _val) ())
                (:None (:wat::test::assert-eq "next-cache-miss" ""))))
            (:None (:wat::test::assert-eq "next-no-reply" ""))))

         ;; cache-terminal: Put + Get
         ((_pt :wat::kernel::Sent)
          (:wat::kernel::send terminal-tx
            (:trading::cache::Request::Put kt vt)))
         ((_gt :wat::kernel::Sent)
          (:wat::kernel::send terminal-tx
            (:trading::cache::Request::Get kt reply-tx-t)))
         ((reply-t :Option<Option<wat::holon::HolonAST>>)
          (:wat::kernel::recv reply-rx-t))
         ((_check-t :())
          (:wat::core::match reply-t -> :()
            ((Some inner)
              (:wat::core::match inner -> :()
                ((Some _val) ())
                (:None (:wat::test::assert-eq "terminal-cache-miss" ""))))
            (:None (:wat::test::assert-eq "terminal-no-reply" "")))))
        (:wat::core::tuple next-driver terminal-driver))))
    (:wat::core::let*
      (((next-d :wat::kernel::ProgramHandle<()>)
        (:wat::core::first drivers))
       ((term-d :wat::kernel::ProgramHandle<()>)
        (:wat::core::second drivers))
       ((_check-next :())
        (:wat::core::match (:wat::kernel::join-result next-d) -> :()
          ((Ok _) ())
          ((Err _) (:wat::test::assert-eq "next-died" "")))))
      (:wat::core::match (:wat::kernel::join-result term-d) -> :()
        ((Ok _) ())
        ((Err _) (:wat::test::assert-eq "terminal-died" ""))))))

;; ─── Caches are isolated: a Put on next is invisible from terminal ──
;;
;; The two L2 services own separate HologramLRUs; a key Put on
;; cache-next must not appear when Get from cache-terminal.

(:deftest-hermetic :trading::test::cache::L2-spawn::test-caches-isolated
  (:wat::core::let*
    (((drivers :(wat::kernel::ProgramHandle<()>,wat::kernel::ProgramHandle<()>))
      (:wat::core::let*
        (((l2 :trading::cache::L2)
          (:trading::cache::L2/spawn 1 16))
         ((next-pool :trading::cache::ReqTxPool)
          (:trading::cache::L2/next-pool l2))
         ((next-driver :wat::kernel::ProgramHandle<()>)
          (:trading::cache::L2/next-driver l2))
         ((terminal-pool :trading::cache::ReqTxPool)
          (:trading::cache::L2/terminal-pool l2))
         ((terminal-driver :wat::kernel::ProgramHandle<()>)
          (:trading::cache::L2/terminal-driver l2))

         ((next-tx :trading::cache::ReqTx)
          (:wat::kernel::HandlePool::pop next-pool))
         ((_finish-next :()) (:wat::kernel::HandlePool::finish next-pool))
         ((terminal-tx :trading::cache::ReqTx)
          (:wat::kernel::HandlePool::pop terminal-pool))
         ((_finish-terminal :()) (:wat::kernel::HandlePool::finish terminal-pool))

         ((reply-pair :wat::kernel::QueuePair<Option<wat::holon::HolonAST>>)
          (:wat::kernel::make-bounded-queue :Option<wat::holon::HolonAST> 1))
         ((reply-tx :trading::cache::GetReplyTx)
          (:wat::core::first reply-pair))
         ((reply-rx :trading::cache::GetReplyRx)
          (:wat::core::second reply-pair))

         ((k :wat::holon::HolonAST) (:wat::holon::leaf :only-in-next))
         ((v :wat::holon::HolonAST) (:wat::holon::leaf :next-payload))

         ;; Put k → v ONLY on cache-next.
         ((_p :wat::kernel::Sent)
          (:wat::kernel::send next-tx
            (:trading::cache::Request::Put k v)))
         ;; Get k from cache-TERMINAL — should miss; key was never
         ;; put on this cache.
         ((_g :wat::kernel::Sent)
          (:wat::kernel::send terminal-tx
            (:trading::cache::Request::Get k reply-tx)))
         ((reply :Option<Option<wat::holon::HolonAST>>)
          (:wat::kernel::recv reply-rx))
         ((_check :())
          (:wat::core::match reply -> :()
            ((Some inner)
              (:wat::core::match inner -> :()
                ((Some _val)
                  (:wat::test::assert-eq "terminal-saw-next-key" ""))
                (:None ())))
            (:None (:wat::test::assert-eq "terminal-no-reply" "")))))
        (:wat::core::tuple next-driver terminal-driver))))
    (:wat::core::let*
      (((next-d :wat::kernel::ProgramHandle<()>)
        (:wat::core::first drivers))
       ((term-d :wat::kernel::ProgramHandle<()>)
        (:wat::core::second drivers))
       ((_check-next :())
        (:wat::core::match (:wat::kernel::join-result next-d) -> :()
          ((Ok _) ())
          ((Err _) (:wat::test::assert-eq "next-died" "")))))
      (:wat::core::match (:wat::kernel::join-result term-d) -> :()
        ((Ok _) ())
        ((Err _) (:wat::test::assert-eq "terminal-died" ""))))))
