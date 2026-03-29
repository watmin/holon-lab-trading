;; ── mod/channels — price envelope and channel indicators ────────────
;; Used by: structure expert
;;
;; Currently: ichimoku, keltner, bollinger (from eval_ichimoku, eval_keltner)
;;
;; Not yet implemented:
;; - Donchian channels (N-period high/low)
;; - Price envelopes (SMA ± N%)
;; - Supertrend indicator
;; - Parabolic SAR
;;
;; Each channel produces: above/below/inside facts + squeeze detection.
;; Structure: (bind at (bind close above-channel))

(atom "donchian-upper") (atom "donchian-lower") (atom "donchian-mid")
(atom "above-donchian") (atom "below-donchian") (atom "in-donchian")
(atom "supertrend") (atom "supertrend-bull") (atom "supertrend-bear")
(atom "parabolic-sar") (atom "sar-below") (atom "sar-above") (atom "sar-flip")
