;; wat-tests/vocab/exit/trade-atoms.wat — Lab arc 023.
;;
;; Six tests for :trading::vocab::exit::trade-atoms. First lab
;; consumer of arc 049's newtype value semantics — uses
;; (:Price/new f64) to construct PaperEntry's three Price fields,
;; and `:Price/0` accessor inside the vocab function reads them
;; back. PaperEntry's three thought fields use simple Atom HolonASTs
;; — the experiment under arc 023's directory proved struct fields
;; of type `:wat::holon::HolonAST` round-trip cleanly.


(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/exit/trade-atoms.wat")
   ;; Test fixture builder. Default thought fields use plain Atoms;
   ;; bool fields default false; price-history holds [entry, extreme].
   ;; Caller supplies entry-price + extreme + signaled-flag + age +
   ;; entry-candle.
   (:wat::core::define
     (:test::fresh-paper
       (entry :f64)
       (extreme :f64)
       (signaled :bool)
       (age :i64)
       (entry-candle :i64)
       -> :trading::types::PaperEntry)
     (:trading::types::PaperEntry/new
       0
       (:wat::holon::Atom "composed")
       (:wat::holon::Atom "market")
       (:wat::holon::Atom "position")
       :trading::types::Direction::Up
       (:trading::types::Price/new entry)
       (:trading::types::Distances/new 0.05 0.10)
       extreme
       (:trading::types::Price/new entry)
       (:trading::types::Price/new
         (:wat::core::- entry (:wat::core::* entry 0.10)))
       signaled
       false
       age
       entry-candle
       (:wat::core::vec :f64 entry extreme)))
   (:wat::core::define
     (:test::empty-phases -> :trading::types::PhaseRecords)
     (:wat::core::vec :trading::types::PhaseRecord))))

;; ─── 1. count — 13 atoms emitted ───────────────────────────────

(:deftest :trading::test::vocab::exit::trade-atoms::test-atoms-count
  (:wat::core::let*
    (((paper :trading::types::PaperEntry)
      (:test::fresh-paper 100.0 110.0 false 5 0))
     ((atoms :Vec<wat::holon::HolonAST>)
      (:trading::vocab::exit::trade-atoms::compute-trade-atoms
        paper 108.0 (:test::empty-phases))))
    (:wat::test::assert-eq
      (:wat::core::length atoms)
      13)))

;; ─── 2. exit-excursion atom shape — fact[0] coincident ─────────

(:deftest :trading::test::vocab::exit::trade-atoms::test-excursion-shape
  (:wat::core::let*
    (((paper :trading::types::PaperEntry)
      (:test::fresh-paper 100.0 110.0 false 5 0))
     ((atoms :Vec<wat::holon::HolonAST>)
      (:trading::vocab::exit::trade-atoms::compute-trade-atoms
        paper 108.0 (:test::empty-phases)))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get atoms 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None    (:wat::holon::Atom "unreachable"))))
     ;; Excursion = |(110 - 100) / 100| = 0.10; floored max(0.10, 0.0001) = 0.10.
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "exit-excursion")
        (:wat::holon::Log 0.10 0.0001 0.5))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 3. deterministic — same input → coincident first atom ─────

(:deftest :trading::test::vocab::exit::trade-atoms::test-deterministic
  (:wat::core::let*
    (((p :trading::types::PaperEntry)
      (:test::fresh-paper 100.0 110.0 false 5 0))
     ((a1 :Vec<wat::holon::HolonAST>)
      (:trading::vocab::exit::trade-atoms::compute-trade-atoms
        p 108.0 (:test::empty-phases)))
     ((a2 :Vec<wat::holon::HolonAST>)
      (:trading::vocab::exit::trade-atoms::compute-trade-atoms
        p 108.0 (:test::empty-phases)))
     ((h1 :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get a1 0) -> :wat::holon::HolonAST
        ((Some h) h)
        (:None    (:wat::holon::Atom "unreachable"))))
     ((h2 :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get a2 0) -> :wat::holon::HolonAST
        ((Some h) h)
        (:None    (:wat::holon::Atom "unreachable")))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? h1 h2)
      true)))

;; ─── 4. select-trade-atoms Core → 5 atoms ─────────────────────

(:deftest :trading::test::vocab::exit::trade-atoms::test-select-core-count
  (:wat::core::let*
    (((p :trading::types::PaperEntry)
      (:test::fresh-paper 100.0 110.0 false 5 0))
     ((all :Vec<wat::holon::HolonAST>)
      (:trading::vocab::exit::trade-atoms::compute-trade-atoms
        p 108.0 (:test::empty-phases)))
     ((picked :Vec<wat::holon::HolonAST>)
      (:trading::vocab::exit::trade-atoms::select-trade-atoms
        :trading::types::RegimeLens::Core all)))
    (:wat::test::assert-eq
      (:wat::core::length picked)
      5)))

;; ─── 5. select-trade-atoms Full → 13 atoms ────────────────────

(:deftest :trading::test::vocab::exit::trade-atoms::test-select-full-count
  (:wat::core::let*
    (((p :trading::types::PaperEntry)
      (:test::fresh-paper 100.0 110.0 false 5 0))
     ((all :Vec<wat::holon::HolonAST>)
      (:trading::vocab::exit::trade-atoms::compute-trade-atoms
        p 108.0 (:test::empty-phases)))
     ((picked :Vec<wat::holon::HolonAST>)
      (:trading::vocab::exit::trade-atoms::select-trade-atoms
        :trading::types::RegimeLens::Full all)))
    (:wat::test::assert-eq
      (:wat::core::length picked)
      13)))

;; ─── 6. different excursions differ — non-coincident first atom

(:deftest :trading::test::vocab::exit::trade-atoms::test-different-excursions-differ
  (:wat::core::let*
    (;; A: extreme=110, excursion=0.10. B: extreme=200, excursion=1.0
     ;; (will saturate Log at upper bound 0.5). Different log inputs
     ;; → different Thermometer-projected vectors.
     ((p-a :trading::types::PaperEntry)
      (:test::fresh-paper 100.0 110.0 false 5 0))
     ((p-b :trading::types::PaperEntry)
      (:test::fresh-paper 100.0 200.0 false 5 0))
     ((atoms-a :Vec<wat::holon::HolonAST>)
      (:trading::vocab::exit::trade-atoms::compute-trade-atoms
        p-a 108.0 (:test::empty-phases)))
     ((atoms-b :Vec<wat::holon::HolonAST>)
      (:trading::vocab::exit::trade-atoms::compute-trade-atoms
        p-b 108.0 (:test::empty-phases)))
     ((h-a :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get atoms-a 0) -> :wat::holon::HolonAST
        ((Some h) h)
        (:None    (:wat::holon::Atom "unreachable"))))
     ((h-b :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get atoms-b 0) -> :wat::holon::HolonAST
        ((Some h) h)
        (:None    (:wat::holon::Atom "unreachable")))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? h-a h-b)
      false)))
