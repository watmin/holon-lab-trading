;; ── mod/crosses — signal line and moving average crosses ────────────
;; Used by: momentum expert
;;
;; Currently: temporal lookback through PELT segments (eval_temporal)
;;
;; Not yet implemented:
;; - SMA cross timing: how many candles since SMA20 crossed SMA50?
;; - MACD histogram direction change (not just line cross)
;; - Stochastic K/D cross strength (angle of cross)
;; - Multiple timeframe cross agreement

(atom "sma-golden-cross")     ; short SMA crossed above long SMA
(atom "sma-death-cross")      ; short SMA crossed below long SMA
(atom "cross-age")            ; how many candles since last cross
(atom "macd-hist-turn")       ; histogram changed direction
(atom "stoch-kd-cross-up")    ; K crossed above D
(atom "stoch-kd-cross-down")  ; K crossed below D
(atom "cross-strength")       ; angle/speed of the cross
