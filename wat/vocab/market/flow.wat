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
;; obv-slope and volume-ratio use the natural form
;; `(ReciprocalLog 10.0 (exp x))` — exp lifts the signed slope to
;; (0, ∞), ReciprocalLog 10 encodes via reciprocal bounds (0.1, 10).
;; Originally arc 014 shipped these as `Thermometer x (-ln 10)
;; (ln 10)` — algebraic equivalence to skip the missing exp
;; primitive. wat-rs arc 046 added `:wat::std::math::exp`; arc 015
;; sweeps the call sites to the natural form. N=10 matches arc 010
;; regime's variance-ratio precedent (coarse-near-1, fine-across-
;; range); empirical refinement deferred.
;;
;; RANGE-CONDITIONAL PATTERN. Three atoms (buying-pressure,
;; selling-pressure, body-ratio) guard `(field) / range` against
;; zero-range candles via `if (high - low) > 0`. Compute range
;; once, guard once via `range-positive`, branch per atom.
;; Different defaults (0.5 / 0.5 / 0.0) fight a shared helper;
;; stay inline per stdlib-as-blueprint.
;;
;; abs(close - open) — uses substrate `:wat::core::f64::abs`
;; (wat-rs arc 046). Originally inline two-arm `if` here; the lab
;; clamp-extraction conversation in arc 015 promoted the whole
;; numeric basics family (max/min/abs/clamp + math::exp) to the
;; substrate.

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
    (((obv-slope-12 :wat::core::f64)
      (:trading::types::Candle::Momentum/obv-slope-12 m))
     ((volume-accel :wat::core::f64)
      (:trading::types::Candle::Momentum/volume-accel m))
     ((vwap-distance-raw :wat::core::f64)
      (:trading::types::Candle::Persistence/vwap-distance p))
     ((open :wat::core::f64) (:trading::types::Ohlcv/open o))
     ((high :wat::core::f64) (:trading::types::Ohlcv/high o))
     ((low :wat::core::f64) (:trading::types::Ohlcv/low o))
     ((close :wat::core::f64) (:trading::types::Ohlcv/close o))

     ;; vwap-distance — direct scaled-linear at round-to-4.
     ((vwap-distance :wat::core::f64)
      (:trading::encoding::round-to-4 vwap-distance-raw))

     ;; Range-conditional compute setup.
     ((range :wat::core::f64) (:wat::core::- high low))
     ((range-positive :wat::core::bool) (:wat::core::> range 0.0))

     ;; buying-pressure: (close - low) / range else 0.5
     ((buying-pressure :wat::core::f64)
      (:wat::core::if range-positive -> :wat::core::f64
        (:trading::encoding::round-to-2
          (:wat::core::/
            (:wat::core::- close low) range))
        0.5))

     ;; selling-pressure: (high - close) / range else 0.5
     ((selling-pressure :wat::core::f64)
      (:wat::core::if range-positive -> :wat::core::f64
        (:trading::encoding::round-to-2
          (:wat::core::/
            (:wat::core::- high close) range))
        0.5))

     ;; body-ratio: abs(close - open) / range else 0.0. abs via
     ;; substrate f64::abs (wat-rs arc 046).
     ((abs-body :wat::core::f64)
      (:wat::core::f64::abs (:wat::core::- close open)))
     ((body-ratio :wat::core::f64)
      (:wat::core::if range-positive -> :wat::core::f64
        (:trading::encoding::round-to-2
          (:wat::core::/ abs-body range))
        0.0))

     ;; obv-slope via ReciprocalLog 10 of exp(slope) — Bind directly,
     ;; no scales. exp lifts signed slope to (0, ∞); ReciprocalLog 10
     ;; encodes via reciprocal bounds (0.1, 10).
     ((h1 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "obv-slope")
        (:wat::holon::ReciprocalLog 10.0
          (:wat::std::math::exp obv-slope-12))))

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

     ;; volume-ratio via ReciprocalLog 10 of exp(volume-accel) —
     ;; same shape as obv-slope.
     ((h5 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "volume-ratio")
        (:wat::holon::ReciprocalLog 10.0
          (:wat::std::math::exp volume-accel))))

     ;; body-ratio via scaled-linear.
     ((e6 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "body-ratio" body-ratio s4))
     ((h6 :wat::holon::HolonAST) (:wat::core::first e6))
     ((s6 :trading::encoding::Scales) (:wat::core::second e6))

     ;; Assemble the Holons vec.
     ((holons :wat::holon::Holons)
      (:wat::core::vec :wat::holon::HolonAST h1 h2 h3 h4 h5 h6)))
    (:wat::core::tuple holons s6)))
