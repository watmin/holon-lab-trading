;; ── vocab/flow.wat — volume flow indicators ─────────────────────
;;
;; OBV direction and divergence, VWAP distance, MFI zones,
;; buying/selling pressure from candle wicks, volume acceleration.
;; VWAP and pressure are window-dependent. MFI and OBV pre-computed.
;;
;; Lens: volume

(require facts)

;; ── OBV analysis ───────────────────────────────────────────────
;;
;; Returns a separate struct, not Fact data.
;; The encoder uses ObvFacts for custom bind patterns
;; (sign direction + divergence flag) that don't fit the Fact interface.

(struct obv-facts
  obv-sign               ; f64 — +1.0 rising, -1.0 falling, 0.0 flat
  obv-diverges)          ; bool — OBV and price disagree on direction

(define (obv-analysis now candles)
  "OBV direction from pre-computed slope. Divergence from price direction."
  (let ((slope (:obv-slope-12 now))
        (obv-sign (cond ((> slope 0.0) 1.0)
                        ((< slope 0.0) -1.0)
                        (else          0.0)))
        (n (len candles))
        (price-slope (cond ((>= n 12) (- (:close now) (:close (nth candles (- n 12)))))
                           ((>= n 2)  (- (:close now) (:close (first candles))))
                           (else      0.0)))
        (price-sign (cond ((> price-slope 0.0) 1.0)
                          ((< price-slope 0.0) -1.0)
                          (else                0.0))))
    (obv-facts :obv-sign obv-sign
               :obv-diverges (and (!= obv-sign 0.0)
                                  (!= price-sign 0.0)
                                  (!= obv-sign price-sign)))))

;; ── VWAP ───────────────────────────────────────────────────────

(define (vwap-distance candles)
  "Distance from volume-weighted average price, normalized by close.
   Returns None if cumulative volume is near zero."
  (let ((cum-vol-price (fold (lambda (sum c)
                               (+ sum (* (/ (+ (:high c) (:low c) (:close c)) 3.0)
                                         (:volume c))))
                             0.0 candles))
        (cum-vol (fold (lambda (sum c) (+ sum (:volume c))) 0.0 candles)))
    (when (> cum-vol 1e-10)
      (let ((vwap    (/ cum-vol-price cum-vol))
            (current (:close (last candles))))
        (/ (- current vwap) current)))))

;; ── Facts produced ─────────────────────────────────────────────

(define (eval-flow candles)
  "Volume flow facts. Returns (ObvFacts, Vec<Fact>)."
  (let ((now (last candles)))
    (let ((obv       (obv-analysis now candles))
          (mfi       (:mfi now))
          (vol-accel (:vol-accel now))
          (range     (- (:high now) (:low now))))
      (list obv
        (append
          ;; VWAP distance — window-dependent
          (when-let ((dist (vwap-distance candles)))
            (list (fact/scalar "vwap" (+ (* (clamp dist -1.0 1.0) 0.5) 0.5) 1.0)))

          ;; MFI zones — pre-computed
          (cond
            ((> mfi 80.0) (list (fact/zone "mfi" "mfi-overbought")))
            ((< mfi 20.0) (list (fact/zone "mfi" "mfi-oversold")))
            (else (list)))

          ;; Buying/selling pressure from wicks
          (if (> range 1e-10)
              (let ((body-top    (max (:close now) (:open now)))
                    (body-bottom (min (:close now) (:open now)))
                    (body        (- body-top body-bottom)))
                (list (fact/scalar "buy-pressure"  (/ (- body-bottom (:low now)) range) 1.0)
                      (fact/scalar "sell-pressure" (/ (- (:high now) body-top) range)    1.0)
                      (fact/scalar "body-ratio"    (/ body range)                        1.0)))
              (list))

          ;; Volume acceleration — pre-computed
          (cond
            ((> vol-accel 2.0) (list (fact/zone "volume" "volume-spike")))
            ((< vol-accel 0.3) (list (fact/zone "volume" "volume-drought")))
            (else (list))))))))

;; ── What flow does NOT do ──────────────────────────────────────
;; - Does NOT encode OBV into vectors (the encoder handles ObvFacts separately)
;; - Does NOT track cumulative OBV (pre-computed on Candle)
;; - Does NOT compute MFI (pre-computed on Candle)
;; - Pure function. Candles in, (ObvFacts, facts) out.
