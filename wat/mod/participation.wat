;; ── mod/participation — volume confirmation and price action ────────
;; Used by: volume expert
;;
;; Currently: eval_volume_confirmation, eval_price_action
;;
;; Not yet implemented:
;; - Volume breakout: volume > 3× SMA on a directional candle
;; - Volume dry-up: declining volume over N candles (low participation)
;; - Candle pattern strength: doji, hammer, engulfing scored by volume
;; - Relative volume: current vs same-hour historical average

(atom "volume-breakout")      ; volume spike + directional candle
(atom "volume-dry-up")        ; declining volume trend
(atom "doji")                 ; open ≈ close (indecision)
(atom "hammer")               ; long lower wick (buying at low)
(atom "engulfing-bull")       ; current candle engulfs previous bearish
(atom "engulfing-bear")       ; current candle engulfs previous bullish
(atom "relative-volume")      ; vs same hour of day historical average
