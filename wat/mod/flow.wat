;; ── mod/flow — volume flow indicators ───────────────────────────────
;;
;; Used by: volume expert
;; Produces: flow direction facts, divergence facts, accumulation/distribution
;;
;; Volume tells you WHO is behind the move. Price tells you WHAT moved.
;; Flow tells you WHETHER the move has backing.

;; ── Currently implemented ───────────────────────────────────────────

;; Volume vs SMA (from eval_volume_analysis)
(atom "volume")
(atom "volume-sma")
(atom "volume-spike")        ; volume > 2× SMA
(atom "volume-drought")      ; volume < 0.5× SMA
;; Facts: (at volume volume-spike), (at volume volume-drought)

;; ── NOT YET IMPLEMENTED ─────────────────────────────────────────────

;; On-Balance Volume (OBV) — cumulative volume with sign
;; Close > prev_close: add volume. Close < prev_close: subtract volume.
;; OBV trending up while price flat = accumulation (bullish).
;; OBV trending down while price flat = distribution (bearish).
(atom "obv")
(atom "obv-sma")             ; 20-period SMA of OBV
(atom "obv-divergence-bull") ; price making lower lows, OBV making higher lows
(atom "obv-divergence-bear") ; price making higher highs, OBV making lower highs
;; Facts: (at obv obv-divergence-bull), OBV vs OBV-SMA crosses

;; VWAP (Volume Weighted Average Price) — the institutional benchmark
;; Intraday reference. Price above VWAP = bullish. Below = bearish.
;; Distance from VWAP = how extended the price is.
(atom "vwap")
(atom "above-vwap")
(atom "below-vwap")
(atom "vwap-distance")       ; (encode-linear (abs (- close vwap) / vwap) 1.0)
;; Facts: (above close vwap), distance as scalar

;; Accumulation/Distribution Line (A/D)
;; Measures money flow: (close - low) - (high - close) / (high - low) × volume
;; Close near high + high volume = accumulation. Near low = distribution.
(atom "ad-line")
(atom "ad-sma")
(atom "ad-divergence-bull")
(atom "ad-divergence-bear")
;; Facts: divergence with price, trend direction

;; Money Flow Index (MFI) — RSI but weighted by volume
;; Range: 0-100. Overbought > 80. Oversold < 20.
;; Volume-weighted momentum — catches exhaustion moves that RSI misses.
(atom "mfi")
(atom "mfi-overbought")
(atom "mfi-oversold")
;; Facts: zone facts. MFI diverging from price = strong signal.

;; Chaikin Money Flow (CMF) — 20-period average of A/D normalized by volume
;; Range: -1 to +1. Positive = accumulation. Negative = distribution.
(atom "cmf")
(atom "cmf-accumulation")   ; > 0.05
(atom "cmf-distribution")   ; < -0.05
(atom "cmf-neutral")        ; -0.05 to 0.05
;; Facts: zone facts, trend in CMF

;; Buying/Selling Pressure (estimated from wick analysis)
;; Upper wick = selling pressure. Lower wick = buying pressure.
;; Body ratio = conviction of the move.
(atom "buy-pressure")
(atom "sell-pressure")
(atom "body-ratio")          ; body / (high - low). Near 1 = strong candle.
;; Facts: (bind buy-pressure (encode-linear ratio 1.0))

;; ── Encoding rule ───────────────────────────────────────────────────
;; OBV/AD-line: encode-log (cumulative, spans orders of magnitude)
;; MFI/CMF: encode-linear scale=1.0 (bounded ranges)
;; VWAP distance: encode-linear scale=1.0 (fraction of price)
;; Divergence: binary atom (present/absent)
