;; explore-log.wat — arc 005 fog-breaker (2026-04-23).
;;
;; Observe :wat::holon::Log behavior at three bound settings, with
;; reference value 1.0 (ROC "no change"). For each test value,
;; compute cosine similarity against the reference at each bound
;; setting.  See the saturation — values outside [min, max] all
;; encode identically.
;;
;; Bound settings:
;;   wide   — (0.00001, 100000)     matches the pre-058-017 archive's
;;                                   "10 orders of magnitude" span
;;   medium — (0.1, 10)              ±1 order of magnitude around 1
;;   tight  — (0.5, 2)               ratio-near-1.0, focused
;;
;; How to run (from the lab or wat-rs dir):
;;   cargo run --manifest-path=../../../../../wat-rs/Cargo.toml --bin wat -- \
;;     docs/arc/2026/04/005-market-oscillators-vocab/explore-log.wat


;; ─── helpers ──────────────────────────────────────────────────────

(:wat::core::define
  (:explore::log-enc
    (value :f64)
    (mn :f64)
    (mx :f64)
    -> :wat::holon::HolonAST)
  (:wat::holon::Log value mn mx))

;; Print one row: value  cos-wide  cos-med  cos-tight
(:wat::core::define
  (:explore::print-row
    (stdout :wat::io::IOWriter)
    (v :f64)
    (ref-wide :wat::holon::HolonAST)
    (ref-med :wat::holon::HolonAST)
    (ref-tight :wat::holon::HolonAST)
    -> :())
  (:wat::core::let*
    (((h-wide  :wat::holon::HolonAST)
      (:explore::log-enc v 0.00001 100000.0))
     ((h-med   :wat::holon::HolonAST)
      (:explore::log-enc v 0.1 10.0))
     ((h-tight :wat::holon::HolonAST)
      (:explore::log-enc v 0.5 2.0))
     ((cw :f64) (:wat::holon::cosine ref-wide  h-wide))
     ((cm :f64) (:wat::holon::cosine ref-med   h-med))
     ((ct :f64) (:wat::holon::cosine ref-tight h-tight))
     ((line :String)
      (:wat::core::string::join "\t"
        (:wat::core::vec :String
          (:wat::core::f64::to-string v)
          (:wat::core::f64::to-string cw)
          (:wat::core::f64::to-string cm)
          (:wat::core::f64::to-string ct)))))
    (:wat::io::IOWriter/println stdout line)))

;; ─── main — print header, noise floor, then the table ────────────

(:wat::core::define
  (:user::main
    (stdin  :wat::io::IOReader)
    (stdout :wat::io::IOWriter)
    (stderr :wat::io::IOWriter)
    -> :())
  (:wat::core::let*
    (((ref-wide  :wat::holon::HolonAST)
      (:explore::log-enc 1.0 0.00001 100000.0))
     ((ref-med   :wat::holon::HolonAST)
      (:explore::log-enc 1.0 0.1 10.0))
     ((ref-tight :wat::holon::HolonAST)
      (:explore::log-enc 1.0 0.5 2.0))
     ((nf :f64) (:wat::config::noise-floor))

     ((_0 :())
      (:wat::io::IOWriter/println stdout
        (:wat::core::string::join ""
          (:wat::core::vec :String
            "d=1024 noise-floor="
            (:wat::core::f64::to-string nf)
            "  (coincident? fires when cosine > "
            (:wat::core::f64::to-string (:wat::core::f64::- 1.0 nf))
            ")"))))
     ((_1 :())
      (:wat::io::IOWriter/println stdout ""))
     ((_2 :())
      (:wat::io::IOWriter/println stdout
        "value\tcos-wide(1e-5,1e5)\tcos-med(0.1,10)\tcos-tight(0.5,2)"))

     ;; ROC-space values — 1.0 is "no change"
     ((_3  :()) (:explore::print-row stdout 0.5  ref-wide ref-med ref-tight))
     ((_4  :()) (:explore::print-row stdout 0.7  ref-wide ref-med ref-tight))
     ((_5  :()) (:explore::print-row stdout 0.9  ref-wide ref-med ref-tight))
     ((_6  :()) (:explore::print-row stdout 0.95 ref-wide ref-med ref-tight))
     ((_7  :()) (:explore::print-row stdout 0.99 ref-wide ref-med ref-tight))
     ((_8  :()) (:explore::print-row stdout 1.0  ref-wide ref-med ref-tight))
     ((_9  :()) (:explore::print-row stdout 1.01 ref-wide ref-med ref-tight))
     ((_10 :()) (:explore::print-row stdout 1.05 ref-wide ref-med ref-tight))
     ((_11 :()) (:explore::print-row stdout 1.1  ref-wide ref-med ref-tight))
     ((_12 :()) (:explore::print-row stdout 1.3  ref-wide ref-med ref-tight))
     ((_13 :()) (:explore::print-row stdout 2.0  ref-wide ref-med ref-tight)))
    ()))
