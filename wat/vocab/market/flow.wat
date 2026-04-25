;; wat/vocab/market/flow.wat — Phase 2.11 (lab arc 014).
;;
;; Port of archived/pre-wat-native/src/vocab/market/flow.rs (47L).
;; Six atoms describing volume flow + intra-bar pressure:
;;
;;   obv-slope         — OBV trend slope, log-bound around 0
;;   vwap-distance     — distance from volume-weighted average
;;   buying-pressure   — close position in candle range (low end)
;;   selling-pressure  — close position in candle range (high end)
;;   volume-ratio      — volume acceleration, log-bound around 0
;;   body-ratio        — body width as fraction of full range
;;
;; FIFTH CROSS-SUB-STRUCT VOCAB. **First K=3 module** (Momentum +
;; Ohlcv + Persistence). Signature alphabetical-by-leaf per arc
;; 011: M < O < P.
;;
;; SUBSTRATE-GAP / ALGEBRAIC-EQUIVALENCE WORKAROUND. The archive
;; encodes obv-slope and volume-ratio as `Log(exp(x))` chains —
;; lift signed slope to positive via exp, encode as Log. wat-rs's
;; :wat::std::math has ln/log/sin/cos/pi but no exp. Algebraic
;; equivalence: `Log(exp(x), 1/N, N)` ≡ `Thermometer(x, -ln(N),
;; ln(N))`. We encode the signed slope directly via Thermometer at
;; log-bounds — semantically identical, zero substrate cost. N=10
;; chosen to match arc 010 regime's variance-ratio precedent;
;; ships as best-current-estimate, empirical refinement deferred.
;;
;; RANGE-CONDITIONAL PATTERN. Three atoms (buying-pressure,
;; selling-pressure, body-ratio) guard `(field) / range` against
;; zero-range candles via `if (high - low) > 0`. Compute range
;; once, guard once via `range-positive`, branch per atom.
;; Different defaults (0.5 / 0.5 / 0.0) fight a shared helper;
;; stay inline per stdlib-as-blueprint.
;;
;; abs(close - open) — single inline use for body-ratio. Two-arm
;; if matches arc 011's signum + arc 009's clamp shape. Extract to
;; shared/helpers.wat if a third caller surfaces.

(:wat::load-file! "../../types/candle.wat")
(:wat::load-file! "../../types/ohlcv.wat")
(:wat::load-file! "../../encoding/round.wat")
(:wat::load-file! "../../encoding/scale-tracker.wat")
(:wat::load-file! "../../encoding/scaled-linear.wat")

(:wat::core::define
  (:trading::vocab::market::flow::encode-flow-holons
    (m :trading::types::Candle::Momentum)
    (o :trading::types::Ohlcv)
    (p :trading::types::Candle::Persistence)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::VocabEmission)
  (:wat::core::let*
    ;; Pull raw values once.
    (((obv-slope-12 :f64)
      (:trading::types::Candle::Momentum/obv-slope-12 m))
     ((volume-accel :f64)
      (:trading::types::Candle::Momentum/volume-accel m))
     ((vwap-distance-raw :f64)
      (:trading::types::Candle::Persistence/vwap-distance p))
     ((open :f64) (:trading::types::Ohlcv/open o))
     ((high :f64) (:trading::types::Ohlcv/high o))
     ((low :f64) (:trading::types::Ohlcv/low o))
     ((close :f64) (:trading::types::Ohlcv/close o))

     ;; Log-bound Thermometer bounds (-ln 10, ln 10) ≈ (-2.3, 2.3).
     ;; Equivalent to ReciprocalLog 10 of exp(value); the algebraic
     ;; equivalence lets us skip exp (missing from wat-rs) by going
     ;; straight to the Thermometer at log-bounds.
     ((ln-N :f64) (:wat::std::math::ln 10.0))
     ((neg-ln-N :f64) (:wat::core::f64::- 0.0 ln-N))

     ;; vwap-distance — direct scaled-linear at round-to-4.
     ((vwap-distance :f64)
      (:trading::encoding::round-to-4 vwap-distance-raw))

     ;; Range-conditional compute setup.
     ((range :f64) (:wat::core::f64::- high low))
     ((range-positive :bool) (:wat::core::> range 0.0))

     ;; buying-pressure: (close - low) / range else 0.5
     ((buying-pressure :f64)
      (:wat::core::if range-positive -> :f64
        (:trading::encoding::round-to-2
          (:wat::core::f64::/
            (:wat::core::f64::- close low) range))
        0.5))

     ;; selling-pressure: (high - close) / range else 0.5
     ((selling-pressure :f64)
      (:wat::core::if range-positive -> :f64
        (:trading::encoding::round-to-2
          (:wat::core::f64::/
            (:wat::core::f64::- high close) range))
        0.5))

     ;; body-ratio: abs(close - open) / range else 0.0.
     ;; abs inline — single use, two-arm if (signum/clamp shape).
     ((body :f64) (:wat::core::f64::- close open))
     ((abs-body :f64)
      (:wat::core::if (:wat::core::>= body 0.0) -> :f64
        body
        (:wat::core::f64::- 0.0 body)))
     ((body-ratio :f64)
      (:wat::core::if range-positive -> :f64
        (:trading::encoding::round-to-2
          (:wat::core::f64::/ abs-body range))
        0.0))

     ;; obv-slope via log-bound Thermometer — Bind directly, no scales.
     ((h1 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "obv-slope")
        (:wat::holon::Thermometer obv-slope-12 neg-ln-N ln-N)))

     ;; vwap-distance via scaled-linear.
     ((e2 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "vwap-distance" vwap-distance scales))
     ((h2 :wat::holon::HolonAST) (:wat::core::first e2))
     ((s2 :trading::encoding::Scales) (:wat::core::second e2))

     ;; buying-pressure via scaled-linear.
     ((e3 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "buying-pressure" buying-pressure s2))
     ((h3 :wat::holon::HolonAST) (:wat::core::first e3))
     ((s3 :trading::encoding::Scales) (:wat::core::second e3))

     ;; selling-pressure via scaled-linear.
     ((e4 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "selling-pressure" selling-pressure s3))
     ((h4 :wat::holon::HolonAST) (:wat::core::first e4))
     ((s4 :trading::encoding::Scales) (:wat::core::second e4))

     ;; volume-ratio via log-bound Thermometer — same shape as obv-slope.
     ((h5 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "volume-ratio")
        (:wat::holon::Thermometer volume-accel neg-ln-N ln-N)))

     ;; body-ratio via scaled-linear.
     ((e6 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "body-ratio" body-ratio s4))
     ((h6 :wat::holon::HolonAST) (:wat::core::first e6))
     ((s6 :trading::encoding::Scales) (:wat::core::second e6))

     ;; Assemble the Holons vec.
     ((holons :wat::holon::Holons)
      (:wat::core::vec :wat::holon::HolonAST h1 h2 h3 h4 h5 h6)))
    (:wat::core::tuple holons s6)))
