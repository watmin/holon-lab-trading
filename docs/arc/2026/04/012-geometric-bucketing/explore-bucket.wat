;; explore-bucket.wat — arc 012 fog-breaker (2026-04-23).
;;
;; Empirical observation of the geometric bucketing rule against
;; the current round-to-2 value quantization. For each value pair
;; (v1, v2) at a chosen scale, tabulate:
;;
;;   round-to-2(v1), round-to-2(v2)   — current cache-key values
;;   current-same?                    — do they hit the same cache key?
;;   bucket-width = scale × noise-floor
;;   bucket(v1, s), bucket(v2, s)     — geometric-bucketed values
;;   bucketed-same?                   — do they hit the same cache key?
;;   coincident?(T(v1), T(v2))        — does the substrate say they're equal?
;;
;; The proof point: bucketed-same? should agree with coincident?
;; EXACTLY — every pair that's substrate-equivalent buckets to the
;; same cache key; every distinguishable pair buckets to distinct
;; keys. The current round-to-2 agrees with coincident? only
;; accidentally — where the quantization happens to align with the
;; shell boundaries.
;;
;; How to run (from the lab dir):
;;   cargo run --manifest-path=../../../../../wat-rs/Cargo.toml --bin wat -- \
;;     docs/arc/2026/04/012-geometric-bucketing/explore-bucket.wat


;; ─── helpers ──────────────────────────────────────────────────────

;; Current quantization — what every vocab module uses today.
(:wat::core::define
  (:explore::round-to-2
    (v :f64)
    -> :f64)
  (:wat::core::f64::round v 2))

;; Proposed quantization — bucket at scale × noise-floor.
(:wat::core::define
  (:explore::bucket
    (v :f64)
    (scale :f64)
    (nf :f64)
    -> :f64)
  (:wat::core::let*
    (((bw :f64) (:wat::core::f64::* scale nf))
     ((idx :f64) (:wat::core::f64::round (:wat::core::f64::/ v bw) 0)))
    (:wat::core::f64::* idx bw)))

;; Print one row for a given (v1, v2, scale) triple.
(:wat::core::define
  (:explore::print-row
    (stdout :wat::io::IOWriter)
    (v1 :f64)
    (v2 :f64)
    (scale :f64)
    (nf :f64)
    -> :())
  (:wat::core::let*
    (((r1 :f64) (:explore::round-to-2 v1))
     ((r2 :f64) (:explore::round-to-2 v2))
     ((curr-same :bool) (:wat::core::= r1 r2))
     ((bw :f64) (:wat::core::f64::* scale nf))
     ((b1 :f64) (:explore::bucket v1 scale nf))
     ((b2 :f64) (:explore::bucket v2 scale nf))
     ((buck-same :bool) (:wat::core::= b1 b2))
     ((t1 :wat::holon::HolonAST)
      (:wat::holon::Thermometer v1
        (:wat::core::f64::- 0.0 scale) scale))
     ((t2 :wat::holon::HolonAST)
      (:wat::holon::Thermometer v2
        (:wat::core::f64::- 0.0 scale) scale))
     ((coinc :bool) (:wat::holon::coincident? t1 t2))
     ((line :String)
      (:wat::core::string::join "\t"
        (:wat::core::vec :String
          (:wat::core::f64::to-string v1)
          (:wat::core::f64::to-string v2)
          (:wat::core::f64::to-string scale)
          (:wat::core::f64::to-string bw)
          (:wat::core::f64::to-string r1)
          (:wat::core::f64::to-string r2)
          (:wat::core::bool::to-string curr-same)
          (:wat::core::f64::to-string b1)
          (:wat::core::f64::to-string b2)
          (:wat::core::bool::to-string buck-same)
          (:wat::core::bool::to-string coinc)))))
    (:wat::io::IOWriter/println stdout line)))

;; ─── main ────────────────────────────────────────────────────────

