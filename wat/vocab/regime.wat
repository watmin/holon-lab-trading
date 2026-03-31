;; ── vocab/regime.wat — market regime characterization ────────────
;;
;; Abstract properties of the price series. Is it trending or choppy?
;; Persistent or mean-reverting? Orderly or chaotic?
;; These survive window noise better than candle-level patterns.
;;
;; The fattest module. Eight independent regime measures plus
;; pre-computed trend/volatility/range scalars.
;;
;; Expert profile: regime (exclusive)

(require vocab/mod)

;; ── Atoms introduced ───────────────────────────────────────────

;; Indicators:   kama-er, chop, dfa-alpha, variance-ratio, td-count,
;;               aroon-up, fractal-dim, entropy-rate, gr-bvalue,
;;               trend-consistency-6, trend-consistency-12, trend-consistency-24,
;;               atr-roc-6, atr-roc-12,
;;               range-pos-12, range-pos-24, range-pos-48,
;;               trend, volatility
;;
;; Zones:        efficient-trend, inefficient-chop, moderate-efficiency,
;;               chop-trending, chop-choppy, chop-extreme, chop-transition,
;;               persistent-dfa, anti-persistent-dfa, random-walk-dfa,
;;               vr-momentum, vr-mean-revert, vr-neutral,
;;               td-exhausted, td-mature, td-building, td-inactive,
;;               aroon-strong-up, aroon-strong-down, aroon-stale, aroon-consolidating,
;;               trending-geometry, mean-reverting-geometry, random-walk-geometry,
;;               low-entropy-rate, high-entropy-rate,
;;               heavy-tails, light-tails,
;;               trend-strong, trend-choppy,
;;               vol-expanding, vol-contracting

;; ── Facts produced ─────────────────────────────────────────────

