;; wat-tests/cache/L2-spawn.wat — :trading::cache::L2/spawn tests.
;;
;; Verifies the paired L2 cache spawner: cache-next + cache-terminal
;; come up, accept Put + Get round-trips on each, and shut down
;; cleanly when the client scope drops the popped handles.
;;
;; Same nested-let* shape as substrate HologramCacheService's
;; step5 multi-client test — outer holds the two drivers; inner owns
;; the popped per-cache handles + reply channels.

(:wat::test::make-deftest :deftest-hermetic
  ((:wat::load-file! "wat/cache/L2-spawn.wat")))

;; ─── L2 spawn + put/get round-trip on each cache ────────────────

(:deftest-hermetic :trading::test::cache::L2-spawn::test-paired-spawn-roundtrip
  (:wat::core::let*
    (((drivers :(wat::kernel::ProgramHandle<()>,wat::kernel::ProgramHandle<()>))
      (:wat::core::let*
        (((l2 :trading::cache::L2)
          (:trading::cache::L2/spawn 1 16 :wat::holon::lru::HologramCacheService/null-reporter (:wat::holon::lru::HologramCacheService/null-metrics-cadence)))
         ((next-pool :wat::holon::lru::HologramCacheService::ReqTxPool)
          (:trading::cache::L2/next-pool l2))
         ((next-driver :wat::kernel::ProgramHandle<()>)
          (:trading::cache::L2/next-driver l2))
         ((terminal-pool :wat::holon::lru::HologramCacheService::ReqTxPool)
          (:trading::cache::L2/terminal-pool l2))
         ((terminal-driver :wat::kernel::ProgramHandle<()>)
          (:trading::cache::L2/terminal-driver l2))

         ;; Pop one client handle from each pool; finish to assert
         ;; no orphans (count=1 means exactly one handle each).
         ((next-tx :wat::holon::lru::HologramCacheService::ReqTx)
          (:wat::kernel::HandlePool::pop next-pool))
         ((_finish-next :()) (:wat::kernel::HandlePool::finish next-pool))
         ((terminal-tx :wat::holon::lru::HologramCacheService::ReqTx)
          (:wat::kernel::HandlePool::pop terminal-pool))
         ((_finish-terminal :()) (:wat::kernel::HandlePool::finish terminal-pool))

         ;; Reply channels — one per cache, single-shot for the test.
         ((reply-pair-n :wat::kernel::QueuePair<Option<wat::holon::HolonAST>>)
          (:wat::kernel::make-bounded-queue :Option<wat::holon::HolonAST> 1))
         ((reply-tx-n :wat::holon::lru::HologramCacheService::GetReplyTx)
          (:wat::core::first reply-pair-n))
         ((reply-rx-n :wat::holon::lru::HologramCacheService::GetReplyRx)
          (:wat::core::second reply-pair-n))

         ((reply-pair-t :wat::kernel::QueuePair<Option<wat::holon::HolonAST>>)
          (:wat::kernel::make-bounded-queue :Option<wat::holon::HolonAST> 1))
         ((reply-tx-t :wat::holon::lru::HologramCacheService::GetReplyTx)
          (:wat::core::first reply-pair-t))
         ((reply-rx-t :wat::holon::lru::HologramCacheService::GetReplyRx)
          (:wat::core::second reply-pair-t))

         ((kn :wat::holon::HolonAST) (:wat::holon::leaf :next-key))
         ((vn :wat::holon::HolonAST) (:wat::holon::leaf :next-val))
         ((kt :wat::holon::HolonAST) (:wat::holon::leaf :term-key))
         ((vt :wat::holon::HolonAST) (:wat::holon::leaf :term-val))

         ;; cache-next: Put + Get
         ((_pn :())
          (:wat::core::result::expect -> :() (:wat::kernel::send next-tx
            (:wat::holon::lru::HologramCacheService::Request::Put kn vn)) "test send _pn: peer disconnected"))
         ((_gn :())
          (:wat::core::result::expect -> :() (:wat::kernel::send next-tx
            (:wat::holon::lru::HologramCacheService::Request::Get kn reply-tx-n)) "test send _gn: peer disconnected"))
         ((_check-n :())
          (:wat::core::match (:wat::kernel::recv reply-rx-n) -> :()
            ((Ok (Some inner))
              (:wat::core::match inner -> :()
                ((Some _val) ())
                (:None (:wat::test::assert-eq "next-cache-miss" ""))))
            ((Ok :None) (:wat::test::assert-eq "next-no-reply" ""))
            ((Err _died) (:wat::test::assert-eq "next-no-reply" ""))))

         ;; cache-terminal: Put + Get
         ((_pt :())
          (:wat::core::result::expect -> :() (:wat::kernel::send terminal-tx
            (:wat::holon::lru::HologramCacheService::Request::Put kt vt)) "test send _pt: peer disconnected"))
         ((_gt :())
          (:wat::core::result::expect -> :() (:wat::kernel::send terminal-tx
            (:wat::holon::lru::HologramCacheService::Request::Get kt reply-tx-t)) "test send _gt: peer disconnected"))
         ((_check-t :())
          (:wat::core::match (:wat::kernel::recv reply-rx-t) -> :()
            ((Ok (Some inner))
              (:wat::core::match inner -> :()
                ((Some _val) ())
                (:None (:wat::test::assert-eq "terminal-cache-miss" ""))))
            ((Ok :None) (:wat::test::assert-eq "terminal-no-reply" ""))
            ((Err _died) (:wat::test::assert-eq "terminal-no-reply" "")))))
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
;; The two L2 services own separate HologramCaches; a key Put on
;; cache-next must not appear when Get from cache-terminal.

(:deftest-hermetic :trading::test::cache::L2-spawn::test-caches-isolated
  (:wat::core::let*
    (((drivers :(wat::kernel::ProgramHandle<()>,wat::kernel::ProgramHandle<()>))
      (:wat::core::let*
        (((l2 :trading::cache::L2)
          (:trading::cache::L2/spawn 1 16 :wat::holon::lru::HologramCacheService/null-reporter (:wat::holon::lru::HologramCacheService/null-metrics-cadence)))
         ((next-pool :wat::holon::lru::HologramCacheService::ReqTxPool)
          (:trading::cache::L2/next-pool l2))
         ((next-driver :wat::kernel::ProgramHandle<()>)
          (:trading::cache::L2/next-driver l2))
         ((terminal-pool :wat::holon::lru::HologramCacheService::ReqTxPool)
          (:trading::cache::L2/terminal-pool l2))
         ((terminal-driver :wat::kernel::ProgramHandle<()>)
          (:trading::cache::L2/terminal-driver l2))

         ((next-tx :wat::holon::lru::HologramCacheService::ReqTx)
          (:wat::kernel::HandlePool::pop next-pool))
         ((_finish-next :()) (:wat::kernel::HandlePool::finish next-pool))
         ((terminal-tx :wat::holon::lru::HologramCacheService::ReqTx)
          (:wat::kernel::HandlePool::pop terminal-pool))
         ((_finish-terminal :()) (:wat::kernel::HandlePool::finish terminal-pool))

         ((reply-pair :wat::kernel::QueuePair<Option<wat::holon::HolonAST>>)
          (:wat::kernel::make-bounded-queue :Option<wat::holon::HolonAST> 1))
         ((reply-tx :wat::holon::lru::HologramCacheService::GetReplyTx)
          (:wat::core::first reply-pair))
         ((reply-rx :wat::holon::lru::HologramCacheService::GetReplyRx)
          (:wat::core::second reply-pair))

         ((k :wat::holon::HolonAST) (:wat::holon::leaf :only-in-next))
         ((v :wat::holon::HolonAST) (:wat::holon::leaf :next-payload))

         ;; Put k → v ONLY on cache-next.
         ((_p :())
          (:wat::core::result::expect -> :() (:wat::kernel::send next-tx
            (:wat::holon::lru::HologramCacheService::Request::Put k v)) "test send _p: peer disconnected"))
         ;; Get k from cache-TERMINAL — should miss; key was never
         ;; put on this cache.
         ((_g :())
          (:wat::core::result::expect -> :() (:wat::kernel::send terminal-tx
            (:wat::holon::lru::HologramCacheService::Request::Get k reply-tx)) "test send _g: peer disconnected"))
         ((_check :())
          (:wat::core::match (:wat::kernel::recv reply-rx) -> :()
            ((Ok (Some inner))
              (:wat::core::match inner -> :()
                ((Some _val)
                  (:wat::test::assert-eq "terminal-saw-next-key" ""))
                (:None ())))
            ((Ok :None) (:wat::test::assert-eq "terminal-no-reply" ""))
            ((Err _died) (:wat::test::assert-eq "terminal-no-reply" "")))))
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
