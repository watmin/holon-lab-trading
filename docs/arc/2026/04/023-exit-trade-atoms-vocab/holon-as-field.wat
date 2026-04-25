;; wat-tests/experiments/holon-as-field.wat
;;
;; Experiment: can `:wat::holon::HolonAST` be a struct field?
;;
;; Hypothesis: yes — the substrate doesn't distinguish HolonAST in
;; collections (already used via `:Vec<HolonAST>` / `:wat::holon::Holons`)
;; from HolonAST as a struct field. Both are values of the universal
;; load-bearing type.
;;
;; If yes: PaperEntry (arc 023) ships with HolonAST fields directly,
;; no wat-holon sibling crate needed for the lab's storage shape;
;; the Vector-field-on-struct pattern from the archive is a Rust-tier
;; concern that the wat-native form replaces.


(:wat::test::make-deftest :deftest
  ((:wat::core::struct :test::Container
     (label  :String)
     (holon  :wat::holon::HolonAST)
     (count  :i64))))

;; ─── 1. construct + read — HolonAST round-trips through field ───

(:deftest :test::experiments::holon-as-field::test-construct-and-read
  (:wat::core::let*
    (((source :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "alpha")
        (:wat::holon::Atom "beta")))
     ((c :test::Container)
      (:test::Container/new "first" source 7))
     ((retrieved :wat::holon::HolonAST)
      (:test::Container/holon c)))
    (:wat::test::assert-eq
      (:wat::holon::coincident? retrieved source)
      true)))

;; ─── 2. distinct ASTs in distinct containers stay distinct ──────

(:deftest :test::experiments::holon-as-field::test-distinct-asts-stay-distinct
  (:wat::core::let*
    (((a :wat::holon::HolonAST) (:wat::holon::Atom "alpha"))
     ((b :wat::holon::HolonAST) (:wat::holon::Atom "beta"))
     ((ca :test::Container) (:test::Container/new "a" a 1))
     ((cb :test::Container) (:test::Container/new "b" b 2))
     ((retrieved-a :wat::holon::HolonAST) (:test::Container/holon ca))
     ((retrieved-b :wat::holon::HolonAST) (:test::Container/holon cb)))
    (:wat::test::assert-eq
      (:wat::holon::coincident? retrieved-a retrieved-b)
      false)))

;; ─── 3. compound HolonAST (Bundle) stored and retrieved ─────────

(:deftest :test::experiments::holon-as-field::test-bundle-as-field
  (:wat::core::let*
    (((bundle-result :wat::holon::BundleResult)
      (:wat::holon::Bundle
        (:wat::core::vec :wat::holon::HolonAST
          (:wat::holon::Atom "x")
          (:wat::holon::Atom "y")
          (:wat::holon::Atom "z"))))
     ((bundle :wat::holon::HolonAST)
      (:wat::core::match bundle-result -> :wat::holon::HolonAST
        ((Ok h)  h)
        ((Err _) (:wat::holon::Atom "unreachable"))))
     ((c :test::Container)
      (:test::Container/new "compound" bundle 3))
     ((retrieved :wat::holon::HolonAST)
      (:test::Container/holon c)))
    (:wat::test::assert-eq
      (:wat::holon::coincident? retrieved bundle)
      true)))
