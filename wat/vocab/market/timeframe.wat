;; wat/vocab/market/timeframe.wat — Phase 2.9 (lab arc 011).
;;
;; Port of archived/pre-wat-native/src/vocab/market/timeframe.rs
;; (59L). Six scaled-linear atoms describing 1h/4h trend structure
;; and inter-timeframe alignment:
;;
;;   tf-1h-trend       — 1h body direction
;;   tf-1h-ret         — 1h return fraction (4-decimal precision)
;;   tf-4h-trend       — 4h body direction
;;   tf-4h-ret         — 4h return fraction (4-decimal precision)
;;   tf-agreement      — multi-timeframe coherence
;;   tf-5m-1h-align    — computed: signum(tf-1h-body) × 5m return
;;
;; THIRD CROSS-SUB-STRUCT VOCAB. First Ohlcv read in a vocab
;; module. Signature order alphabetical by leaf type name —
;; arc 011 clarified arc 008's rule to specify leaf (unqualified)
;; name, not full path. O < T → Ohlcv first, Candle::Timeframe
;; second. Scales last.
;;
;; One atom (tf-5m-1h-align) crosses both sub-structs in its
;; computation — uses Ohlcv's close/open for the 5-minute return
;; AND Candle::Timeframe's tf-1h-body for the sign. First compute
;; atom that's genuinely cross-sub-struct (earlier modules read
;; from multiple sub-structs but computed each atom from a single
;; one).

(:wat::load-file! "../../types/candle.wat")
(:wat::load-file! "../../types/ohlcv.wat")
(:wat::load-file! "../../encoding/round.wat")
(:wat::load-file! "../../encoding/scale-tracker.wat")
(:wat::load-file! "../../encoding/scaled-linear.wat")

(:wat::core::define
  (:trading::vocab::market::timeframe::encode-timeframe-holons
    (o :trading::types::Ohlcv)
    (t :trading::types::Candle::Timeframe)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::VocabEmission)
  (:wat::core::let*
    ;; Pull Timeframe-side raw values.
    (((tf-1h-body-raw :wat::core::f64)
      (:trading::types::Candle::Timeframe/tf-1h-body t))
     ((tf-1h-ret-raw :wat::core::f64)
      (:trading::types::Candle::Timeframe/tf-1h-ret t))
     ((tf-4h-body-raw :wat::core::f64)
      (:trading::types::Candle::Timeframe/tf-4h-body t))
     ((tf-4h-ret-raw :wat::core::f64)
      (:trading::types::Candle::Timeframe/tf-4h-ret t))
     ((tf-agreement-raw :wat::core::f64)
      (:trading::types::Candle::Timeframe/tf-agreement t))

     ;; Pull Ohlcv-side raw values (for tf-5m-1h-align compute).
     ((close :wat::core::f64) (:trading::types::Ohlcv/close o))
     ((open :wat::core::f64)  (:trading::types::Ohlcv/open o))

     ;; Round to the archive's digit widths.
     ((tf-1h-trend :wat::core::f64) (:trading::encoding::round-to-2 tf-1h-body-raw))
     ((tf-1h-ret   :wat::core::f64) (:trading::encoding::round-to-4 tf-1h-ret-raw))
     ((tf-4h-trend :wat::core::f64) (:trading::encoding::round-to-2 tf-4h-body-raw))
     ((tf-4h-ret   :wat::core::f64) (:trading::encoding::round-to-4 tf-4h-ret-raw))
     ((tf-agreement :wat::core::f64) (:trading::encoding::round-to-2 tf-agreement-raw))

     ;; Cross-sub-struct compute: signum(tf-1h-body) × 5m return,
     ;; rounded to 4 decimals. signum inline (single use).
     ((signum-1h :wat::core::f64)
      (:wat::core::if (:wat::core::> tf-1h-body-raw 0.0) -> :wat::core::f64
        1.0
        (:wat::core::if (:wat::core::< tf-1h-body-raw 0.0) -> :wat::core::f64
          (:wat::core::- 0.0 1.0)
          0.0)))
     ((five-m-ret :wat::core::f64)
      (:wat::core::/
        (:wat::core::- close open) close))
     ((tf-5m-1h-align :wat::core::f64)
      (:trading::encoding::round-to-4
        (:wat::core::* signum-1h five-m-ret)))

     ;; Thread Scales through six scaled-linear calls.
     ((e1 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "tf-1h-trend" tf-1h-trend scales))
     ((h1 :wat::holon::HolonAST) (:wat::core::first e1))
     ((s1 :trading::encoding::Scales) (:wat::core::second e1))

     ((e2 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "tf-1h-ret" tf-1h-ret s1))
     ((h2 :wat::holon::HolonAST) (:wat::core::first e2))
     ((s2 :trading::encoding::Scales) (:wat::core::second e2))

     ((e3 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "tf-4h-trend" tf-4h-trend s2))
     ((h3 :wat::holon::HolonAST) (:wat::core::first e3))
     ((s3 :trading::encoding::Scales) (:wat::core::second e3))

     ((e4 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "tf-4h-ret" tf-4h-ret s3))
     ((h4 :wat::holon::HolonAST) (:wat::core::first e4))
     ((s4 :trading::encoding::Scales) (:wat::core::second e4))

     ((e5 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "tf-agreement" tf-agreement s4))
     ((h5 :wat::holon::HolonAST) (:wat::core::first e5))
     ((s5 :trading::encoding::Scales) (:wat::core::second e5))

     ((e6 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "tf-5m-1h-align" tf-5m-1h-align s5))
     ((h6 :wat::holon::HolonAST) (:wat::core::first e6))
     ((s6 :trading::encoding::Scales) (:wat::core::second e6))

     ;; Assemble the Holons vec.
     ((holons :wat::holon::Holons)
      (:wat::core::vec :wat::holon::HolonAST h1 h2 h3 h4 h5 h6)))
    (:wat::core::tuple holons s6)))
