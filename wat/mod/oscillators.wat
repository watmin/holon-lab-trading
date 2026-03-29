;; ── mod/oscillators — momentum indicators ──────────────────────────
;;
;; Used by: momentum expert
;; Produces: zone facts (overbought/oversold), comparison facts
;;
;; Each oscillator produces a value in a bounded range.
;; The module encodes: (bind at (bind indicator zone))
;; where zone = the current state of the oscillator.

;; ── Currently implemented ───────────────────────────────────────────

;; RSI (14-period, pre-computed in candle DB)
(atom "rsi")
(atom "rsi-sma")            ; 14-period SMA of RSI
(atom "rsi-oversold")       ; RSI < 30
(atom "rsi-overbought")     ; RSI > 70
(atom "rsi-neutral")        ; 30 <= RSI <= 70
;; eval_rsi_sma_cached: (above rsi rsi-sma), (below rsi rsi-sma),
;;   (crosses-above rsi rsi-sma), (crosses-below rsi rsi-sma)

;; Stochastic (14-period K, 3-period D)
(atom "stoch-k")
(atom "stoch-d")
(atom "stoch-overbought")   ; K > 80
(atom "stoch-oversold")     ; K < 20
;; eval_stochastic: zone facts + K/D crosses

;; CCI (Commodity Channel Index, 20-period)
(atom "cci")
(atom "cci-overbought")     ; CCI > 100
(atom "cci-oversold")       ; CCI < -100
;; eval_momentum: CCI zone facts

;; ── NOT YET IMPLEMENTED (from VOCAB_UNDERDOGS.md) ──────────────────

;; Williams %R (14-period) — like stochastic but inverted, -100 to 0
;; Range: [-100, 0]. Overbought < -20. Oversold > -80.
;; Similar to stochastic but measures close relative to high-low range.
(atom "williams-r")
(atom "williams-overbought")  ; %R < -20
(atom "williams-oversold")    ; %R > -80
;; Facts: (at williams-r williams-overbought), zone crosses

;; Stochastic RSI — RSI of RSI, 0-1 range
;; More sensitive than raw RSI. Catches earlier turns.
(atom "stoch-rsi")
(atom "stoch-rsi-overbought") ; > 0.8
(atom "stoch-rsi-oversold")   ; < 0.2
;; Facts: zone facts + crosses with signal line

;; Ultimate Oscillator (7, 14, 28 periods) — multi-timeframe momentum
;; Range: 0-100. Combines three timeframes into one reading.
;; Overbought > 70. Oversold < 30.
(atom "ult-osc")
(atom "ult-osc-overbought")
(atom "ult-osc-oversold")
;; Facts: zone facts. Divergence with price (via divergence module).

;; Rate of Change (ROC) — price change as percentage over N periods
;; Already partially in eval_momentum, but could be richer.
;; Multiple timeframes: ROC-5, ROC-10, ROC-20
(atom "roc-5")
(atom "roc-10")
(atom "roc-20")
;; Facts: (bind roc-5 (encode-linear value 1.0)), comparison between timeframes
;; Accelerating: ROC-5 > ROC-10 > ROC-20 = momentum increasing

;; ── Encoding rule ───────────────────────────────────────────────────
;; All oscillators bounded [0, 100] or [-100, 100] → encode-linear scale=1.0
;; Zone facts: binary (present or absent) via atom lookup
;; Cross facts: (crosses-above indicator threshold) via stdlib comparisons
