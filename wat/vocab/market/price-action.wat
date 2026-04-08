;; price-action.wat — inside/outside bars, gaps, consecutive runs
;;
;; Depends on: candle
;; Domain: market (MarketLens :structure)
;;
;; Candlestick structure. Each pattern is a scalar fact, not a zone.
;; Inside bars compress. Outside bars expand. Gaps show momentum.
;; Consecutive runs show conviction.

(require primitives)
(require candle)

;; Inside bar: current range within previous range.
;; Scalar: how much of the previous range does the current cover?
;; 0.0 = tiny inside bar (extreme compression). 1.0 = barely inside.
;;
;; Outside bar: current range engulfs previous.
;; Scalar: how much bigger is the current range vs previous?
;; Log-encoded because ratio.
;;
;; Gap: (open - prev_close) / prev_close. Signed. Log magnitude.
;;
;; Consecutive runs: how many candles in the same direction?
;; Signed: positive = consecutive up, negative = consecutive down.
;; Log-encoded because the difference between 3 and 4 matters
;; more than 8 and 9.

(define (encode-price-action-facts [candle : Candle]
                                   [candles : Vec<Candle>])
  : Vec<ThoughtAST>
  (let ((n (len candles)))
    (if (< n 3)
      (list)
      (let* ((now       candle)
             (prev      (nth candles (- n 2)))
             (now-range (- (:high now) (:low now)))
             (prev-range (- (:high prev) (:low prev)))
             (facts     (list))

             ;; Inside bar
             (facts (if (and (<= (:high now) (:high prev))
                             (>= (:low now) (:low prev))
                             (> prev-range 1e-10))
                      (append facts
                        (list (Linear "inside-bar"
                                (/ now-range prev-range) 1.0)))
                      facts))

             ;; Outside bar
             (facts (if (and (> (:high now) (:high prev))
                             (< (:low now) (:low prev))
                             (> prev-range 1e-10))
                      (append facts
                        (list (Log "outside-bar"
                               (max (/ now-range prev-range) 1.0))))
                      facts))

             ;; Gap
             (gap (/ (- (:open now) (:close prev)) (:close prev)))
             (facts (if (> (abs gap) 0.001)
                      (append facts
                        (list (Bind (Atom "gap")
                                (Bind (Linear "gap-sign" (signum gap) 1.0)
                                      (Log "gap-mag" (max (abs gap) 0.001))))))
                      facts))

             ;; Consecutive runs
             (runs  (consecutive-runs candles))
             (up-ct (first runs))
             (dn-ct (second runs))
             (facts (if (>= up-ct 2)
                      (append facts
                        (list (Log "consec-up" (+ up-ct 0.0))))
                      facts))
             (facts (if (>= dn-ct 2)
                      (append facts
                        (list (Log "consec-down" (+ dn-ct 0.0))))
                      facts)))

        facts))))

;; Count consecutive same-direction candles from the most recent backwards.
;; Returns (up-count, down-count). At most one can be non-zero.
(define (consecutive-runs [candles : Vec<Candle>])
  : (usize usize)
  (let loop ((i (- (len candles) 1))
             (up 0) (down 0))
    (if (< i 0)
      (list up down)
      (let ((c (nth candles i)))
        (cond
          ((> (:close c) (:open c))
           (if (> down 0)
             (list up down)
             (loop (- i 1) (+ up 1) down)))
          ((< (:close c) (:open c))
           (if (> up 0)
             (list up down)
             (loop (- i 1) up (+ down 1))))
          (true (list up down)))))))
