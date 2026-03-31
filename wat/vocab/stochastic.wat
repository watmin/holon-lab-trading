;; ── vocab/stochastic.wat — Stochastic Oscillator ────────────────
;;
;; %K vs %D comparison, crossover detection, overbought/oversold zones.
;; Reads pre-computed stoch_k, stoch_d from the Candle struct.
;; Cross detection uses current + previous candle.
;;
;; Expert profile: momentum

(require vocab/mod)
(require std-candidates)

;; ── Atoms introduced ───────────────────────────────────────────

;; Indicators:   stoch-k, stoch-d
;; Predicates:   above, below, crosses-above, crosses-below
;; Zones:        stoch-overbought, stoch-oversold

;; ── Facts produced ─────────────────────────────────────────────

(define (eval-stochastic candles)
  "Stochastic oscillator facts. Returns Some(Vec<Fact>) or None if < 2 candles."

  ;; K vs D position
  ;; Comparison: (above stoch-k stoch-d) or (below stoch-k stoch-d)
  (if (> stoch-k stoch-d)
      (fact/comparison "above" "stoch-k" "stoch-d")
      (fact/comparison "below" "stoch-k" "stoch-d"))

  ;; Crossover detection — compares current and previous candle
  ;; Comparison: (crosses-above stoch-k stoch-d) when prev_k < prev_d AND curr_k >= curr_d
  ;;              (crosses-below stoch-k stoch-d) when prev_k > prev_d AND curr_k <= curr_d
  ;; No threshold. Pure sign change detection.
  (when (and (< prev-k prev-d) (>= stoch-k stoch-d))
    (fact/comparison "crosses-above" "stoch-k" "stoch-d"))
  (when (and (> prev-k prev-d) (<= stoch-k stoch-d))
    (fact/comparison "crosses-below" "stoch-k" "stoch-d"))

  ;; Overbought/oversold zone
  ;; Zone: (at stoch-k stoch-overbought) when %K > 80
  ;;        (at stoch-k stoch-oversold)   when %K < 20
  ;; Thresholds: 80/20. Standard stochastic levels.
  (when (> stoch-k 80.0) (fact/zone "stoch-k" "stoch-overbought"))
  (when (< stoch-k 20.0) (fact/zone "stoch-k" "stoch-oversold")))

;; ── Minimum: 2 candles ─────────────────────────────────────────
;; Need current + previous for cross detection.

;; ── What stochastic does NOT do ────────────────────────────────
;; - Does NOT compute %K or %D (pre-computed on Candle)
;; - Does NOT use smoothed %D for zones (uses raw %K)
;; - Does NOT check StochRSI (that's oscillators.wat)
;; - Does NOT import holon or create vectors
;; - Pure function. Candles in, facts out.
