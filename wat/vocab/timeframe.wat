;; ── vocab/timeframe.wat — inter-timeframe structure and narrative ──
;;
;; Split by domain: structure sees geometry (range position, body ratio).
;; Narrative sees the story (direction agreement, return magnitude).
;; Each expert gets the thoughts that belong to its way of thinking.
;;
;; Expert profiles: structure (eval-timeframe-structure),
;;                  narrative (eval-timeframe-narrative)

(require vocab/mod)
(require std-candidates)

;; ── Atoms introduced ───────────────────────────────────────────

;; Structure indicators: tf-1h-body, tf-4h-body, tf-1h-range-pos, tf-4h-range-pos
;; Narrative indicators: tf-1h, tf-4h, tf-1h-ret, tf-4h-ret
;; Narrative zones:      tf-1h-up-strong, tf-1h-up-mild,
;;                       tf-1h-down-strong, tf-1h-down-mild,
;;                       tf-4h-up-strong, tf-4h-up-mild,
;;                       tf-4h-down-strong, tf-4h-down-mild
;; Bare facts:           tf-all-agree, tf-all-disagree,
;;                       tf-1h-agrees, tf-4h-agrees

;; ── Structure facts ────────────────────────────────────────────

(define (eval-timeframe-structure candles)
  "Multi-timeframe geometry. Pre-computed values from Candle."

  ;; Body ratios — how decisive is each timeframe's candle?
  ;; Scalar: clamped [0, 1], scale 1.0
  ;; 0 = all wick (indecision). 1 = all body (conviction).
  (fact/scalar "tf-1h-body" (clamp tf-1h-body 0.0 1.0) 1.0)
  (fact/scalar "tf-4h-body" (clamp tf-4h-body 0.0 1.0) 1.0)

  ;; Range position — where is close within the hourly/4h range?
  ;; Scalar: (close - low) / (high - low), clamped [0, 1], scale 1.0
  ;; Only emitted when range > 1e-10.
  (when (> h-range 1e-10)
    (fact/scalar "tf-1h-range-pos" (clamp h-pos 0.0 1.0) 1.0))
  (when (> h4-range 1e-10)
    (fact/scalar "tf-4h-range-pos" (clamp h4-pos 0.0 1.0) 1.0)))

;; ── Narrative facts ────────────────────────────────────────────

(define (eval-timeframe-narrative candles)
  "Multi-timeframe story. Pre-computed returns from Candle."

  ;; 1-hour return direction and magnitude
  ;; Zone: tf-1h-up-strong   (ret > 0.5%), tf-1h-up-mild   (ret > 0)
  ;;        tf-1h-down-strong (ret < -0.5%), tf-1h-down-mild (ret < 0)
  ;; Scalar: ret clamped to [-5%, 5%], scaled to [0, 1]
  ;; Thresholds: 0.5% for "strong". Empirical for 1h crypto returns.
  (when (> (abs tf-1h-ret) 1e-10)
    (fact/zone "tf-1h" (cond
      ((> tf-1h-ret 0.005)  "tf-1h-up-strong")
      ((> tf-1h-ret 0.0)    "tf-1h-up-mild")
      ((< tf-1h-ret -0.005) "tf-1h-down-strong")
      (else                  "tf-1h-down-mild")))
    (fact/scalar "tf-1h-ret" (+ (* (clamp tf-1h-ret -0.05 0.05) 10.0) 0.5) 1.0))

  ;; 4-hour return direction and magnitude
  ;; Zone: tf-4h-up-strong   (ret > 1%), tf-4h-up-mild   (ret > 0)
  ;;        tf-4h-down-strong (ret < -1%), tf-4h-down-mild (ret < 0)
  ;; Scalar: ret clamped to [-5%, 5%], scaled to [0, 1]
  ;; Thresholds: 1% for "strong". Larger window = larger threshold.
  (when (> (abs tf-4h-ret) 1e-10)
    (fact/zone "tf-4h" (cond
      ((> tf-4h-ret 0.01)  "tf-4h-up-strong")
      ((> tf-4h-ret 0.0)   "tf-4h-up-mild")
      ((< tf-4h-ret -0.01) "tf-4h-down-strong")
      (else                 "tf-4h-down-mild")))
    (fact/scalar "tf-4h-ret" (+ (* (clamp tf-4h-ret -0.05 0.05) 10.0) 0.5) 1.0))

  ;; Inter-timeframe agreement — do 5m, 1h, and 4h agree on direction?
  ;; Compares current 5m return sign with 1h and 4h return signs.
  ;; Needs >= 2 candles for 5m direction.
  ;; Bare: (tf-all-agree)    — all three timeframes same direction
  ;;        (tf-all-disagree) — both higher timeframes disagree with 5m
  ;;        (tf-1h-agrees)   — 1h agrees, 4h disagrees
  ;;        (tf-4h-agrees)   — 4h agrees, 1h disagrees
  ;; No thresholds. Pure sign comparison.
  (when (>= n 2)
    (cond
      ((and agree-1h agree-4h) (fact/bare "tf-all-agree"))
      ((and (not agree-1h) (not agree-4h)) (fact/bare "tf-all-disagree"))
      (agree-1h (fact/bare "tf-1h-agrees"))
      (else     (fact/bare "tf-4h-agrees")))))

;; ── What timeframe does NOT do ─────────────────────────────────
;; - Does NOT aggregate candles (aggregation pre-computed at load time)
;; - Does NOT compute moving averages at higher timeframes
;; - Does NOT emit comparison facts (positions are scalar, not relational)
;; - Does NOT import holon or create vectors
;; - Two functions. Two domains. Same source data.
