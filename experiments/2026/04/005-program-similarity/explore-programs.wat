;; experiments/2026/04/005-program-similarity/explore-programs.wat
;;
;; Proof program for BOOK Chapter 54 — Programs as Coordinates.
;;
;; The user's recognition: programs are ASTs; the substrate's encoder
;; walks them recursively producing one vector per program; concrete
;; values snap to fiber positions via Thermometer encoding; programs
;; with similar structure AND similar values have similar vectors.
;;
;; This means we can:
;;   1. Measure program similarity via cosine
;;   2. Cluster similar programs into label regions
;;   3. Look up a new program's label via Bind+cleanup
;;
;; Three tables:
;;   Table 1: Pairwise cosines among 5 small programs. RSI variants
;;            with values near 0.7 cluster together (high mutual
;;            cosine). RSI variants near 0.3 form a separate cluster.
;;            Programs at different values are distant.
;;   Table 2: Build a labeled-program database — Bundle of
;;            (program ⊙ label) pairs. Look up new programs by
;;            Bind+cosine. Argmax label for a near-program should
;;            recover the cluster's label.
;;   Table 3: Domain anomaly. A program from a different indicator
;;            (MACD instead of RSI) doesn't match either RSI label
;;            well; cosines collapse to noise.
;;
;; Force d=10k for clean numbers (default tier 0 at d=256 has
;; significant cross-talk; d=10k is the trading lab's typical tier).
;;
;; Run: wat experiments/2026/04/005-program-similarity/explore-programs.wat

;; ─── Force d=10k for everything ────────────────────────────────────
(:wat::config::set-dim-router!
  (:wat::core::lambda
    ((ast :wat::holon::HolonAST) -> :Option<i64>)
    (Some 10000)))

;; ─── helpers ───────────────────────────────────────────────────────

(:wat::core::define
  (:explore::print-row5
    (stdout :wat::io::IOWriter)
    (header :String)
    (c1 :f64) (c2 :f64) (c3 :f64) (c4 :f64) (c5 :f64)
    -> :())
  (:wat::io::IOWriter/println stdout
    (:wat::core::string::join "\t"
      (:wat::core::vec :String
        header
        (:wat::core::f64::to-string c1)
        (:wat::core::f64::to-string c2)
        (:wat::core::f64::to-string c3)
        (:wat::core::f64::to-string c4)
        (:wat::core::f64::to-string c5)))))

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

;; Construct a program: Bind(Atom indicator, Thermometer value)
(:wat::core::define
  (:explore::program-at
    (indicator :String)
    (value :f64) (lo :f64) (hi :f64)
    -> :wat::holon::HolonAST)
  (:wat::holon::Bind
    (:wat::holon::Atom indicator)
    (:wat::holon::Thermometer value lo hi)))

;; ─── main ──────────────────────────────────────────────────────────

(:wat::core::define (:user::main
                     (stdin  :wat::io::IOReader)
                     (stdout :wat::io::IOWriter)
                     (stderr :wat::io::IOWriter)
                     -> :())
  (:wat::core::let*
    (
     ;; ── 5 SAMPLE PROGRAMS ─────────────────────────────────────
     ;; Three "RSI overbought" variants: values near 0.7
     ((p-rsi-70 :wat::holon::HolonAST) (:explore::program-at "rsi" 0.70 0.0 1.0))
     ((p-rsi-72 :wat::holon::HolonAST) (:explore::program-at "rsi" 0.72 0.0 1.0))
     ((p-rsi-68 :wat::holon::HolonAST) (:explore::program-at "rsi" 0.68 0.0 1.0))
     ;; Two "RSI oversold" variants: values near 0.3
     ((p-rsi-30 :wat::holon::HolonAST) (:explore::program-at "rsi" 0.30 0.0 1.0))
     ((p-rsi-32 :wat::holon::HolonAST) (:explore::program-at "rsi" 0.32 0.0 1.0))

     ;; ── TABLE 1: Pairwise cosines ─────────────────────────────
     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 1: Pairwise cosine — 5 small programs ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Programs encoded recursively; structural+value similarity reflected in cosine."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "          rsi=0.70   rsi=0.72   rsi=0.68   rsi=0.30   rsi=0.32"))
     ((_ :()) (:explore::print-row5 stdout "rsi=0.70 "
                (:wat::holon::cosine p-rsi-70 p-rsi-70)
                (:wat::holon::cosine p-rsi-70 p-rsi-72)
                (:wat::holon::cosine p-rsi-70 p-rsi-68)
                (:wat::holon::cosine p-rsi-70 p-rsi-30)
                (:wat::holon::cosine p-rsi-70 p-rsi-32)))
     ((_ :()) (:explore::print-row5 stdout "rsi=0.72 "
                (:wat::holon::cosine p-rsi-72 p-rsi-70)
                (:wat::holon::cosine p-rsi-72 p-rsi-72)
                (:wat::holon::cosine p-rsi-72 p-rsi-68)
                (:wat::holon::cosine p-rsi-72 p-rsi-30)
                (:wat::holon::cosine p-rsi-72 p-rsi-32)))
     ((_ :()) (:explore::print-row5 stdout "rsi=0.68 "
                (:wat::holon::cosine p-rsi-68 p-rsi-70)
                (:wat::holon::cosine p-rsi-68 p-rsi-72)
                (:wat::holon::cosine p-rsi-68 p-rsi-68)
                (:wat::holon::cosine p-rsi-68 p-rsi-30)
                (:wat::holon::cosine p-rsi-68 p-rsi-32)))
     ((_ :()) (:explore::print-row5 stdout "rsi=0.30 "
                (:wat::holon::cosine p-rsi-30 p-rsi-70)
                (:wat::holon::cosine p-rsi-30 p-rsi-72)
                (:wat::holon::cosine p-rsi-30 p-rsi-68)
                (:wat::holon::cosine p-rsi-30 p-rsi-30)
                (:wat::holon::cosine p-rsi-30 p-rsi-32)))
     ((_ :()) (:explore::print-row5 stdout "rsi=0.32 "
                (:wat::holon::cosine p-rsi-32 p-rsi-70)
                (:wat::holon::cosine p-rsi-32 p-rsi-72)
                (:wat::holon::cosine p-rsi-32 p-rsi-68)
                (:wat::holon::cosine p-rsi-32 p-rsi-30)
                (:wat::holon::cosine p-rsi-32 p-rsi-32)))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Within-cluster (overbought 0.68-0.72): expected high cosine."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Within-cluster (oversold 0.30-0.32): expected high cosine."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Across-cluster (overbought vs oversold): expected anti-correlated."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── BUILD LABELED-PROGRAM DATABASE ────────────────────────
     ;; Each entry: Bind(program, label).
     ;; programs in the same region all bound to the same label.
     ((label-over  :wat::holon::HolonAST) (:wat::holon::Atom "overbought"))
     ((label-under :wat::holon::HolonAST) (:wat::holon::Atom "oversold"))

     ((db :wat::holon::HolonAST)
      (:explore::force (:wat::holon::Bundle
        (:wat::core::vec :wat::holon::HolonAST
          (:wat::holon::Bind p-rsi-70 label-over)
          (:wat::holon::Bind p-rsi-72 label-over)
          (:wat::holon::Bind p-rsi-68 label-over)
          (:wat::holon::Bind p-rsi-30 label-under)
          (:wat::holon::Bind p-rsi-32 label-under)))))

     ;; ── TEST PROGRAMS (slightly different from training) ──────
     ((p-test-A :wat::holon::HolonAST) (:explore::program-at "rsi" 0.71 0.0 1.0))
     ((p-test-B :wat::holon::HolonAST) (:explore::program-at "rsi" 0.31 0.0 1.0))
     ((p-test-C :wat::holon::HolonAST) (:explore::program-at "rsi" 0.50 0.0 1.0))

     ;; Lookups: Bind test program with db, cosine vs labels.
     ((lookup-A :wat::holon::HolonAST) (:wat::holon::Bind p-test-A db))
     ((lookup-B :wat::holon::HolonAST) (:wat::holon::Bind p-test-B db))
     ((lookup-C :wat::holon::HolonAST) (:wat::holon::Bind p-test-C db))

     ;; ── TABLE 2: Label lookups ────────────────────────────────
     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 2: Label region lookup ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Bind test-program with db. Cosine result vs each known label."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "Argmax label = the region this program belongs to."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "                            overbought    oversold      gap"))
     ((_ :()) (:explore::print-row3 stdout "test-A (rsi=0.71, near over)"
                (:wat::holon::cosine lookup-A label-over)
                (:wat::holon::cosine lookup-A label-under)
                (:wat::core::f64::- (:wat::holon::cosine lookup-A label-over)
                                     (:wat::holon::cosine lookup-A label-under))))
     ((_ :()) (:explore::print-row3 stdout "test-B (rsi=0.31, near under)"
                (:wat::holon::cosine lookup-B label-over)
                (:wat::holon::cosine lookup-B label-under)
                (:wat::core::f64::- (:wat::holon::cosine lookup-B label-over)
                                     (:wat::holon::cosine lookup-B label-under))))
     ((_ :()) (:explore::print-row3 stdout "test-C (rsi=0.50, between)  "
                (:wat::holon::cosine lookup-C label-over)
                (:wat::holon::cosine lookup-C label-under)
                (:wat::core::f64::- (:wat::holon::cosine lookup-C label-over)
                                     (:wat::holon::cosine lookup-C label-under))))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  test-A (0.71): closer to overbought cluster — argmax over."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  test-B (0.31): closer to oversold cluster — argmax under."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  test-C (0.50): between clusters — gap small, classification ambiguous."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))

     ;; ── TABLE 3: Domain anomaly ───────────────────────────────
     ;; A program from a totally different indicator (MACD).
     ;; The substrate doesn't recognize it as belonging to either RSI region.
     ((p-macd :wat::holon::HolonAST) (:explore::program-at "macd" 0.05 -1.0 1.0))
     ((lookup-macd :wat::holon::HolonAST) (:wat::holon::Bind p-macd db))

     ((_ :()) (:wat::io::IOWriter/println stdout
                "=== Table 3: Domain anomaly — MACD program against RSI database ==="))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Program from a different indicator domain. db only knows RSI."))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "                            overbought    oversold      gap"))
     ((_ :()) (:explore::print-row3 stdout "MACD program (anomaly)      "
                (:wat::holon::cosine lookup-macd label-over)
                (:wat::holon::cosine lookup-macd label-under)
                (:wat::core::f64::- (:wat::holon::cosine lookup-macd label-over)
                                     (:wat::holon::cosine lookup-macd label-under))))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Both label cosines should be near zero."))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "  Substrate flags: this program belongs to neither known region.")))

    (:wat::io::IOWriter/println stdout
      "  Programs are coordinates. Labels are regions. Cosine is the test.")))
