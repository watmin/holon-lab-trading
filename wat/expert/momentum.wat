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
;; eval_temporal            — lookback through PELT segments for cross timing
;; eval_rsi_sma_cached      — (above rsi rsi-sma), (crosses-below rsi rsi-sma)
;; eval_divergence          — RSI divergence via PELT peak detection
;; eval_stochastic          — (at stoch-k stoch-overbought), %K/%D crosses
;; eval_momentum            — CCI zones (overbought/oversold), ROC
;; eval_advanced            — DeMark, choppiness, DFA, variance ratio, aroon, fractal dim, entropy

;; ── Example thoughts ────────────────────────────────────────────────
;;
;; (bundle
;;   (bind above (bind close sma50))         ; price above SMA50
;;   (bind crosses-above (bind macd-line macd-signal))  ; MACD golden cross
;;   (bind at (bind stoch-k stoch-overbought))          ; stochastic overbought
;;   (bind above (bind rsi rsi-sma))                     ; RSI above its SMA
;;   (bind at (bind dfa-alpha persistent-dfa))           ; DFA says trending
;;   (seg rsi up 0.0234 dur=8 @0 ago=0)                 ; via eval_temporal
;;   ...)

;; ── What momentum sees ──────────────────────────────────────────────
;; - Comparisons: close vs SMA, MACD line vs signal, DMI+ vs DMI-
;; - Oscillator zones: RSI overbought/oversold, stochastic zones, CCI zones
;; - Crosses: MACD crossing signal, RSI crossing its SMA (temporal lookback)
;; - Divergence: RSI diverging from price (PELT structural peaks)
;; - Regime: DFA alpha (trending/random/mean-reverting), variance ratio,
;;   entropy rate, choppiness index, aroon, fractal dimension

;; ── What momentum does NOT see ──────────────────────────────────────
;; - Calendar / time of day (that's narrative)
;; - PELT segment narrative (that's narrative + structure)
;; - Fibonacci levels (that's structure)
;; - Ichimoku cloud (that's structure)
;; - Range position (that's structure)
;; - Keltner / squeeze (that's structure)
;; - Volume confirmation / analysis / price action (that's volume)

;; ── DISCOVERY ───────────────────────────────────────────────────────
;; Momentum shares eval_advanced with structure and regime. This means
;; DFA alpha, entropy rate, fractal dimension appear in THREE experts.
;; Is this intentional? The same fact in multiple experts' bundles
;; means the manager sees it three times (via three signed convictions).
;; This may dilute the signal or reinforce it depending on whether
;; the three experts agree. Worth investigating: should advanced
;; indicators belong to regime ONLY?
