;; divergence.wat — RSI divergence via PELT structural peaks
;;
;; Depends on: candle
;; Domain: market (MarketLens :narrative)
;;
;; Structural divergence: price and RSI disagree at turning points.
;; PELT finds structural segments. Consecutive peaks/troughs reveal
;; divergence. The scalar is the magnitude of disagreement.

(require primitives)
(require candle)

;; Divergence facts. When price makes higher highs but RSI makes
;; lower highs: bearish divergence. When price makes lower lows
;; but RSI makes higher lows: bullish divergence.
;;
;; The fact carries the magnitude of both the price and indicator
;; deltas — not a boolean "diverges/doesn't." The discriminant
;; learns how much divergence matters.

(define (encode-divergence-facts [candles : Vec<Candle>])
  : Vec<ThoughtAST>
  (if (< (len candles) 10)
    (list)
    (let* ((close-ln   (map (lambda (c) (ln (:close c))) candles))
           (penalty    (bic-penalty close-ln))
           (cps        (pelt-changepoints close-ln penalty))
           (n          (len close-ln))
           (boundaries (append (list 0) (append cps (list n))))
           (n-segs     (- (len boundaries) 1)))

      (if (< n-segs 3)
        (list)
        (let* ((seg-dirs (map (lambda (i)
                           (segment-direction boundaries i close-ln))
                         (range 0 n-segs)))
               (peaks   (find-peaks seg-dirs boundaries))
               (troughs (find-troughs seg-dirs boundaries))
               (facts   (list))

               ;; Bearish: price higher high, RSI lower high
               (facts (fold-left
                        (lambda (acc pair)
                          (let ((prev (first pair))
                                (curr (second pair)))
                            (if (and (> (:close (nth candles curr))
                                        (:close (nth candles prev)))
                                     (< (:rsi (nth candles curr))
                                        (:rsi (nth candles prev))))
                              (let ((price-delta (/ (- (:close (nth candles curr))
                                                       (:close (nth candles prev)))
                                                    (:close (nth candles prev))))
                                    (rsi-delta   (- (:rsi (nth candles curr))
                                                    (:rsi (nth candles prev)))))
                                (append acc
                                  (list (Bind (Atom "bearish-divergence")
                                          (Bind (Linear "price-delta" price-delta 0.1)
                                                (Linear "rsi-delta" rsi-delta 1.0))))))
                              acc)))
                        facts (sliding-pairs peaks)))

               ;; Bullish: price lower low, RSI higher low
               (facts (fold-left
                        (lambda (acc pair)
                          (let ((prev (first pair))
                                (curr (second pair)))
                            (if (and (< (:close (nth candles curr))
                                        (:close (nth candles prev)))
                                     (> (:rsi (nth candles curr))
                                        (:rsi (nth candles prev))))
                              (let ((price-delta (/ (- (:close (nth candles curr))
                                                       (:close (nth candles prev)))
                                                    (:close (nth candles prev))))
                                    (rsi-delta   (- (:rsi (nth candles curr))
                                                    (:rsi (nth candles prev)))))
                                (append acc
                                  (list (Bind (Atom "bullish-divergence")
                                          (Bind (Linear "price-delta" price-delta 0.1)
                                                (Linear "rsi-delta" rsi-delta 1.0))))))
                              acc)))
                        facts (sliding-pairs troughs))))

          facts)))))

;; Segment direction: +1 (up), -1 (down), 0 (flat).
(define (segment-direction [boundaries : Vec<usize>]
                           [i : usize]
                           [values : Vec<f64>])
  : i8
  (let ((change (- (nth values (- (nth boundaries (+ i 1)) 1))
                   (nth values (nth boundaries i)))))
    (cond ((> change 1e-10)  1)
          ((< change -1e-10) -1)
          (true              0))))

;; Peaks: up-segment meets down-segment (structural highs).
(define (find-peaks [seg-dirs : Vec<i8>]
                    [boundaries : Vec<usize>])
  : Vec<usize>
  (filter-map (lambda (i)
    (if (and (= (nth seg-dirs i) 1)
             (= (nth seg-dirs (+ i 1)) -1))
      (Some (- (nth boundaries (+ i 1)) 1))
      None))
    (range 0 (- (length seg-dirs) 1))))

;; Troughs: down-segment meets up-segment (structural lows).
(define (find-troughs [seg-dirs : Vec<i8>]
                      [boundaries : Vec<usize>])
  : Vec<usize>
  (filter-map (lambda (i)
    (if (and (= (nth seg-dirs i) -1)
             (= (nth seg-dirs (+ i 1)) 1))
      (Some (- (nth boundaries (+ i 1)) 1))
      None))
    (range 0 (- (length seg-dirs) 1))))

;; Sliding pairs: [a, b, c] → [(a, b), (b, c)].
(define (sliding-pairs [xs : Vec<usize>])
  : Vec<(usize usize)>
  (if (< (length xs) 2)
    (list)
    (map (lambda (i) (list (nth xs i) (nth xs (+ i 1))))
      (range 0 (- (length xs) 1)))))

;; PELT changepoints and BIC penalty — provided by the substrate.
;; Declared here for interface clarity.
;; (pelt-changepoints values penalty) → Vec<usize>
;; (bic-penalty values) → f64
