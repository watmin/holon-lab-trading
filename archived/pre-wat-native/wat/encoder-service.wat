;; ── encoder-service.wat ──────────────────────────────────────────
;;
;; ThoughtEncoder cache as a single-threaded pipe loop.
;;
;; The encoder holds an LRU cache. Each caller gets its own pipe set
;; (EncoderHandle). The loop iterates all pipes once per iteration.
;; No mutex. One thread. N callers. One cache.
;;
;; Protocol:
;;   Caller: write AST to lookup pipe -> block on answer pipe -> receive Some/None
;;   Caller: if None, compute locally, write (AST, Vector) to install pipe (fire and forget)
;;   Encoder: one pass per iteration — drain installs, service lookups, select, repeat.
;;
;; Depends on: thought-encoder (ThoughtAST), primitives (Vector).

(require thought-encoder)
(require primitives)

;; ── EncoderHandle — a caller's pipe set ─────────────────────────
;; One per thread. Moved into the thread at construction.

(struct encoder-handle
  [lookup  : Sender<ThoughtAST>]          ; bounded 1
  [answer  : Receiver<Option<Vector>>]    ; bounded 1
  [install : Sender<(ThoughtAST, Vector)>]) ; unbounded, fire and forget

;; Blocking lookup. Sends AST, waits for Some(Vector) or None.
(define (encoder-get [h : EncoderHandle] [ast : ThoughtAST])
  : Option<Vector>
  (send (:lookup h) ast)
  (recv (:answer h)))

;; Fire and forget. Cache learns.
(define (encoder-set [h : EncoderHandle] [ast : ThoughtAST] [vec : Vector])
  : ()
  (send (:install h) (list ast vec)))

;; ── EncoderService — owns the thread, reports stats ─────────────
;; Does NOT hold sender copies — the handles ARE the senders.
;; When all handles drop, the channels close, the cascade flows,
;; the encoder thread exits.

(struct encoder-service
  [handle     : JoinHandle<()>]
  [hits       : Arc<AtomicUsize>]         ; cache hit counter
  [misses     : Arc<AtomicUsize>]         ; cache miss counter
  [cache-size : Arc<AtomicUsize>])        ; current cache occupancy

;; ── Spawn — create the service + N handles ──────────────────────

(define (encoder-service-spawn [n-callers : usize] [cache-capacity : usize])
  : (EncoderService, Vec<EncoderHandle>)

  ;; Create N pipe sets. No backup senders. The handles ARE the only senders.
  ;; When handles drop, channels close, cascade flows.
  (let ((handles '())
        (get-rxs '())
        (resp-txs '())
        (set-rxs '()))
    (for-each (range n-callers)
      (lambda (_)
        (let (((lookup-tx lookup-rx)   (make-pipe :capacity 1 :carries ThoughtAST))
              ((answer-tx answer-rx)   (make-pipe :capacity 1 :carries Option<Vector>))
              ((install-tx install-rx) (make-pipe :capacity :unbounded :carries (ThoughtAST, Vector))))
          (push! handles (make-encoder-handle lookup-tx answer-rx install-tx))
          (push! get-rxs lookup-rx)
          (push! resp-txs answer-tx)
          (push! set-rxs install-rx))))

    ;; Shared atomic counters
    (let ((hits (arc (atomic 0)))
          (misses (arc (atomic 0)))
          (cache-size (arc (atomic 0))))

      ;; Spawn the encoder thread
      (let ((handle
              (spawn
                (lambda ()
                  (let ((cache (lru-cache cache-capacity))
                        (n (len get-rxs))
                        (closed (vec-of false n)))

                    (loop
                      ;; Pass 1: drain ALL install pipes. Put into cache.
                      (for-each set-rxs
                        (lambda (rx)
                          (loop
                            (match (try-recv rx)
                              ((Some (ast vec)) (put! cache ast vec))
                              (None (break))))))
                      (store! cache-size (len cache))

                      ;; Pass 2: service ALL pending lookup pipes.
                      (for-each (range n)
                        (lambda (i)
                          (when (not (nth closed i))
                            (match (try-recv (nth get-rxs i))
                              ((Some ast)
                                (let ((result (get cache ast)))
                                  (if (some? result)
                                    (fetch-add! hits 1)
                                    (fetch-add! misses 1))
                                  (send (nth resp-txs i) result)))
                              (None nil)
                              (:disconnected
                                (set! closed i true))))))

                      ;; Shutdown: all get pipes closed
                      (when (all? closed)
                        (break))

                      ;; Block until ANY channel has data. Zero CPU when idle.
                      ;; select over all open get + set pipes.
                      ;; Wakes when any channel has data. The next iteration's
                      ;; try-recv passes pick it up.
                      (let ((pipes (append
                                     (filter-indexed get-rxs (lambda (i) (not (nth closed i))))
                                     set-rxs)))
                        (select pipes))))))))

        (list (make-encoder-service handle hits misses cache-size)
              handles)))))

;; ── Shutdown ────────────────────────────────────────────────────
;; The cascade must have already closed all handles (callers dropped
;; their EncoderHandles). The encoder thread exits when all get
;; pipes are Disconnected.

(define (encoder-service-shutdown [svc : EncoderService])
  : ()
  (join (:handle svc)))

;; ── Accessors ───────────────────────────────────────────────────

(define (hit-count [svc : EncoderService]) : usize
  (load (:hits svc)))

(define (miss-count [svc : EncoderService]) : usize
  (load (:misses svc)))

(define (cache-len [svc : EncoderService]) : usize
  (load (:cache-size svc)))
