;; ── vocab/stochastic.wat — Stochastic Oscillator ────────────────
;;
;; %K vs %D comparison, crossover detection, overbought/oversold zones.
;; Reads pre-computed stoch_k, stoch_d from the Candle struct.
;; Cross detection uses current + previous candle.
;;
;; Lens: momentum

(require facts)

(define (eval-stochastic candles)
  "Stochastic oscillator facts. None if < 2 candles."
  (when (>= (len candles) 2)
    (let ((now     (last candles))
          (prev    (nth candles (- (len candles) 2)))
          (sk      (:stoch-k now))
          (sd      (:stoch-d now))
          (prev-sk (:stoch-k prev))
          (prev-sd (:stoch-d prev)))
      (append
        ;; K vs D position
        (list (if (> sk sd)
                  (fact/comparison "above" "stoch-k" "stoch-d")
                  (fact/comparison "below" "stoch-k" "stoch-d")))

        ;; Crossover: sign change between prev and current
        (cond
          ((and (< prev-sk prev-sd) (>= sk sd))
           (list (fact/comparison "crosses-above" "stoch-k" "stoch-d")))
          ((and (> prev-sk prev-sd) (<= sk sd))
           (list (fact/comparison "crosses-below" "stoch-k" "stoch-d")))
          (else (list)))

        ;; Overbought/oversold zones (80/20, standard levels)
        (cond
          ((> sk 80.0) (list (fact/zone "stoch-k" "stoch-overbought")))
          ((< sk 20.0) (list (fact/zone "stoch-k" "stoch-oversold")))
          (else (list)))))))

;; ── What stochastic does NOT do ────────────────────────────────
;; - Does NOT compute %K or %D (pre-computed on Candle)
;; - Does NOT use smoothed %D for zones (uses raw %K)
;; - Does NOT check StochRSI (that's oscillators.wat)
;; - Pure function. Candles in, facts out.
