;; timeframe.wat — 1h/4h structure + narrative + inter-timeframe agreement
;;
;; Depends on: candle
;; Domain: market (MarketLens :narrative)
;;
;; Multi-timeframe analysis. 5-minute candles aggregate into 1h and 4h.
;; Structure: where is price geometrically? Narrative: what's the story?
;; Agreement: do timeframes confirm or contradict?

(require primitives)
(require candle)

;; 1h/4h body ratio — how decisive is the higher-timeframe candle?
;; Range [0, 1]. Pre-computed on Candle.
;;
;; 1h/4h range position — where is price in the higher-timeframe range?
;; Computed from tf-Xh-high and tf-Xh-low. Range [0, 1].
;;
;; 1h/4h return — signed. How much has the higher-timeframe moved?
;; Linear-encoded with scale 0.05 (5% is a large hourly move for BTC).
;;
;; Inter-timeframe agreement — do 5m, 1h, and 4h all point the same way?
;; Scalar: -1 = all disagree, +1 = all agree. Intermediate = partial.

(define (encode-timeframe-facts [candle : Candle]
                                [candles : Vec<Candle>])
  : Vec<ThoughtAST>
  (let* ((facts (list))

         ;; 1h structure
         (h-range (- (:tf-1h-high candle) (:tf-1h-low candle)))
         (facts (append facts
                  (list (Linear "tf-1h-body" (clamp (:tf-1h-body candle) 0.0 1.0) 1.0))))
         (facts (if (> h-range 1e-10)
                  (let ((pos (/ (- (:close candle) (:tf-1h-low candle)) h-range)))
                    (append facts (list (Linear "tf-1h-range-pos" (clamp pos 0.0 1.0) 1.0))))
                  facts))

         ;; 4h structure
         (h4-range (- (:tf-4h-high candle) (:tf-4h-low candle)))
         (facts (append facts
                  (list (Linear "tf-4h-body" (clamp (:tf-4h-body candle) 0.0 1.0) 1.0))))
         (facts (if (> h4-range 1e-10)
                  (let ((pos (/ (- (:close candle) (:tf-4h-low candle)) h4-range)))
                    (append facts (list (Linear "tf-4h-range-pos" (clamp pos 0.0 1.0) 1.0))))
                  facts))

         ;; 1h/4h returns — signed, linear
         (facts (if (> (abs (:tf-1h-ret candle)) 1e-10)
                  (append facts (list (Linear "tf-1h-ret" (:tf-1h-ret candle) 0.05)))
                  facts))
         (facts (if (> (abs (:tf-4h-ret candle)) 1e-10)
                  (append facts (list (Linear "tf-4h-ret" (:tf-4h-ret candle) 0.05)))
                  facts))

         ;; Inter-timeframe agreement
         (facts (if (>= (len candles) 2)
                  (let* ((prev     (nth candles (- (len candles) 2)))
                         (m5-dir   (signum (- (:close candle) (:close prev))))
                         (h1-dir   (signum (:tf-1h-ret candle)))
                         (h4-dir   (signum (:tf-4h-ret candle)))
                         ;; Agreement score: mean of pairwise agreements
                         ;; Each pair: +1 if same sign, -1 if opposite, 0 if either zero
                         (agree-m5-1h (if (or (= m5-dir 0.0) (= h1-dir 0.0)) 0.0
                                        (if (= m5-dir h1-dir) 1.0 -1.0)))
                         (agree-m5-4h (if (or (= m5-dir 0.0) (= h4-dir 0.0)) 0.0
                                        (if (= m5-dir h4-dir) 1.0 -1.0)))
                         (agree-1h-4h (if (or (= h1-dir 0.0) (= h4-dir 0.0)) 0.0
                                        (if (= h1-dir h4-dir) 1.0 -1.0)))
                         (agreement   (/ (+ agree-m5-1h agree-m5-4h agree-1h-4h) 3.0)))
                    (append facts (list (Linear "tf-agreement" agreement 1.0))))
                  facts)))

    facts))