(:wat::core::define (:user::main
                     (stdin  :wat::io::IOReader)
                     (stdout :wat::io::IOWriter)
                     (stderr :wat::io::IOWriter)
                     -> :())
  (:wat::core::let*
    (((nf :f64) (:wat::config::noise-floor))
     ((_ :()) (:wat::io::IOWriter/println stdout
                (:wat::core::string::join ""
                  (:wat::core::vec :String
                    "d=1024  noise-floor=" (:wat::core::f64::to-string nf)
                    "  (coincident? fires when cosine > "
                    (:wat::core::f64::to-string
                      (:wat::core::f64::- 1.0 nf))
                    ")"))))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "v1\tv2\tscale\tbkt-w\tr-t-2(v1)\tr-t-2(v2)\tcurr-same?\tbkt(v1)\tbkt(v2)\tbkt-same?\tcoincident?"))

     ;; ─── Large-scale atom (mature scale ~2.0) ───
     ;;   bucket-width = 2.0 × 0.031 = 0.063
     ;;   round-to-2 width = 0.01 (MUCH finer than bucket)
     ;;   Expect: round-to-2 OVER-SPLITS — many cache keys for
     ;;   substrate-equivalent values. Bucketing consolidates them.
     ((_ :()) (:wat::io::IOWriter/println stdout
                "# Large-scale atom (s=2.0): round-to-2 OVER-SPLITS"))
     ((_ :()) (:explore::print-row stdout 1.00 1.02 2.0 nf))
     ((_ :()) (:explore::print-row stdout 1.00 1.05 2.0 nf))
     ((_ :()) (:explore::print-row stdout 1.00 1.10 2.0 nf))
     ((_ :()) (:explore::print-row stdout 1.00 1.20 2.0 nf))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ─── Medium-scale atom (mature scale ~0.5) ───
     ;;   bucket-width = 0.5 × 0.031 = 0.016
     ;;   round-to-2 width = 0.01 (slightly finer)
     ;;   Expect: alignment is mostly already there; small gap.
     ((_ :()) (:wat::io::IOWriter/println stdout
                "# Medium-scale atom (s=0.5): round-to-2 roughly matches"))
     ((_ :()) (:explore::print-row stdout 0.50 0.51 0.5 nf))
     ((_ :()) (:explore::print-row stdout 0.50 0.52 0.5 nf))
     ((_ :()) (:explore::print-row stdout 0.50 0.53 0.5 nf))
     ((_ :()) (:explore::print-row stdout 0.50 0.55 0.5 nf))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ─── Small-scale atom (mature scale ~0.05) ───
     ;;   bucket-width = 0.05 × 0.031 = 0.0016
     ;;   round-to-2 width = 0.01 (COARSER — round-to-2 under-splits!)
     ;;   Expect: round-to-2 UNDER-SPLITS — values that substrate
     ;;   CAN distinguish get collapsed. Bucketing preserves
     ;;   discrimination.
     ((_ :()) (:wat::io::IOWriter/println stdout
                "# Small-scale atom (s=0.05): round-to-2 UNDER-SPLITS"))
     ((_ :()) (:explore::print-row stdout 0.020 0.021 0.05 nf))
     ((_ :()) (:explore::print-row stdout 0.020 0.023 0.05 nf))
     ((_ :()) (:explore::print-row stdout 0.020 0.025 0.05 nf))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ─── Startup saturation — separate problem (not arc 012) ───
     ;;   Fresh tracker: scale = 0.001 (floored).
     ;;   bucket-width = 0.001 × 0.031 = 0.000031 — essentially no bucketing.
     ;;   Thermometer saturates for any non-trivial value.
     ((_ :()) (:wat::io::IOWriter/println stdout
                "# Startup-saturation regime (s=0.001): separate problem"))
     ((_ :()) (:explore::print-row stdout 0.020 0.023 0.001 nf)))

    ;; Final separator
    (:wat::io::IOWriter/println stdout "")))
