;; ── vocab/price-action.wat — candlestick patterns and price structure ──
;;
;; Inside bars, outside bars, gaps, consecutive same-direction candles.
;; Pure pattern detection from raw OHLC data. No indicators needed.
;;
;; Expert profile: volume

(require vocab/mod)
(require std-candidates)

;; ── Atoms introduced ───────────────────────────────────────────

;; Indicators:   close
;; Zones:        inside-bar, outside-bar,
;;               gap-up, gap-down,
;;               consecutive-up, consecutive-down

;; ── Facts produced ─────────────────────────────────────────────

(define (eval-price-action candles)
  "Price action pattern facts. Minimum 3 candles."

  ;; Inside bar — current range within previous range
  ;; Zone: (at close inside-bar)
  ;; No threshold. Pure geometric containment.
  (when (and (<= now-high prev-high) (>= now-low prev-low))
    (fact/zone "close" "inside-bar"))

  ;; Outside bar — current range engulfs previous
  ;; Zone: (at close outside-bar)
  ;; No threshold. Pure geometric engulfment.
  (when (and (> now-high prev-high) (< now-low prev-low))
    (fact/zone "close" "outside-bar"))

  ;; Gap — opening price vs previous close
  ;; gap = (open - prev_close) / prev_close
  ;; Zone: (at close gap-up)   when gap > 0.1%
  ;;        (at close gap-down) when gap < -0.1%
  ;; Threshold: 0.1%. Filters micro-gaps in 5-minute crypto data.
  (let ((gap (/ (- now-open prev-close) prev-close)))
    (when (> gap 0.001)  (fact/zone "close" "gap-up"))
    (when (< gap -0.001) (fact/zone "close" "gap-down")))

  ;; Consecutive same-direction candles — counting from most recent
  ;; Zone: (at close consecutive-up)   when >= 3 consecutive bullish candles
  ;;        (at close consecutive-down) when >= 3 consecutive bearish candles
  ;; Threshold: 3 candles. Minimal run length for signal.
  ;; Bullish candle: close > open. Bearish: close < open.
  (when (>= up-count 3)   (fact/zone "close" "consecutive-up"))
  (when (>= down-count 3) (fact/zone "close" "consecutive-down")))

;; ── Minimum: 3 candles ─────────────────────────────────────────
;; Need current + previous for bars/gaps, 3 for consecutive.

;; ── What price-action does NOT do ──────────────────────────────
;; - Does NOT detect doji, hammer, shooting star, etc. (future work)
;; - Does NOT compute body/wick ratios (that's flow.wat buy-pressure)
;; - Does NOT emit scalars (patterns are binary — present or not)
;; - Does NOT import holon or create vectors
;; - Pure function. Candles in, facts out.
