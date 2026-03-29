;; ── mod/persistence — trend persistence and memory ──────────────────
;;
;; Used by: regime expert
;; Produces: regime classification facts
;;
;; These indicators measure PROPERTIES of the price series:
;; "Is this market trending or mean-reverting? Persistent or random?"
;; They don't predict direction — they predict character.

;; ── Currently implemented (in eval_advanced) ────────────────────────

;; DFA Alpha (Detrended Fluctuation Analysis)
(atom "dfa-alpha")
(atom "persistent-dfa")       ; alpha > 0.6 — trends continue
(atom "anti-persistent-dfa")  ; alpha < 0.4 — mean-reverting
(atom "random-walk-dfa")      ; 0.4-0.6 — unpredictable
;; The strongest regime indicator. Survived gates when others failed.

;; Variance Ratio (Lo-MacKinlay)
(atom "variance-ratio")
(atom "vr-momentum")          ; VR > 1.1 — momentum regime
(atom "vr-mean-revert")       ; VR < 0.9 — mean-reverting regime
(atom "vr-neutral")           ; 0.9-1.1 — efficient/random

;; ── NOT YET IMPLEMENTED ─────────────────────────────────────────────

;; Hurst Exponent (R/S analysis) — related to DFA but different computation
;; H > 0.5: persistent (trends continue). H < 0.5: anti-persistent.
;; H = 0.5: random walk. Gives a continuous measure, not just zones.
(atom "hurst")
(atom "hurst-trending")       ; H > 0.55
(atom "hurst-reverting")      ; H < 0.45
(atom "hurst-random")         ; 0.45-0.55
;; Facts: zone facts + (bind hurst (encode-linear H 1.0))

;; Autocorrelation of Returns (lag 1-5)
;; Positive autocorrelation = momentum. Negative = mean-reversion.
;; Multiple lags reveal the memory structure of the price series.
(atom "autocorr-1")           ; lag-1 autocorrelation
(atom "autocorr-5")           ; lag-5 autocorrelation
(atom "autocorr-positive")    ; significant positive autocorrelation
(atom "autocorr-negative")    ; significant negative autocorrelation
;; Facts: (bind autocorr-1 (encode-linear value 1.0)), zone facts
;; Note: holon has autocorrelate() primitive — could use that directly

;; Trend Strength (ADX-derived or custom)
;; ADX > 25: strong trend. ADX < 20: no trend.
;; Already in the candle DB as adx. Currently only in comparisons.
;; Should have explicit zone encoding.
(atom "adx")
(atom "strong-trend")         ; ADX > 25
(atom "weak-trend")           ; ADX < 20
(atom "moderate-trend")       ; 20-25
;; Facts: zone facts + (bind adx (encode-linear value/100 1.0))

;; Regime Transition Detection
;; When DFA or VR or Hurst changes zone: "regime shift in progress"
;; This is a CHANGE fact, not a state fact. Uses difference().
(atom "regime-shift")
(atom "trending-to-reverting")
(atom "reverting-to-trending")
(atom "entering-random")
;; Facts: transition atoms when zone changes detected

;; ── Encoding rule ───────────────────────────────────────────────────
;; DFA/Hurst/VR: encode-linear scale=1.0 (bounded continuous values)
;; Autocorrelation: encode-linear scale=1.0 (range [-1, 1], shifted to [0,1])
;; ADX: encode-linear scale=1.0 (0-100 normalized)
;; Transitions: binary atoms (present when change detected)
