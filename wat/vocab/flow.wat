;; ── vocab/flow.wat — volume flow indicators ─────────────────────
;;
;; OBV direction and divergence, VWAP distance, MFI zones,
;; buying/selling pressure from candle wicks, volume acceleration.
;; VWAP and pressure are window-dependent. MFI and OBV pre-computed.
;;
;; Expert profile: volume

(require vocab/mod)
(require std/facts)

;; ── Atoms introduced ───────────────────────────────────────────

;; Indicators:   vwap, mfi, buy-pressure, sell-pressure, body-ratio, volume
;; Zones:        mfi-overbought, mfi-oversold, volume-spike, volume-drought

;; ── Special return: ObvFacts ───────────────────────────────────
;;
;; OBV analysis returns a separate struct, not Fact data.
;; The encoder uses ObvFacts for custom bind patterns
;; (sign direction + divergence flag) that don't fit the Fact interface.

(struct obv-facts
  obv-sign               ; f64 — +1.0 rising, -1.0 falling, 0.0 flat
  obv-diverges)          ; bool — OBV and price disagree on direction

;; OBV direction from pre-computed obv_slope_12.
;; Divergence: OBV going one way, price going the other over ~12 candles.

;; ── Facts produced ─────────────────────────────────────────────

(define (eval-flow candles)
  "Volume flow facts. Returns (ObvFacts, Vec<Fact>)."

  ;; VWAP distance — window-dependent, computed from raw candles
  ;; vwap = cumulative(typical_price * volume) / cumulative(volume)
  ;; distance = (close - vwap) / close, clamped to [-1, 1], scaled to [0, 1]
  ;; Scalar: (vwap value) scale 1.0
  (fact/scalar "vwap" (+ (* (clamp dist -1.0 1.0) 0.5) 0.5) 1.0)

  ;; MFI — pre-computed on Candle (14-period)
  ;; Zone: (at mfi mfi-overbought) when mfi > 80
  ;;        (at mfi mfi-oversold)   when mfi < 20
  ;; Thresholds: 80/20. Standard MFI levels.
  (fact/zone "mfi" (cond
    ((> mfi 80.0) "mfi-overbought")
    ((< mfi 20.0) "mfi-oversold")))

  ;; Buying/selling pressure from candle wicks — per-candle
  ;; buy-pressure  = (body_bottom - low) / range — lower wick ratio
  ;; sell-pressure = (high - body_top) / range — upper wick ratio
  ;; body-ratio    = body / range — decisiveness of the candle
  ;; All [0, 1]. Only emitted when range > 1e-10.
  ;; Scalar: scale 1.0
  (when (> range 1e-10)
    (fact/scalar "buy-pressure"  bp 1.0)
    (fact/scalar "sell-pressure" sp 1.0)
    (fact/scalar "body-ratio"    br 1.0))

  ;; Volume acceleration — pre-computed vol_accel on Candle
  ;; vol_accel = volume / volume_sma_20
  ;; Zone: (at volume volume-spike)   when > 2.0x average
  ;;        (at volume volume-drought) when < 0.3x average
  ;; Thresholds: 2.0 (spike), 0.3 (drought). Empirical.
  (fact/zone "volume" (cond
    ((> vol-accel 2.0) "volume-spike")
    ((< vol-accel 0.3) "volume-drought"))))

;; ── What flow does NOT do ──────────────────────────────────────
;; - Does NOT encode OBV into vectors (the encoder handles ObvFacts separately)
;; - Does NOT track cumulative OBV (pre-computed on Candle)
;; - Does NOT compute MFI (pre-computed on Candle)
;; - Does NOT import holon or create vectors
;; - Pure function. Candles in, (ObvFacts, facts) out.
