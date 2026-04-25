;; wat-tests/vocab/broker/portfolio.wat — Lab arc 022.
;;
;; Four tests for :trading::vocab::broker::portfolio. First broker
;; sub-tree vocab — five rhythm calls over a snapshot window.
;; Returns Result<Vec<HolonAST>, CapacityExceeded> per arc 032's
;; BundleResult convention.


(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/broker/portfolio.wat")
   (:wat::core::define
     (:test::fresh-snapshot
       (avg-age :f64) (avg-tp :f64) (avg-unrealized :f64)
       (grace-rate :f64) (active-count :f64)
       -> :trading::types::PortfolioSnapshot)
     (:trading::types::PortfolioSnapshot/new
       avg-age avg-tp avg-unrealized grace-rate active-count))))

;; ─── 1. count — Ok arm holds Vec of length 5 ───────────────────

(:deftest :trading::test::vocab::broker::portfolio::test-rhythm-count
  (:wat::core::let*
    (((snapshots :trading::types::PortfolioSnapshots)
      (:wat::core::vec :trading::types::PortfolioSnapshot
        (:test::fresh-snapshot 10.0 0.2  0.01  0.5  3.0)
        (:test::fresh-snapshot 12.0 0.25 0.015 0.55 4.0)
        (:test::fresh-snapshot 15.0 0.3  0.02  0.6  5.0)
        (:test::fresh-snapshot 18.0 0.35 0.025 0.65 6.0)
        (:test::fresh-snapshot 20.0 0.4  0.03  0.7  7.0)))
     ((r :Result<Vec<wat::holon::HolonAST>,wat::holon::CapacityExceeded>)
      (:trading::vocab::broker::portfolio::portfolio-rhythm-asts snapshots))
     ((rhythms :Vec<wat::holon::HolonAST>)
      (:wat::core::match r -> :Vec<wat::holon::HolonAST>
        ((Ok v)  v)
        ((Err _) (:wat::core::vec :wat::holon::HolonAST)))))
    (:wat::test::assert-eq
      (:wat::core::length rhythms)
      5)))

;; ─── 2. deterministic — same snapshots → coincident holon[0] ───

(:deftest :trading::test::vocab::broker::portfolio::test-rhythm-deterministic
  (:wat::core::let*
    (((snapshots :trading::types::PortfolioSnapshots)
      (:wat::core::vec :trading::types::PortfolioSnapshot
        (:test::fresh-snapshot 10.0 0.2  0.01  0.5  3.0)
        (:test::fresh-snapshot 12.0 0.25 0.015 0.55 4.0)
        (:test::fresh-snapshot 15.0 0.3  0.02  0.6  5.0)
        (:test::fresh-snapshot 18.0 0.35 0.025 0.65 6.0)
        (:test::fresh-snapshot 20.0 0.4  0.03  0.7  7.0)))
     ((r1 :Result<Vec<wat::holon::HolonAST>,wat::holon::CapacityExceeded>)
      (:trading::vocab::broker::portfolio::portfolio-rhythm-asts snapshots))
     ((r2 :Result<Vec<wat::holon::HolonAST>,wat::holon::CapacityExceeded>)
      (:trading::vocab::broker::portfolio::portfolio-rhythm-asts snapshots))
     ((rhythms-1 :Vec<wat::holon::HolonAST>)
      (:wat::core::match r1 -> :Vec<wat::holon::HolonAST>
        ((Ok v)  v)
        ((Err _) (:wat::core::vec :wat::holon::HolonAST))))
     ((rhythms-2 :Vec<wat::holon::HolonAST>)
      (:wat::core::match r2 -> :Vec<wat::holon::HolonAST>
        ((Ok v)  v)
        ((Err _) (:wat::core::vec :wat::holon::HolonAST))))
     ((h1 :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get rhythms-1 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None    (:wat::holon::Atom "unreachable"))))
     ((h2 :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get rhythms-2 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None    (:wat::holon::Atom "unreachable")))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? h1 h2)
      true)))

