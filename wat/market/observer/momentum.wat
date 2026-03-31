;; ── momentum expert ─────────────────────────────────────────────────
;;
;; Thinks about: speed and direction of price change.
;; Window: sampled from [12, 2016] per candle (discovers own scale).
;;
;; (require stdlib)            ; comparisons, zones
;; (require mod/oscillators)   ; RSI, stochastic, CCI, Williams %R, UltOsc, StochRSI, ROC
;; (require mod/divergence)    ; RSI div, stochastic div, MACD div, multi-indicator div
;; (require mod/crosses)       ; SMA crosses, MACD histogram, K/D cross, temporal lookback

;; ── Eval methods ────────────────────────────────────────────────────
;; eval_comparisons_cached  — (above close sma50), (crosses-above macd-line macd-signal), etc.
;; eval_rsi_sma_cached      — (above rsi rsi-sma), (crosses-below rsi rsi-sma)
;; eval_divergence          — RSI divergence via PELT peak detection
;; eval_stochastic          — (at stoch-k stoch-overbought), %K/%D crosses
;; eval_momentum            — CCI zones (overbought/oversold), ROC
;; eval_oscillators_module  — Williams %R, StochRSI, UltOsc, multi-ROC

;; ── Example thoughts ────────────────────────────────────────────────
;;
;; (bundle
;;   (bind above (bind close sma50))         ; price above SMA50
;;   (bind crosses-above (bind macd-line macd-signal))  ; MACD golden cross
;;   (bind at (bind stoch-k stoch-overbought))          ; stochastic overbought
;;   (bind above (bind rsi rsi-sma))                     ; RSI above its SMA
;;   (seg rsi up 0.0234 dur=8 @0 ago=0)                 ; via eval_temporal
;;   ...)

;; ── What momentum sees ──────────────────────────────────────────────
;; - Comparisons: close vs SMA, MACD line vs signal, DMI+ vs DMI-
;; - Oscillator zones: RSI overbought/oversold, stochastic zones, CCI zones
;; - Crosses: MACD crossing signal, RSI crossing its SMA (temporal lookback)
;; - Divergence: RSI diverging from price (PELT structural peaks)
;; - Oscillators: Williams %R, StochRSI, UltOsc, multi-ROC

;; ── What momentum does NOT see ──────────────────────────────────────
;; - Calendar / time of day (that's narrative)
;; - PELT segment narrative (that's narrative + structure)
;; - Fibonacci levels (that's structure)
;; - Ichimoku cloud (that's structure)
;; - Range position (that's structure)
;; - Keltner / squeeze (that's structure)
;; - Volume confirmation / analysis / price action (that's volume)

;; ── RESOLVED ────────────────────────────────────────────────────────
;; Advanced regime indicators (DFA, entropy, fractal dim, variance ratio,
;; aroon, choppiness) now belong to regime ONLY. Momentum no longer sees
;; them. The comparison dispatch was also restricted: only momentum and
;; structure see comparisons. Volume, narrative, and regime do not.
