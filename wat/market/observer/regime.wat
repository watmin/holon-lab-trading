;; rune:assay(prose) — regime.wat lists the vocabulary atoms but does not express
;; eval dispatch or encoding. One instantiation line; the rest is description.

;; ── regime expert ──────────────────────────────────────────────────
;;
;; Thinks about: what KIND of market this is, not which direction.
;; Window: sampled from [min-window, max-window] per candle.
;; The purest expert — no comparisons, no segments, no calendar, no volume.

(require core/primitives)
(require core/structural)
(require common)
(require patterns)

;; ── Vocabulary ──────────────────────────────────────────────────────
;;
;; Regime characterization (vocab/regime module):
;;   (bind :at (bind :kama-er       :efficient-trend))           ; ER > 0.6
;;   (bind :at (bind :kama-er       :inefficient-chop))          ; ER < 0.3
;;   (bind :at (bind :chop          :chop-trending))             ; CI < 38.2
;;   (bind :at (bind :chop          :chop-choppy))               ; CI > 61.8
;;   (bind :at (bind :chop          :chop-extreme))              ; CI > 75.0
;;   (bind :at (bind :dfa-alpha     :persistent-dfa))            ; alpha > 0.6
;;   (bind :at (bind :dfa-alpha     :anti-persistent-dfa))       ; alpha < 0.4
;;   (bind :at (bind :dfa-alpha     :random-walk-dfa))           ; 0.4 <= alpha <= 0.6
;;   (bind :at (bind :variance-ratio :vr-momentum))              ; VR > 1.3
;;   (bind :at (bind :variance-ratio :vr-mean-revert))           ; VR < 0.7
;;   (bind :at (bind :td-count      :td-exhausted))              ; DeMark >= 9
;;   (bind :at (bind :td-count      :td-mature))                 ; DeMark >= 7
;;   (bind :at (bind :td-count      :td-building))               ; DeMark >= 4
;;   (bind :at (bind :aroon-up      :aroon-strong-up))           ; aroon_up > 80, down < 30
;;   (bind :at (bind :aroon-up      :aroon-strong-down))         ; aroon_down > 80, up < 30
;;   (bind :at (bind :aroon-up      :aroon-consolidating))       ; neither dominant
;;   (bind :at (bind :fractal-dim   :trending-geometry))         ; FD < 1.3
;;   (bind :at (bind :fractal-dim   :mean-reverting-geometry))   ; FD > 1.7
;;   (bind :at (bind :entropy-rate  :low-entropy-rate))          ; normalized H < 0.7
;;   (bind :at (bind :entropy-rate  :high-entropy-rate))         ; normalized H >= 0.7
;;   (bind :at (bind :gr-bvalue     :heavy-tails))               ; b < 1.0
;;   (bind :at (bind :gr-bvalue     :light-tails))               ; b >= 1.0
;;
;; Trend consistency (multi-scale):
;;   (bind :trend-consistency-6  (encode-linear tc6 1.0))        ; fraction of last 6 same-dir
;;   (bind :trend-consistency-12 (encode-linear tc12 1.0))
;;   (bind :trend-consistency-24 (encode-linear tc24 1.0))
;;   (bind :at (bind :trend :trend-strong))                      ; tc6 > 0.8 AND tc12 > 0.7
;;   (bind :at (bind :trend :trend-choppy))                      ; tc6 < 0.35 AND tc12 < 0.4
;;
;; Volatility acceleration:
;;   (bind :atr-roc-6  (encode-linear atr-roc-6 1.0))           ; ATR rate of change
;;   (bind :atr-roc-12 (encode-linear atr-roc-12 1.0))
;;   (bind :at (bind :volatility :vol-expanding))                ; atr_roc_6 > 0.2
;;   (bind :at (bind :volatility :vol-contracting))              ; atr_roc_6 < -0.15
;;
;; Range position (multi-scale):
;;   (bind :range-pos-12 (encode-linear rp12 1.0))              ; where in 12-candle range
;;   (bind :range-pos-24 (encode-linear rp24 1.0))
;;   (bind :range-pos-48 (encode-linear rp48 1.0))
;;
;; Persistence (vocab/persistence module):
;;   (bind :hurst    (encode-linear hurst 1.0))                  ; H > 0.5 persistent
;;   (bind :at (bind :hurst :hurst-trending))                    ; H > 0.55
;;   (bind :at (bind :hurst :hurst-reverting))                   ; H < 0.45
;;   (bind :autocorr (encode-linear autocorr 1.0))               ; lag-1 autocorrelation
;;   (bind :at (bind :autocorr :autocorr-positive))              ; > 0.1 (momentum)
;;   (bind :at (bind :autocorr :autocorr-negative))              ; < -0.1 (mean-reversion)
;;   (bind :at (bind :adx (atom (adx-zone adx))))                ; strong/moderate/weak trend

;; ── The expert ──────────────────────────────────────────────────────

;; expert: shorthand for (new-observer profile dims refit-interval seed labels).
;; See market/observer.wat for the Observer struct.
(define regime
  (new-observer "regime" dims refit-interval :seed-regime ["Buy" "Sell"]))

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