;; ─── 3. different windows differ — non-coincident holon[0] ─────

(:deftest :trading::test::vocab::broker::portfolio::test-rhythm-different-windows-differ
  (:wat::core::let*
    (;; Distinct avg-age trajectories — first ascending, second descending.
     ((snapshots-a :trading::types::PortfolioSnapshots)
      (:wat::core::vec :trading::types::PortfolioSnapshot
        (:test::fresh-snapshot 10.0 0.2 0.01 0.5 3.0)
        (:test::fresh-snapshot 20.0 0.2 0.01 0.5 3.0)
        (:test::fresh-snapshot 30.0 0.2 0.01 0.5 3.0)
        (:test::fresh-snapshot 40.0 0.2 0.01 0.5 3.0)
        (:test::fresh-snapshot 50.0 0.2 0.01 0.5 3.0)))
     ((snapshots-b :trading::types::PortfolioSnapshots)
      (:wat::core::vec :trading::types::PortfolioSnapshot
        (:test::fresh-snapshot 50.0 0.2 0.01 0.5 3.0)
        (:test::fresh-snapshot 40.0 0.2 0.01 0.5 3.0)
        (:test::fresh-snapshot 30.0 0.2 0.01 0.5 3.0)
        (:test::fresh-snapshot 20.0 0.2 0.01 0.5 3.0)
        (:test::fresh-snapshot 10.0 0.2 0.01 0.5 3.0)))
     ((r-a :Result<Vec<wat::holon::HolonAST>,wat::holon::CapacityExceeded>)
      (:trading::vocab::broker::portfolio::portfolio-rhythm-asts snapshots-a))
     ((r-b :Result<Vec<wat::holon::HolonAST>,wat::holon::CapacityExceeded>)
      (:trading::vocab::broker::portfolio::portfolio-rhythm-asts snapshots-b))
     ((rhythms-a :Vec<wat::holon::HolonAST>)
      (:wat::core::match r-a -> :Vec<wat::holon::HolonAST>
        ((Ok v)  v)
        ((Err _) (:wat::core::vec :wat::holon::HolonAST))))
     ((rhythms-b :Vec<wat::holon::HolonAST>)
      (:wat::core::match r-b -> :Vec<wat::holon::HolonAST>
        ((Ok v)  v)
        ((Err _) (:wat::core::vec :wat::holon::HolonAST))))
     ((h-a :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get rhythms-a 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None    (:wat::holon::Atom "unreachable"))))
     ((h-b :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get rhythms-b 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None    (:wat::holon::Atom "unreachable")))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? h-a h-b)
      false)))

;; ─── 4. short window — < 4 snapshots → 5 empty-bundle rhythms ──

(:deftest :trading::test::vocab::broker::portfolio::test-rhythm-short-window
  (:wat::core::let*
    (;; 2 snapshots; indicator-rhythm's < 4 fallback emits the
     ;; empty-bundle Bind for each. Function still returns Ok with
     ;; 5 holons (one per atom name).
     ((snapshots :trading::types::PortfolioSnapshots)
      (:wat::core::vec :trading::types::PortfolioSnapshot
        (:test::fresh-snapshot 10.0 0.2 0.01 0.5 3.0)
        (:test::fresh-snapshot 12.0 0.25 0.015 0.55 4.0)))
     ((r :Result<Vec<wat::holon::HolonAST>,wat::holon::CapacityExceeded>)
      (:trading::vocab::broker::portfolio::portfolio-rhythm-asts snapshots))
     ((rhythms :Vec<wat::holon::HolonAST>)
      (:wat::core::match r -> :Vec<wat::holon::HolonAST>
        ((Ok v)  v)
        ((Err _) (:wat::core::vec :wat::holon::HolonAST)))))
    (:wat::test::assert-eq
      (:wat::core::length rhythms)
      5)))
