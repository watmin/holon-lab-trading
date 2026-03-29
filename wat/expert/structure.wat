;; ── structure expert ────────────────────────────────────────────────
;;
;; Thinks about: geometric shape of price action.
;; Vocabulary: PELT segments, Ichimoku cloud, Fibonacci, Keltner,
;;             range position, comparisons, advanced regime indicators.
;; Window: sampled from [12, 2016] per candle.
;;
;; The structure expert sees spatial patterns — levels, channels,
;; cloud boundaries, retracement zones. Where is price relative
;; to significant geometric features?

;; ── Eval methods ────────────────────────────────────────────────────
;; eval_comparisons_cached  — (above close bb-upper), (below close sma200), etc.
;; eval_segment_narrative   — PELT changepoints → segment direction, duration, magnitude
;; eval_range_position      — where is close within the window's high-low range?
;; eval_ichimoku            — cloud zones (above/below/in), tenkan/kijun crosses
;; eval_fibonacci           — swing detection → fib retracement levels
;; eval_keltner             — Keltner channels, BB-inside-Keltner squeeze
;; eval_advanced            — DFA, entropy, fractal dim, variance ratio, aroon

;; ── Example thoughts ────────────────────────────────────────────────
;;
;; (bundle
;;   (bind above (bind close bb-upper))       ; price above Bollinger upper
;;   (bind at (bind close above-cloud))        ; price above Ichimoku cloud
;;   (bind at (bind close fib-618))            ; price near 61.8% retracement
;;   (bind at (bind keltner-upper keltner-lower))  ; squeeze detected
;;   (range-pos 0.85)                          ; close near range high
;;   (seg close up 234.5 dur=12 @0 ago=0)     ; PELT: close trending up for 12 candles
;;   ...)

;; ── WINDOW SENSITIVITY (critical) ──────────────────────────────────
;; Structure is the MOST window-dependent expert. PELT changepoints,
;; range position, and Fibonacci swing detection all change meaning
;; at different window sizes. A segment of "12 candles up" in a
;; 48-candle window is different from a segment of "12 candles up"
;; in a 500-candle window (same absolute, different relative).
;;
;; The segment narrative labels carry the scale implicitly:
;;   (seg close up 0.0234 dur=12 @0 ago=0)
;; Duration 12 and magnitude 0.0234 — these are absolute values.
;; But their SIGNIFICANCE changes with window. The discriminant
;; must learn this from the distribution it observes.
;;
;; DISCOVERY: Structure might benefit from a NARROWER window range
;; than other experts. Its vocabulary is most meaningful at scales
;; where PELT finds 3-8 segments (not 1 or 50). Could the window
;; sampler learn this range per expert?

;; ── What structure does NOT see ─────────────────────────────────────
;; - RSI-SMA relationships (momentum)
;; - RSI divergence (momentum)
;; - Stochastic zones (momentum)
;; - CCI/ROC (momentum)
;; - Calendar / sessions (narrative)
;; - Volume confirmation / analysis / price action (volume)
