;; wat/vocab/broker/portfolio.wat — Phase 2.19 (lab arc 022).
;;
;; Port of archived/pre-wat-native/src/vocab/broker/portfolio.rs (45L).
;; First broker sub-tree vocab. Five per-snapshot scalars sampled
;; into a window, each rendered via the shared `indicator-rhythm`
;; primitive (arc 003 / Phase 3.4):
;;
;;   avg-paper-age          (avg-age,        0.0,  500.0, 100.0)
;;   avg-time-pressure      (avg-tp,         0.0,    1.0,   0.2)
;;   avg-unrealized-residue (avg-unrealized, -0.1,   0.1,   0.05)
;;   grace-rate             (grace-rate,     0.0,    1.0,   0.2)
;;   active-positions       (active-count,   0.0,  500.0, 100.0)
;;
;; Returns Result<Vec<HolonAST>, CapacityExceeded> per arc 032's
;; BundleResult convention — five sequential indicator-rhythm calls
;; need five `try`-unwraps; the surrounding function inherits the
;; Result signature. Err is unreachable at substrate-safe dims
;; (indicator-rhythm trims internally) but the type system enforces
;; honest handling.

(:wat::load-file! "../../types/portfolio.wat")
(:wat::load-file! "../../encoding/rhythm.wat")

(:wat::core::define
  (:trading::vocab::broker::portfolio::portfolio-rhythm-asts
    (snapshots :trading::types::PortfolioSnapshots)
    -> :Result<Vec<wat::holon::HolonAST>,wat::holon::CapacityExceeded>)
  (:wat::core::let*
    ;; Per-field Vec<f64> projections from the snapshot window.
    (((avg-age-vals :Vec<f64>)
      (:wat::core::map snapshots
        (:wat::core::lambda ((s :trading::types::PortfolioSnapshot) -> :f64)
          (:trading::types::PortfolioSnapshot/avg-age s))))
     ((avg-tp-vals :Vec<f64>)
      (:wat::core::map snapshots
        (:wat::core::lambda ((s :trading::types::PortfolioSnapshot) -> :f64)
          (:trading::types::PortfolioSnapshot/avg-tp s))))
     ((avg-unrealized-vals :Vec<f64>)
      (:wat::core::map snapshots
        (:wat::core::lambda ((s :trading::types::PortfolioSnapshot) -> :f64)
          (:trading::types::PortfolioSnapshot/avg-unrealized s))))
     ((grace-rate-vals :Vec<f64>)
      (:wat::core::map snapshots
        (:wat::core::lambda ((s :trading::types::PortfolioSnapshot) -> :f64)
          (:trading::types::PortfolioSnapshot/grace-rate s))))
     ((active-count-vals :Vec<f64>)
      (:wat::core::map snapshots
        (:wat::core::lambda ((s :trading::types::PortfolioSnapshot) -> :f64)
          (:trading::types::PortfolioSnapshot/active-count s))))

     ;; Five rhythm calls in archive order. `try` unwraps each
     ;; BundleResult; on Err the enclosing Result short-circuits.
     ((h0 :wat::holon::HolonAST)
      (:wat::core::try
        (:trading::encoding::rhythm::indicator-rhythm
          "avg-paper-age" avg-age-vals 0.0 500.0 100.0)))
     ((h1 :wat::holon::HolonAST)
      (:wat::core::try
        (:trading::encoding::rhythm::indicator-rhythm
          "avg-time-pressure" avg-tp-vals 0.0 1.0 0.2)))
     ((h2 :wat::holon::HolonAST)
      (:wat::core::try
        (:trading::encoding::rhythm::indicator-rhythm
          "avg-unrealized-residue" avg-unrealized-vals -0.1 0.1 0.05)))
     ((h3 :wat::holon::HolonAST)
      (:wat::core::try
        (:trading::encoding::rhythm::indicator-rhythm
          "grace-rate" grace-rate-vals 0.0 1.0 0.2)))
     ((h4 :wat::holon::HolonAST)
      (:wat::core::try
        (:trading::encoding::rhythm::indicator-rhythm
          "active-positions" active-count-vals 0.0 500.0 100.0))))
    (Ok
      (:wat::core::vec :wat::holon::HolonAST h0 h1 h2 h3 h4))))
