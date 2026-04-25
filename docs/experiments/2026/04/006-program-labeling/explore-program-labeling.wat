;; docs/experiments/2026/04/006-program-labeling/explore-program-labeling.wat
;;
;; Program-similarity labeling at production complexity.
;;
;; Two-axis lookup (BOOK Chapter 36's lattice):
;;
;;   1. Direction-axis — SimHash gives an i64 key per program.
;;      Cosine-similar programs share the same key; orthogonal
;;      programs land in different buckets. O(1) bucket lookup.
;;
;;   2. Value-axis — Thermometer encodes concrete numbers into
;;      vectors that move smoothly with the value. Cosine within
;;      a bucket ranks similarity.
;;
;; Each program is a rhythm-shaped AST: 8 indicator values, each
;; bound to a unique position atom (rsi-p0..rsi-p7), bundled.
;; The position-atom step is what archived/pre-wat-native got
;; right — it scrambles structured Thermometer values into
;; randomized facts so position genuinely matters. Pure
;; Sequential/Permute over raw Therms collapses (the Therm step
;; pattern is too structured to be scrambled by small cyclic
;; shifts).
;;
;; Three tables:
;;   Table 1: Pairwise cosine — 3 archived rhythm programs.
;;   Table 2: Cosine + SimHash side-by-side — 4 candidates × 3
;;            archives. Locality-sensitive hash agrees with cosine.
;;   Table 3: Bucket lookup — exact-replay candidate's simhash
;;            matches archived simhash; noisy candidate falls
;;            back to cosine ranking.
;;
;; d=10k forced. Each program has 8 children in its top-level
;; Bundle — well under √10000 = 100 capacity.
;;
;; Run: wat docs/experiments/2026/04/006-program-labeling/explore-program-labeling.wat

;; ─── Force d=10k for everything ────────────────────────────────────
(:wat::config::set-dim-router!
  (:wat::core::lambda
    ((ast :wat::holon::HolonAST) -> :Option<i64>)
    (Some 10000)))

;; ─── helpers ───────────────────────────────────────────────────────

(:wat::core::define
  (:explore::print-row3
    (stdout :wat::io::IOWriter)
    (header :String)
    (c1 :f64) (c2 :f64) (c3 :f64)
    -> :())
  (:wat::io::IOWriter/println stdout
    (:wat::core::string::join "\t"
      (:wat::core::vec :String
        header
        (:wat::core::f64::to-string c1)
        (:wat::core::f64::to-string c2)
        (:wat::core::f64::to-string c3)))))

(:wat::core::define
  (:explore::force
    (r :wat::holon::BundleResult)
    -> :wat::holon::HolonAST)
  (:wat::core::match r -> :wat::holon::HolonAST
    ((Ok h) h)
    ((Err _) (:wat::holon::Atom "_BUNDLE_ERROR_"))))

;; Position-atom rhythm: each value bound to a unique position atom.
;; The position-atom Bind randomizes the structured Therm pattern
;; into a pseudo-random fact. Bundle of 8 facts → the rhythm vector.
(:wat::core::define
  (:explore::rhythm
    (v0 :f64) (v1 :f64) (v2 :f64) (v3 :f64)
    (v4 :f64) (v5 :f64) (v6 :f64) (v7 :f64)
    -> :wat::holon::HolonAST)
  (:explore::force
    (:wat::holon::Bundle
      (:wat::core::vec :wat::holon::HolonAST
        (:wat::holon::Bind (:wat::holon::Atom "rsi-p0") (:wat::holon::Thermometer v0 0.0 1.0))
        (:wat::holon::Bind (:wat::holon::Atom "rsi-p1") (:wat::holon::Thermometer v1 0.0 1.0))
        (:wat::holon::Bind (:wat::holon::Atom "rsi-p2") (:wat::holon::Thermometer v2 0.0 1.0))
        (:wat::holon::Bind (:wat::holon::Atom "rsi-p3") (:wat::holon::Thermometer v3 0.0 1.0))
        (:wat::holon::Bind (:wat::holon::Atom "rsi-p4") (:wat::holon::Thermometer v4 0.0 1.0))
        (:wat::holon::Bind (:wat::holon::Atom "rsi-p5") (:wat::holon::Thermometer v5 0.0 1.0))
        (:wat::holon::Bind (:wat::holon::Atom "rsi-p6") (:wat::holon::Thermometer v6 0.0 1.0))
        (:wat::holon::Bind (:wat::holon::Atom "rsi-p7") (:wat::holon::Thermometer v7 0.0 1.0))))))

;; ─── main ──────────────────────────────────────────────────────────

(:wat::core::define (:user::main
                     (stdin  :wat::io::IOReader)
                     (stdout :wat::io::IOWriter)
                     (stderr :wat::io::IOWriter)
                     -> :())
  (:wat::core::let*
    (
     ;; ── 3 ARCHIVED PROGRAMS ───────────────────────────────────
     ((p-up :wat::holon::HolonAST)
      (:explore::rhythm 0.30 0.36 0.42 0.48 0.54 0.60 0.66 0.72))
     ((p-down :wat::holon::HolonAST)
      (:explore::rhythm 0.72 0.66 0.60 0.54 0.48 0.42 0.36 0.30))
     ((p-mean :wat::holon::HolonAST)
      (:explore::rhythm 0.50 0.62 0.50 0.38 0.50 0.62 0.50 0.38))

     ;; ── 4 CANDIDATES ──────────────────────────────────────────
     ;; A: exact replay of uptrend
     ((q-A :wat::holon::HolonAST)
      (:explore::rhythm 0.30 0.36 0.42 0.48 0.54 0.60 0.66 0.72))
     ;; B: noisy uptrend
     ((q-B :wat::holon::HolonAST)
      (:explore::rhythm 0.31 0.35 0.43 0.47 0.55 0.59 0.67 0.71))
     ;; C: shifted-up uptrend (same shape, +0.10 offset)
     ((q-C :wat::holon::HolonAST)
      (:explore::rhythm 0.40 0.46 0.52 0.58 0.64 0.70 0.76 0.82))
     ;; D: random walk (no clear trend)
     ((q-D :wat::holon::HolonAST)
      (:explore::rhythm 0.50 0.30 0.70 0.40 0.60 0.45 0.55 0.50))

     ;; SimHashes — direction-axis i64 keys
     ((h-up :i64)   (:wat::holon::simhash p-up))
     ((h-down :i64) (:wat::holon::simhash p-down))
     ((h-mean :i64) (:wat::holon::simhash p-mean))
     ((h-A :i64)    (:wat::holon::simhash q-A))
     ((h-B :i64)    (:wat::holon::simhash q-B))
     ((h-C :i64)    (:wat::holon::simhash q-C))
     ((h-D :i64)    (:wat::holon::simhash q-D))

     ;; ── TABLE 1: Pairwise cosine — 3 archived programs ────────
     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 1: Pairwise cosine — 3 archived rhythm programs ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Each program: 8 (position-atom, value-Therm) facts bundled."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "             uptrend     downtrend   mean-revert"))
     ((_ :()) (:explore::print-row3 stdout "uptrend     "
                (:wat::holon::cosine p-up p-up)
                (:wat::holon::cosine p-up p-down)
                (:wat::holon::cosine p-up p-mean)))
     ((_ :()) (:explore::print-row3 stdout "downtrend   "
                (:wat::holon::cosine p-down p-up)
                (:wat::holon::cosine p-down p-down)
                (:wat::holon::cosine p-down p-mean)))
     ((_ :()) (:explore::print-row3 stdout "mean-revert "
                (:wat::holon::cosine p-mean p-up)
                (:wat::holon::cosine p-mean p-down)
                (:wat::holon::cosine p-mean p-mean)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Off-diagonal < 1: distinct shapes → distinct vectors. Self = 1.0."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── TABLE 2: Cosine + SimHash for archives ────────────────
     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 2: Direction-axis SimHash i64 keys ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Cosine-similar programs share keys (or land in nearby buckets)."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
       (:wat::core::string::join "\t"
         (:wat::core::vec :String "p-up   simhash:" (:wat::core::i64::to-string h-up)))))
     ((_ :()) (:wat::io::IOWriter/println stdout
       (:wat::core::string::join "\t"
         (:wat::core::vec :String "p-down simhash:" (:wat::core::i64::to-string h-down)))))
     ((_ :()) (:wat::io::IOWriter/println stdout
       (:wat::core::string::join "\t"
         (:wat::core::vec :String "p-mean simhash:" (:wat::core::i64::to-string h-mean)))))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
       (:wat::core::string::join "\t"
         (:wat::core::vec :String "q-A    simhash:" (:wat::core::i64::to-string h-A)))))
     ((_ :()) (:wat::io::IOWriter/println stdout
       (:wat::core::string::join "\t"
         (:wat::core::vec :String "q-B    simhash:" (:wat::core::i64::to-string h-B)))))
     ((_ :()) (:wat::io::IOWriter/println stdout
       (:wat::core::string::join "\t"
         (:wat::core::vec :String "q-C    simhash:" (:wat::core::i64::to-string h-C)))))
     ((_ :()) (:wat::io::IOWriter/println stdout
       (:wat::core::string::join "\t"
         (:wat::core::vec :String "q-D    simhash:" (:wat::core::i64::to-string h-D)))))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Three archive keys (distinct) + four candidate keys."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  q-A (exact replay) should equal h-up. q-B/q-C/q-D may shift."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── TABLE 3: Cosine vs archives, with bucket-hit flags ────
     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 3: Cosine ranking + SimHash bucket hits ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Each row: cosine to each archive program. Last column = exact"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "SimHash bucket match (1 = key matches, 0 = no exact match)."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "                     uptrend     downtrend   mean-revert    bucket-hit-on"))

     ((_ :()) (:wat::io::IOWriter/println stdout
       (:wat::core::string::join "\t"
         (:wat::core::vec :String
           "A: exact uptrend   "
           (:wat::core::f64::to-string (:wat::holon::cosine q-A p-up))
           (:wat::core::f64::to-string (:wat::holon::cosine q-A p-down))
           (:wat::core::f64::to-string (:wat::holon::cosine q-A p-mean))
           (:wat::core::if (:wat::core::i64::= h-A h-up) -> :String "uptrend"
             (:wat::core::if (:wat::core::i64::= h-A h-down) -> :String "downtrend"
               (:wat::core::if (:wat::core::i64::= h-A h-mean) -> :String "mean-revert"
                 "(no bucket)")))))))
     ((_ :()) (:wat::io::IOWriter/println stdout
       (:wat::core::string::join "\t"
         (:wat::core::vec :String
           "B: noisy uptrend   "
           (:wat::core::f64::to-string (:wat::holon::cosine q-B p-up))
           (:wat::core::f64::to-string (:wat::holon::cosine q-B p-down))
           (:wat::core::f64::to-string (:wat::holon::cosine q-B p-mean))
           (:wat::core::if (:wat::core::i64::= h-B h-up) -> :String "uptrend"
             (:wat::core::if (:wat::core::i64::= h-B h-down) -> :String "downtrend"
               (:wat::core::if (:wat::core::i64::= h-B h-mean) -> :String "mean-revert"
                 "(no bucket)")))))))
     ((_ :()) (:wat::io::IOWriter/println stdout
       (:wat::core::string::join "\t"
         (:wat::core::vec :String
           "C: shifted uptrend "
           (:wat::core::f64::to-string (:wat::holon::cosine q-C p-up))
           (:wat::core::f64::to-string (:wat::holon::cosine q-C p-down))
           (:wat::core::f64::to-string (:wat::holon::cosine q-C p-mean))
           (:wat::core::if (:wat::core::i64::= h-C h-up) -> :String "uptrend"
             (:wat::core::if (:wat::core::i64::= h-C h-down) -> :String "downtrend"
               (:wat::core::if (:wat::core::i64::= h-C h-mean) -> :String "mean-revert"
                 "(no bucket)")))))))
     ((_ :()) (:wat::io::IOWriter/println stdout
       (:wat::core::string::join "\t"
         (:wat::core::vec :String
           "D: random walk     "
           (:wat::core::f64::to-string (:wat::holon::cosine q-D p-up))
           (:wat::core::f64::to-string (:wat::holon::cosine q-D p-down))
           (:wat::core::f64::to-string (:wat::holon::cosine q-D p-mean))
           (:wat::core::if (:wat::core::i64::= h-D h-up) -> :String "uptrend"
             (:wat::core::if (:wat::core::i64::= h-D h-down) -> :String "downtrend"
               (:wat::core::if (:wat::core::i64::= h-D h-mean) -> :String "mean-revert"
                 "(no bucket)")))))))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  A: exact bucket hit on uptrend (simhash matches → O(1) lookup)."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  B/C: cosine still ranks uptrend highest; bucket may differ —"))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "       fallback to cosine within neighborhood of buckets."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  D: noise across cosines; no exact bucket hit.")))

    (:wat::io::IOWriter/println stdout
      "  Two axes: SimHash for O(1) bucket lookup, cosine for in-bucket ranking.")))
