;; 004-step-B-cache-alone.wat — stepping stone toward proof_004.
;;
;; HologramCacheService alone, no rundb at all. Null reporter +
;; null cadence (no fires). Drive a few Puts and Gets, exit.
;;
;; What it proves: the cache service alone shuts down cleanly when
;; senders drop. Rules out cache-internal lifecycle bugs.

(:wat::test::make-deftest :deftest ())

(:deftest :trading::test::proofs::004::step-B-cache-alone
  (:wat::core::let*
    (((cache-spawn :wat::holon::lru::HologramCacheService::Spawn)
      (:wat::holon::lru::HologramCacheService/spawn 1 64
        :wat::holon::lru::HologramCacheService/null-reporter
        (:wat::holon::lru::HologramCacheService/null-metrics-cadence)))
     ((cache-pool :wat::holon::lru::HologramCacheService::ReqTxPool)
      (:wat::core::first cache-spawn))
     ((cache-driver :wat::kernel::ProgramHandle<()>)
      (:wat::core::second cache-spawn))

     ((_inner :())
      (:wat::core::let*
        (((cache-req-tx :wat::holon::lru::HologramCacheService::ReqTx)
          (:wat::kernel::HandlePool::pop cache-pool))
         ((_finish-cache :()) (:wat::kernel::HandlePool::finish cache-pool))
         ((reply-pair :wat::holon::lru::HologramCacheService::GetReplyPair)
          (:wat::kernel::make-bounded-queue :Option<wat::holon::HolonAST> 1))
         ((reply-tx :wat::holon::lru::HologramCacheService::GetReplyTx)
          (:wat::core::first reply-pair))
         ((reply-rx :wat::holon::lru::HologramCacheService::GetReplyRx)
          (:wat::core::second reply-pair))

         ;; Two Puts then one Get.
         ((k0 :wat::holon::HolonAST) (:wat::holon::leaf "k0"))
         ((v0 :wat::holon::HolonAST) (:wat::holon::leaf "v0"))
         ((_p0 :())
          (:wat::core::result::expect -> :()
            (:wat::kernel::send cache-req-tx
              (:wat::holon::lru::HologramCacheService::Request::Put k0 v0))
            "step-B: send Put k0: driver died?"))

         ((k1 :wat::holon::HolonAST) (:wat::holon::leaf "k1"))
         ((v1 :wat::holon::HolonAST) (:wat::holon::leaf "v1"))
         ((_p1 :())
          (:wat::core::result::expect -> :()
            (:wat::kernel::send cache-req-tx
              (:wat::holon::lru::HologramCacheService::Request::Put k1 v1))
            "step-B: send Put k1: driver died?"))

         ((_g0 :())
          (:wat::core::result::expect -> :()
            (:wat::kernel::send cache-req-tx
              (:wat::holon::lru::HologramCacheService::Request::Get k0 reply-tx))
            "step-B: send Get k0: driver died?"))
         ((_reply :Result<Option<Option<wat::holon::HolonAST>>,wat::kernel::ThreadDiedError>)
          (:wat::kernel::recv reply-rx)))
        ()))

     ((_cache-join :()) (:wat::kernel::join cache-driver)))
    (:wat::test::assert-eq true true)))
