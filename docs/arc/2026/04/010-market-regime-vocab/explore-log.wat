;; explore-log.wat — arc 010 fog-breaker (2026-04-23).
;;
;; Observe :wat::holon::Log behavior for variance-ratio across three
;; ReciprocalLog family settings. The reference value is 1.0 (random-
;; walk baseline — variance over single-step equals variance over
;; multi-step scaled appropriately). Values below 1 indicate mean-
;; reversion; values above 1 indicate trending.
;;
;; Bound settings (arc 034's ReciprocalLog family (1/N, N)):
;;   N=2   — (0.5, 2.0)      ±doubling;    arc 005's choice for ROC
;;   N=3   — (1/3, 3.0)      ±tripling
;;   N=10  — (0.1, 10.0)     ±10× ;       full typical financial range
;;
;; Values tested: 0.1 through 20.0, sampled around 1.0.
;;
;; Expected reading:
;;   - N=2 saturates for any value outside ±doubling (most rows pinned)
;;   - N=10 distinguishes across the full financial range but coarse
;;     near 1.0
;;   - N=3 is the middle option — distinguishes moderate excursions
;;     (±tripling) without saturating wide regimes completely
;;
;; How to run (from the lab dir):
;;   cargo run --manifest-path=../../../../../wat-rs/Cargo.toml --bin wat -- \
;;     docs/arc/2026/04/010-market-regime-vocab/explore-log.wat

(:wat::config::set-capacity-mode! :error)
(:wat::config::set-dims! 1024)

;; ─── helpers ──────────────────────────────────────────────────────

(:wat::core::define
  (:explore::log-enc
    (value :f64)
    (mn :f64)
    (mx :f64)
    -> :wat::holon::HolonAST)
  (:wat::holon::Log value mn mx))

;; Print one row: value  cos-n2  cos-n3  cos-n10
(:wat::core::define
  (:explore::print-row
    (stdout :wat::io::IOWriter)
    (v :f64)
    (ref-n2 :wat::holon::HolonAST)
    (ref-n3 :wat::holon::HolonAST)
    (ref-n10 :wat::holon::HolonAST)
    -> :())
  (:wat::core::let*
    (((h-n2  :wat::holon::HolonAST)
      (:explore::log-enc v 0.5 2.0))
     ((h-n3  :wat::holon::HolonAST)
      (:explore::log-enc v (:wat::core::f64::/ 1.0 3.0) 3.0))
     ((h-n10 :wat::holon::HolonAST)
      (:explore::log-enc v 0.1 10.0))
     ((c-n2  :f64) (:wat::holon::cosine ref-n2  h-n2))
     ((c-n3  :f64) (:wat::holon::cosine ref-n3  h-n3))
     ((c-n10 :f64) (:wat::holon::cosine ref-n10 h-n10))
     ((line :String)
      (:wat::core::string::join "\t"
        (:wat::core::vec :String
          (:wat::core::f64::to-string v)
          (:wat::core::f64::to-string c-n2)
          (:wat::core::f64::to-string c-n3)
          (:wat::core::f64::to-string c-n10)))))
    (:wat::io::IOWriter/println stdout line)))

;; ─── main — print header, noise floor, then the table ────────────

(:wat::core::define (:user::main
                     (stdin  :wat::io::IOReader)
                     (stdout :wat::io::IOWriter)
                     (stderr :wat::io::IOWriter)
                     -> :())
  (:wat::core::let*
    (((ref-n2  :wat::holon::HolonAST)
      (:explore::log-enc 1.0 0.5 2.0))
     ((ref-n3  :wat::holon::HolonAST)
      (:explore::log-enc 1.0 (:wat::core::f64::/ 1.0 3.0) 3.0))
     ((ref-n10 :wat::holon::HolonAST)
      (:explore::log-enc 1.0 0.1 10.0))
     ((nf :f64) (:wat::config::noise-floor))
     ((_ :()) (:wat::io::IOWriter/println stdout
                (:wat::core::string::join ""
                  (:wat::core::vec :String
                    "d=1024  noise-floor="
                    (:wat::core::f64::to-string nf)
                    "  (coincident? fires when cosine > "
                    (:wat::core::f64::to-string
                      (:wat::core::f64::- 1.0 nf))
                    ")"))))
     ((_ :()) (:wat::io::IOWriter/println stdout ""))
     ((_ :()) (:wat::io::IOWriter/println stdout
                "value\tN=2(0.5,2)\tN=3(1/3,3)\tN=10(0.1,10)"))

     ;; Test values spanning 0.1 to 20.0
     ((_ :()) (:explore::print-row stdout 0.1  ref-n2 ref-n3 ref-n10))
     ((_ :()) (:explore::print-row stdout 0.2  ref-n2 ref-n3 ref-n10))
     ((_ :()) (:explore::print-row stdout 0.3  ref-n2 ref-n3 ref-n10))
     ((_ :()) (:explore::print-row stdout 0.5  ref-n2 ref-n3 ref-n10))
     ((_ :()) (:explore::print-row stdout 0.7  ref-n2 ref-n3 ref-n10))
     ((_ :()) (:explore::print-row stdout 0.9  ref-n2 ref-n3 ref-n10))
     ((_ :()) (:explore::print-row stdout 0.95 ref-n2 ref-n3 ref-n10))
     ((_ :()) (:explore::print-row stdout 0.99 ref-n2 ref-n3 ref-n10))
     ((_ :()) (:explore::print-row stdout 1.0  ref-n2 ref-n3 ref-n10))
     ((_ :()) (:explore::print-row stdout 1.01 ref-n2 ref-n3 ref-n10))
     ((_ :()) (:explore::print-row stdout 1.05 ref-n2 ref-n3 ref-n10))
     ((_ :()) (:explore::print-row stdout 1.1  ref-n2 ref-n3 ref-n10))
     ((_ :()) (:explore::print-row stdout 1.3  ref-n2 ref-n3 ref-n10))
     ((_ :()) (:explore::print-row stdout 1.5  ref-n2 ref-n3 ref-n10))
     ((_ :()) (:explore::print-row stdout 2.0  ref-n2 ref-n3 ref-n10))
     ((_ :()) (:explore::print-row stdout 3.0  ref-n2 ref-n3 ref-n10))
     ((_ :()) (:explore::print-row stdout 5.0  ref-n2 ref-n3 ref-n10))
     ((_ :()) (:explore::print-row stdout 10.0 ref-n2 ref-n3 ref-n10)))
    (:explore::print-row stdout 20.0 ref-n2 ref-n3 ref-n10)))
