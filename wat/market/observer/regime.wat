;; ── regime expert ──────────────────────────────────────────────────
;;
;; Thinks about: what KIND of market this is, not which direction.
;; Window: sampled from [min-window, max-window] per candle.
;; The purest expert — no comparisons, no segments, no calendar, no volume.

(require core/primitives)
(require core/structural)
(require facts)
(require patterns)

;; ── Profile dispatch ────────────────────────────────────────────────

(define (encode-regime candles)
  "Regime's thought: regime characterization + persistence."
  (append
    (eval-regime-module candles)        ; KAMA-ER, choppiness, DFA, VR, DeMark, Aroon, fractal dim, entropy, tails, trend consistency, vol accel, range pos
    (eval-persistence-module candles))) ; Hurst, autocorrelation, ADX zones

;; ── The expert ──────────────────────────────────────────────────────

(define regime
  (new-observer "regime" dims refit-interval :seed-regime ["Buy" "Sell"]))

;; ── Example thoughts ────────────────────────────────────────────────
;;
;; (fact/zone "kama-er" "efficient-trend")              ; ER > 0.6
;; (fact/zone "chop" "chop-choppy")                     ; CI > 61.8
;; (fact/zone "dfa-alpha" "persistent-dfa")             ; alpha > 0.6
;; (fact/zone "variance-ratio" "vr-mean-revert")        ; VR < 0.7
;; (fact/zone "hurst" "hurst-trending")                 ; H > 0.55
;; (fact/zone "autocorr" "autocorr-negative")           ; lag-1 < -0.1 (mean-reversion)
;; (fact/zone "td-count" "td-exhausted")                ; DeMark >= 9
;; (fact/zone "fractal-dim" "trending-geometry")        ; FD < 1.3

;; ── RESOLVED ────────────────────────────────────────────────────────
;; Regime EXCLUSIVELY owns eval_regime and eval_persistence.
;; No comparisons, no segments, no calendar, no volume.
;; This purity is WHY it's the most gate-stable expert:
;; DFA alpha, entropy, fractal dimension measure SERIES PROPERTIES
;; that survive window noise. The other experts' vocabularies depend
;; on candle values at specific positions — different sampled windows
;; give different values. Regime's facts describe the NATURE of the
;; sequence, not the values. Abstraction is robustness.

;; ── What regime does NOT see ────────────────────────────────────────
;; - Comparisons (momentum, structure)
;; - PELT segments (narrative, structure)
;; - Temporal crosses (narrative, momentum)
;; - Oscillators: RSI, stochastic, CCI (momentum)
;; - Cloud / fibonacci / keltner (structure)
;; - Volume (volume)
;; - Calendar (narrative)
