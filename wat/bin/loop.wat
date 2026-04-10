;; The loop expression.
;; The entire enterprise as a let* that binds pipes and invokes a fold.
;; See it. Then make it.

(define (run-enterprise [ent : Enterprise] [ctx : Ctx] [stream : Stream<RawCandle>])
  : (Vec<LogEntry>)

  (let* (;; ── Channels — bounded(1). Lock step. Lazy enumerators. ────
         (n (length market-lenses))
         (m (length exit-lenses))

         ;; Main → observers: enriched candle (product fan-out — each gets a clone)
         (obs-in-chs    (map (lambda (_) (make-channel 1)) (range n)))

         ;; Observers → main: encoded thoughts
         (obs-out-chs   (map (lambda (_) (make-channel 1)) (range n)))

         ;; Main → observers: learning signals (propagation back)
         (obs-learn-chs (map (lambda (_) (make-channel 1)) (range n)))

         ;; ── Observer pipes — each is a thread, each is a fold ──────
         (obs-threads
           (map (lambda (i)
                  (let ((in-ch   (nth obs-in-chs i))
                        (out-ch  (nth obs-out-chs i))
                        (learn-ch (nth obs-learn-chs i))
                        (obs     (nth (:market-observers (:posts ent) 0) i)))
                    (spawn (lambda ()
                      ;; The pipe: receive, encode, send. Forever.
                      (loop
                        ;; Block on input
                        (let (((candle window encode-count) (recv in-ch)))

                          ;; Encode via lens
                          (let* ((facts  (encode-market-facts (:lens obs) candle window))
                                 (bundle (Bundle facts))
                                 ((thought misses) (encode (:thought-encoder ctx) bundle))
                                 (result (observe-candle obs thought)))

                            ;; Send downstream — block until consumer takes
                            (send out-ch (list (:thought result)
                                               (:prediction result)
                                               (:edge result)
                                               misses))

                            ;; Drain learning signals (non-blocking — apply all pending)
                            (while-let (((thought direction weight) (try-recv learn-ch)))
                              (resolve obs thought direction weight)))))))))
                (range n)))

         ;; ── The fold — main thread drives everything ───────────────
         (all-logs
           (fold
             (lambda (logs raw-candle)

               ;; 1. Tick indicators — sequential, streaming state
               (let* ((candle (tick (:indicator-bank post) raw-candle))
                      (_     (push! (:candle-window post) candle))
                      (_     (inc! (:encode-count post)))
                      (window (to-vec (:candle-window post)))
                      (price  (:close candle)))

                 ;; 2. Fan-out — send to all observers (product: each gets a clone)
                 (for-each (lambda (ch)
                   (send ch (list candle window (:encode-count post))))
                   obs-in-chs)

                 ;; 3. Collect thoughts — block on each observer
                 (let* ((results (map (lambda (ch) (recv ch)) obs-out-chs))
                        (thoughts    (map first results))
                        (predictions (map second results))
                        (edges       (map third results))
                        (misses      (apply append (map fourth results))))

                   ;; 4. N×M grid — compose + propose + paper (parallel)
                   (let* ((grid
                            (pmap (lambda (slot)
                              (let* ((mi (/ slot m))
                                     (ei (mod slot m))
                                     (market-thought (nth thoughts mi))
                                     (exit-facts (encode-exit-facts
                                                   (:lens (nth (:exit-observers post) ei))
                                                   candle))
                                     ((exit-vec exit-misses) (encode (:thought-encoder ctx)
                                                                     (Bundle exit-facts)))
                                     (composed (bundle market-thought exit-vec))
                                     ((dists _) (recommended-distances
                                                  (nth (:exit-observers post) ei)
                                                  composed
                                                  (:scalar-accums (nth (:registry post) slot)))))
                                (list slot composed dists mi ei exit-misses)))
                              (range (* n m))))

                          ;; 5. Apply mutations — per broker, parallel
                          (_ (pmap (lambda ((slot composed dists mi ei _))
                               (let ((broker (nth (:registry post) slot)))
                                 (propose broker composed)
                                 (register-paper broker composed price dists)))
                               grid))

                          ;; 6. Tick papers — per broker, parallel
                          (all-resolutions
                            (apply append
                              (pmap (lambda (broker) (tick-papers broker price))
                                    (:registry post))))

                          ;; 7. Propagate — send learning signals back to observer pipes
                          (_ (for-each (lambda (res)
                               (let ((mi (/ (:broker-slot-idx res) m)))
                                 (send (nth obs-learn-chs mi)
                                       (list (:composed-thought res)
                                             (:direction res)
                                             (:amount res)))))
                               all-resolutions))

                          ;; 8. Fund proposals
                          (fund-logs (fund-proposals (:treasury ent))))

                     ;; Accumulate logs
                     (append logs fund-logs)))))

             ;; Initial accumulator, the stream
             (list)
             stream)))

    ;; ── Shutdown — close channels, join threads ─────────────────
    (for-each close! obs-in-chs)
    (for-each close! obs-learn-chs)
    (for-each join obs-threads)

    all-logs))
