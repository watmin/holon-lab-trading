;; 004-step-A-rundb-alone.wat — stepping stone toward proof_004.
;;
;; SMALLEST possible test: spawn the rundb service, pop one client
;; handle, send ONE batch (1 Event::Log), recv the ack, exit. Inner
;; scope drops the client senders; rundb loop sees disconnect; outer
;; join unblocks.
;;
;; What it proves: the rundb service alone shuts down cleanly under
;; the same shape proof_004 uses (Sqlite/auto-spawn → Service<Event,_>
;; → batch-log → join). NO cache, NO reporter, NO closure capture.
;; If THIS hangs, the issue is in rundb itself.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/telemetry/Sqlite.wat")))

(:deftest :trading::test::proofs::004::step-A-rundb-alone
  (:wat::core::let*
    (((now :wat::time::Instant) (:wat::time::now))
     ((epoch-str :wat::core::String)
      (:wat::core::i64::to-string (:wat::time::epoch-seconds now)))
     ((db-path :wat::core::String)
      (:wat::core::string::concat "runs/proof-004-A-" epoch-str ".db"))
     ((rundb-spawn :wat::telemetry::Service::Spawn<wat::telemetry::Event>)
      (:trading::telemetry::Sqlite/spawn db-path 1
        (:wat::telemetry::Service/null-metrics-cadence)))
     ((rundb-pool :wat::telemetry::Service::HandlePool<wat::telemetry::Event>)
      (:wat::core::first rundb-spawn))
     ((rundb-driver :wat::kernel::ProgramHandle<()>)
      (:wat::core::second rundb-spawn))

     ;; Inner — pop one handle, send one batch, recv ack, drop.
     ((_inner :())
      (:wat::core::let*
        (((rundb-handle :wat::telemetry::Service::Handle<wat::telemetry::Event>)
          (:wat::kernel::HandlePool::pop rundb-pool))
         ((_finish-rundb :()) (:wat::kernel::HandlePool::finish rundb-pool))
         ((req-tx :wat::telemetry::Service::ReqTx<wat::telemetry::Event>)
          (:wat::core::first rundb-handle))
         ((ack-rx :wat::telemetry::Service::AckRx)
          (:wat::core::second rundb-handle))

         ;; Build ONE Event::Log row.
         ((time-ns :wat::core::i64) (:wat::time::epoch-nanos (:wat::time::now)))
         ((uuid :wat::core::String) (:wat::telemetry::uuid::v4))
         ((tags :wat::telemetry::Tags)
          (:wat::core::HashMap :wat::telemetry::Tag))
         ((event :wat::telemetry::Event)
          (:wat::telemetry::Event::Log
            time-ns
            (:wat::edn::NoTag/new (:wat::holon::Atom :step-A))
            (:wat::edn::NoTag/new (:wat::holon::Atom :step-A.caller))
            (:wat::edn::NoTag/new (:wat::holon::Atom :info))
            uuid
            tags
            (:wat::edn::Tagged/new (:wat::holon::Atom :hello))))
         ((entries :Vec<wat::telemetry::Event>)
          (:wat::core::vec :wat::telemetry::Event event))

         ;; Lockstep: send + recv.
         ((_send-recv :())
          (:wat::telemetry::Service/batch-log req-tx ack-rx entries)))
        ()))

     ;; Inner exited — req-tx + ack-rx + rundb-handle dropped.
     ;; rundb's loop sees disconnect on its single rx, exits cleanly.
     ((_rundb-join :()) (:wat::kernel::join rundb-driver)))
    (:wat::test::assert-eq true true)))