; rune:gaze(phantom) — fact/zone is not in the wat language
; rune:gaze(phantom) — fact/scalar is not in the wat language
(define (eval-regime candles)
  "Market regime facts. Minimum 20 candles."

  ;; ── KAMA Efficiency Ratio ──────────────────────────────────
  ;; ER = |net_move| / sum(|step_move|) over 10 periods.
  ;; 1.0 = perfectly trending. 0.0 = perfectly choppy.
  ;; Zone thresholds: > 0.6 efficient, < 0.3 inefficient. Empirical.
  (fact/zone "kama-er" (cond
    ((> er 0.6) "efficient-trend")
    ((< er 0.3) "inefficient-chop")
    (else       "moderate-efficiency")))

  ;; ── Choppiness Index (14-period) ───────────────────────────
  ;; 100 * log10(ATR_sum / range) / log10(period).
  ;; Low = trending. High = choppy.
  ;; Zone thresholds: < 38.2 trending, > 61.8 choppy, > 75 extreme.
  ;; 38.2 and 61.8 are Fibonacci ratios. Empirical/traditional.
  (fact/zone "chop" (cond
    ((< chop 38.2) "chop-trending")
    ((> chop 75.0) "chop-extreme")
    ((> chop 61.8) "chop-choppy")
    (else          "chop-transition")))

  ;; ── DFA Alpha (detrended fluctuation analysis) ─────────────
  ;; Log-log slope of fluctuation vs scale at scales [4, 6, 8, 12, 16].
  ;; Alpha > 0.6: persistent (trends). Alpha < 0.4: anti-persistent.
  ;; Clamped to [0, 1.5]. Needs >= 16 returns, >= 3 valid scales.
  ;; Thresholds: 0.6/0.4. Modest separation from 0.5 random walk.
  (when (>= (len returns) 16)
    (fact/zone "dfa-alpha" (cond
      ((> alpha 0.6) "persistent-dfa")
      ((< alpha 0.4) "anti-persistent-dfa")
      (else          "random-walk-dfa"))))

  ;; ── Variance Ratio (k=5) ──────────────────────────────────
  ;; VR = var(k-period returns) / (k * var(1-period returns)).
  ;; VR > 1: momentum. VR < 1: mean-reversion. VR = 1: random walk.
  ;; Needs >= 10 returns.
  ;; Thresholds: > 1.3 momentum, < 0.7 mean-revert. Empirical.
  (when (>= (len returns) 10)
    (fact/zone "variance-ratio" (cond
      ((> vr 1.3) "vr-momentum")
      ((< vr 0.7) "vr-mean-revert")
      (else       "vr-neutral"))))

  ;; ── DeMark TD Sequential ──────────────────────────────────
  ;; Counts consecutive closes above/below close[i-4].
  ;; Resets on direction change. Counts up (positive) or down (negative).
  ;; Needs >= 5 candles.
  ;; Thresholds: >= 9 exhausted, >= 7 mature, >= 4 building. TD standard levels.
  (when (>= n 5)
    (fact/zone "td-count" (cond
      ((>= abs-count 9) "td-exhausted")
      ((>= abs-count 7) "td-mature")
      ((>= abs-count 4) "td-building")
      (else             "td-inactive"))))

  ;; ── Aroon (25-period) ─────────────────────────────────────
  ;; aroon_up   = 100 * (periods_since_highest_high / 25)
  ;; aroon_down = 100 * (periods_since_lowest_low / 25)
  ;; Thresholds: up>80 & down<30 = strong up. down>80 & up<30 = strong down.
  ;; Both < 20 = stale. Else consolidating. Standard Aroon interpretation.
  (fact/zone "aroon-up" (cond
    ((and (> aroon-up 80) (< aroon-down 30)) "aroon-strong-up")
    ((and (> aroon-down 80) (< aroon-up 30)) "aroon-strong-down")
    ((and (< aroon-up 20) (< aroon-down 20)) "aroon-stale")
    (else                                     "aroon-consolidating")))

  ;; ── Fractal Dimension (Katz) ──────────────────────────────
  ;; FD = ln(N) / (ln(N) + ln(max_dist / path_len)).
  ;; FD near 1.0: straight line (trending). FD near 2.0: space-filling (noisy).
  ;; Clamped to [1.0, 2.0].
  ;; Thresholds: < 1.3 trending, > 1.7 mean-reverting. Geometric.
  (fact/zone "fractal-dim" (cond
    ((< fd 1.3) "trending-geometry")
    ((> fd 1.7) "mean-reverting-geometry")
    (else       "random-walk-geometry")))

  ;; ── Entropy Rate (bigram conditional entropy) ──────────────
  ;; Classify returns as up/flat/down. Build transition matrix.
  ;; H_cond = -sum(P(i)*P(j|i)*ln(P(j|i))). Normalize by ln(3).
  ;; Low entropy = predictable transitions. High = random.
  ;; Needs >= 20 returns.
  ;; Threshold: < 0.7 low-entropy. Empirical.
  ;; Return classification: > 0.01% = up, < -0.01% = down, else flat.
  (when (>= (len returns) 20)
    (fact/zone "entropy-rate" (cond
      ((< h-norm 0.7) "low-entropy-rate")
      (else           "high-entropy-rate"))))

  ;; ── Gutenberg-Richter b-value ─────────────────────────────
  ;; Seismology: frequency-magnitude relationship of return "quakes".
  ;; b < 1: heavy tails (extreme moves more likely). b > 1: light tails.
  ;; Log-log regression of exceedance count vs threshold.
  ;; Needs >= 20 returns, >= 3 valid thresholds.
  (when (>= (len returns) 20)
    (fact/zone "gr-bvalue" (cond
      ((< b 1.0) "heavy-tails")
      (else      "light-tails"))))

  ;; ── Pre-computed scalars from Candle ──────────────────────

  ;; Trend consistency — fraction of up-closes over recent periods
  ;; Scalar: scale 1.0. Values naturally [0, 1].
  (fact/scalar "trend-consistency-6"  tc6  1.0)
  (fact/scalar "trend-consistency-12" tc12 1.0)
  (fact/scalar "trend-consistency-24" tc24 1.0)

  ;; Trend agreement across scales
  ;; Zone: (at trend trend-strong) when tc6 > 0.8 AND tc12 > 0.7
  ;;        (at trend trend-choppy) when tc6 < 0.35 AND tc12 < 0.4
  ;; Thresholds: empirical. Strong = consistent at multiple scales.
  (when (and (> tc6 0.8) (> tc12 0.7))
    (fact/zone "trend" "trend-strong"))
  (when (and (< tc6 0.35) (< tc12 0.4))
    (fact/zone "trend" "trend-choppy"))

  ;; Volatility acceleration — ATR rate of change
  ;; Scalar: clamped [-1,1] mapped to [0,1], scale 1.0
  (fact/scalar "atr-roc-6"  (+ (* (clamp atr-roc-6 -1.0 1.0) 0.5) 0.5)  1.0)
  (fact/scalar "atr-roc-12" (+ (* (clamp atr-roc-12 -1.0 1.0) 0.5) 0.5) 1.0)

  ;; Zone: (at volatility vol-expanding)   when atr-roc-6 > 0.2
  ;;        (at volatility vol-contracting) when atr-roc-6 < -0.15
  ;; Thresholds: 0.2 / -0.15. Asymmetric — expansion is more notable.
  (when (> atr-roc-6  0.2)  (fact/zone "volatility" "vol-expanding"))
  (when (< atr-roc-6 -0.15) (fact/zone "volatility" "vol-contracting"))

  ;; Range position — where is price in the N-candle range? [0, 1]
  ;; Scalar: pre-computed, scale 1.0
  (fact/scalar "range-pos-12" rp12 1.0)
  (fact/scalar "range-pos-24" rp24 1.0)
  (fact/scalar "range-pos-48" rp48 1.0))

;; ── Magic numbers (honest accounting) ──────────────────────────
;;
;; KAMA ER: 0.6/0.3           — empirical, no theoretical basis
;; Choppiness: 38.2/61.8/75   — Fibonacci-derived tradition
;; DFA alpha: 0.6/0.4         — modest separation from 0.5
;; Variance ratio: 1.3/0.7    — empirical
;; TD Sequential: 9/7/4       — DeMark's standard levels
;; Aroon: 80/30/20            — standard Aroon interpretation
;; Fractal dim: 1.3/1.7       — geometric intuition
;; Entropy: 0.7               — empirical
;; GR b-value: 1.0            — theoretical (power law boundary)
;; Trend consistency: 0.8/0.7/0.35/0.4 — empirical
;; ATR-ROC: 0.2/-0.15         — empirical, asymmetric
;; Return class: 0.01%        — machine epsilon for crypto returns

;; ── What regime does NOT do ────────────────────────────────────
;; - Does NOT predict direction (it measures character)
;; - Does NOT compute Hurst or autocorrelation (that's persistence.wat)
;; - Does NOT import holon or create vectors
;; - The fattest module. Eight independent measurements.
;; - Pure function. Candles in, facts out.
