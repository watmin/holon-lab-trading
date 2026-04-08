;; ── vocab/price-action.wat — candlestick patterns and price structure ──
;;
;; Inside bars, outside bars, gaps, consecutive same-direction candles.
;; Pure pattern detection from raw OHLC data. No indicators needed.
;;
;; Lens: volume

(require facts)

(define (consecutive-runs candles)
  "Count consecutive bullish and bearish candles from most recent backward.
   Returns (up-count, down-count). One reversal, one pass."
  (let ((rev (reverse candles)))
    (fold (lambda (acc c)
            (list (if (> (:close c) (:open c)) (+ (first acc) 1) (first acc))
                  (if (< (:close c) (:open c)) (+ (second acc) 1) (second acc))))
          (list 0 0) rev)))

(define (eval-price-action candles)
  "Price action pattern facts. Minimum 3 candles."
  (when (>= (len candles) 3)
    (let ((now  (last candles))
          (prev (nth candles (- (len candles) 2))))
      (let ((now-high   (:high now))
            (now-low    (:low now))
            (now-open   (:open now))
            (prev-high  (:high prev))
            (prev-low   (:low prev))
            (prev-close (:close prev))
            (runs       (consecutive-runs candles))
            (up-count   (first runs))
            (down-count (second runs)))
        (append
          ;; Inside bar — current range within previous range
          (if (and (<= now-high prev-high) (>= now-low prev-low))
              (list (fact/zone "close" "inside-bar"))
              (list))

          ;; Outside bar — current range engulfs previous
          (if (and (> now-high prev-high) (< now-low prev-low))
              (list (fact/zone "close" "outside-bar"))
              (list))

          ;; Gap detection
          (let ((gap (/ (- now-open prev-close) prev-close)))
            (cond
              ((> gap 0.001)  (list (fact/zone "close" "gap-up")))
              ((< gap -0.001) (list (fact/zone "close" "gap-down")))
              (else (list))))

          ;; Consecutive same-direction candles
          (if (>= up-count 3)   (list (fact/zone "close" "consecutive-up"))   (list))
          (if (>= down-count 3) (list (fact/zone "close" "consecutive-down")) (list)))))))

;; ── What price-action does NOT do ──────────────────────────────
;; - Does NOT detect doji, hammer, shooting star, etc. (future work)
;; - Does NOT compute body/wick ratios (that's flow.wat buy-pressure)
;; - Does NOT emit scalars (patterns are binary — present or not)
;; - Pure function. Candles in, facts out.
