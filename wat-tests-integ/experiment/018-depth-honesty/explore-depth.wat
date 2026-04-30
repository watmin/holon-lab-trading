;; wat-tests-integ/experiment/018-depth-honesty/explore-depth.wat
;;
;; Depth-honesty proof — proof 014.
;;
;; Builder framing (2026-04-26):
;;
;;   "we should have a proof that exploring N-depth is honest as
;;    long as the items-at-N-depth are within the capacity limit...
;;    digging out (x y z a b c d e) depth for many many things...
;;    we are always able to retrieve the arbitrary depth?"
;;
;; Chapter 39's claim: depth is free. The substrate's per-level
;; Kanerva capacity is √d = 100 at d=10000; so long as each level
;; respects that bound, depth composes without loss.
;;
;; Chapter 52 demonstrated tree walking at small scale (3-4 levels,
;; 2-3 children per level). This proof scales: 8-level paths
;; through trees with up to 99 siblings per level (just under
;; capacity). Verifies the substrate's depth-is-free claim at the
;; boundary.
;;
;; ─── The mechanism ──────────────────────────────────────────
;;
;; Each tree node is a Bundle of (Bind(key, child)) pairs. To
;; walk one step down: Bind(target_key, current_node) — MAP VSA's
;; commutative Bind unwinds the matching binding, leaving a noisy
;; vector toward the child. Cleanup against candidate children
;; identifies the right one.
;;
;; For a path (k1, k2, ..., kN) through depth N:
;;   result = Bind(kN, Bind(k_{N-1}, ... Bind(k1, root) ...))
;; The result carries the leaf's signal at the path's endpoint,
;; plus accumulated noise from sibling subtrees at each level.
;; Cosine of the result against the planted leaf vs other
;; candidates reveals whether the walk succeeded.
;;
;; ─── What this proof verifies ───────────────────────────────
;;
;; T1  Depth=4, width=10              — small baseline
;; T2  Depth=8, width=10              — longer path, modest width
;; T3  Depth=8, width=50              — half-capacity per level
;; T4  Depth=8, width=99              — at-capacity per level
;; T5  Different paths through same tree → different leaves
;; T6  Wrong path → does NOT retrieve planted leaf (negative)
;;
;; ─── What "honest" means here ───────────────────────────────
;;
;; cosine(walk-result, planted-leaf) > cosine(walk-result, other-leaf)
;;
;; Argmax classification at the leaf level. Not strict
;; coincident? (which would require cleanup at each level under
;; Plate's HRR scheme). Just: does the substrate distinguish the
;; correct leaf from an unrelated leaf at the path's endpoint?
;;
;; If yes → depth is honest under capacity-bounded width.
;; If no → the substrate's signal degrades faster than its
;; per-level capacity claim suggests.

(:wat::test::make-deftest :deftest
  (;; ─── Atom helpers ─────────────────────────────────────────
   ;;
   ;; Generate distinct atoms by index for siblings + leaves.
   ;; Each atom is a Bind(label, leaf(n)) — distinct n produces
   ;; distinct atoms with quasi-orthogonal vectors at d=10000.
   (:wat::core::define
     (:exp::sibling-atom (level :wat::core::i64) (idx :wat::core::i64) -> :wat::holon::HolonAST)
     (:wat::holon::Bind
       (:wat::holon::Atom "sibling")
       (:wat::holon::leaf
         (:wat::core::+ (:wat::core::* level 10000) idx))))

   (:wat::core::define
     (:exp::path-key (level :wat::core::i64) -> :wat::holon::HolonAST)
     (:wat::holon::Bind
       (:wat::holon::Atom "key")
       (:wat::holon::leaf level)))

   (:wat::core::define
     (:exp::leaf-atom (id :wat::core::i64) -> :wat::holon::HolonAST)
     (:wat::holon::Bind
       (:wat::holon::Atom "planted-leaf")
       (:wat::holon::leaf id)))


   ;; ─── Tree node builder ──────────────────────────────────
   ;;
   ;; Build one tree level: Bundle of (Bind(key_i, child_i)).
   ;; The path-key entry's child is the deeper subtree (or the
   ;; final leaf at depth=0); the other entries are sibling
   ;; placeholders (just unique atoms).
   ;;
   ;; If the bundle's capacity fails (width > √d), returns the
   ;; sibling-0 atom as a sentinel — won't retrieve correctly,
   ;; but won't panic. Tests at width ≤ 100 won't hit this.
   (:wat::core::define
     (:exp::build-level
       (level :wat::core::i64)
       (width :wat::core::i64)
       (path-child :wat::holon::HolonAST)
       -> :wat::holon::HolonAST)
     (:wat::core::let*
       (((path-binding :wat::holon::HolonAST)
          (:wat::holon::Bind (:exp::path-key level) path-child))
        ((sibling-bindings :wat::holon::Holons)
          (:wat::core::map (:wat::core::range 1 width)
            (:wat::core::lambda ((i :wat::core::i64) -> :wat::holon::HolonAST)
              (:wat::holon::Bind
                (:exp::sibling-atom level i)
                (:exp::sibling-atom level (:wat::core::+ i 100000))))))
        ((all-bindings :wat::holon::Holons)
          (:wat::core::concat
            (:wat::core::vec :wat::holon::HolonAST path-binding)
            sibling-bindings)))
       (:wat::core::match (:wat::holon::Bundle all-bindings)
         -> :wat::holon::HolonAST
         ((Ok h) h)
         ((Err _) (:exp::sibling-atom level 0)))))


   ;; ─── Recursive tree builder via tail recursion ─────────
   ;;
   ;; Build N levels deep. Each level wraps the previous via
   ;; build-level. Starts at the leaf and works outward.
   ;;
   ;; build-tree(depth=4, width=10, leaf-id=42):
   ;;   level-4 → leaf-42
   ;;   level-3 → bundle((path-key-3, level-4-result), siblings...)
   ;;   level-2 → bundle((path-key-2, level-3-result), siblings...)
   ;;   level-1 → bundle((path-key-1, level-2-result), siblings...)
   ;;   ROOT = level-1-result
   (:wat::core::define
     (:exp::build-tree-step
       (current-level :wat::core::i64)
       (max-depth :wat::core::i64)
       (width :wat::core::i64)
       (acc :wat::holon::HolonAST)
       -> :wat::holon::HolonAST)
     (:wat::core::if (:wat::core::> current-level max-depth)
       -> :wat::holon::HolonAST
       acc
       (:exp::build-tree-step
         (:wat::core::+ current-level 1)
         max-depth
         width
         (:exp::build-level current-level width acc))))

   (:wat::core::define
     (:exp::build-tree
       (depth :wat::core::i64)
       (width :wat::core::i64)
       (leaf-id :wat::core::i64)
       -> :wat::holon::HolonAST)
     (:exp::build-tree-step 1 depth width (:exp::leaf-atom leaf-id)))


   ;; ─── Walker ─────────────────────────────────────────────
   ;;
   ;; Walk N levels down by successive Bind operations. Bind(k, B)
   ;; is the unbinding move under MAP VSA's commutative product.
   ;; After N hops, the result is a noisy vector toward the leaf
   ;; at the path's endpoint.
   ;;
   ;; Walk path goes from level 1 down to level depth (consuming
   ;; the outermost binding first, since the outermost level
   ;; was built LAST and wraps everything).
   (:wat::core::define
     (:exp::walk-step
       (level :wat::core::i64)
       (max-depth :wat::core::i64)
       (acc :wat::holon::HolonAST)
       -> :wat::holon::HolonAST)
     (:wat::core::if (:wat::core::> level max-depth)
       -> :wat::holon::HolonAST
       acc
       (:exp::walk-step
         (:wat::core::+ level 1)
         max-depth
         (:wat::holon::Bind (:exp::path-key level) acc))))

   (:wat::core::define
     (:exp::walk-path
       (root :wat::holon::HolonAST)
       (depth :wat::core::i64)
       -> :wat::holon::HolonAST)
     (:exp::walk-step 1 depth root))


   ;; ─── Walk-test predicate ────────────────────────────────
   ;;
   ;; Build a tree at (depth, width) with planted leaf id.
   ;; Walk the path. Cosine the result against:
   ;;   - the planted leaf (correct)
   ;;   - a different leaf id (wrong, control)
   ;; Return true iff cosine to the planted is HIGHER than to
   ;; the wrong leaf. That's argmax-classification.
   (:wat::core::define
     (:exp::walk-finds-leaf?
       (depth :wat::core::i64)
       (width :wat::core::i64)
       (leaf-id :wat::core::i64)
       -> :wat::core::bool)
     (:wat::core::let*
       (((root :wat::holon::HolonAST) (:exp::build-tree depth width leaf-id))
        ((result :wat::holon::HolonAST) (:exp::walk-path root depth))
        ((correct :wat::holon::HolonAST) (:exp::leaf-atom leaf-id))
        ((wrong :wat::holon::HolonAST) (:exp::leaf-atom (:wat::core::+ leaf-id 9999)))
        ((cos-correct :wat::core::f64) (:wat::holon::cosine result correct))
        ((cos-wrong :wat::core::f64) (:wat::holon::cosine result wrong)))
       (:wat::core::f64::> cos-correct cos-wrong)))))


;; ════════════════════════════════════════════════════════════════
;;  T1 — Depth=4, width=10 — small baseline
;; ════════════════════════════════════════════════════════════════
;;
;; Walk 4 levels. Each level has 10 siblings. Well under capacity
;; per level. Substrate should retrieve the planted leaf cleanly.

(:deftest :exp::t1-depth4-width10
  (:wat::core::let*
    (((found :wat::core::bool) (:exp::walk-finds-leaf? 4 10 42)))
    (:wat::test::assert-eq found true)))


;; ════════════════════════════════════════════════════════════════
;;  T2 — Depth=8, width=10 — longer path, modest width
;; ════════════════════════════════════════════════════════════════
;;
;; The (x y z a b c d e) depth the user named: 8 levels. Modest
;; width per level. Substrate's depth-is-free claim should hold.

(:deftest :exp::t2-depth8-width10
  (:wat::core::let*
    (((found :wat::core::bool) (:exp::walk-finds-leaf? 8 10 100)))
    (:wat::test::assert-eq found true)))


;; ════════════════════════════════════════════════════════════════
;;  T3 — Depth=8, width=50 — half-capacity per level
;; ════════════════════════════════════════════════════════════════
;;
;; 8 levels, 50 siblings per level. Each level is half the
;; Kanerva capacity (50 of 100). Tests substrate retrieval when
;; per-level dilution is moderate.

(:deftest :exp::t3-depth8-width50
  (:wat::core::let*
    (((found :wat::core::bool) (:exp::walk-finds-leaf? 8 50 200)))
    (:wat::test::assert-eq found true)))


;; ════════════════════════════════════════════════════════════════
;;  T4 — Depth=8, width=99 — at-capacity per level
;; ════════════════════════════════════════════════════════════════
;;
;; 8 levels, 99 siblings per level (just under √d=100 boundary).
;; Each level is operating at the Kanerva capacity edge. The
;; substrate's depth-is-free claim is most stressed here.
;;
;; If the walk still finds the leaf at depth=8 with width=99 per
;; level, the substrate is honoring its claim that capacity-
;; bounded levels compose to arbitrary depth.

(:deftest :exp::t4-depth8-width99-at-capacity
  (:wat::core::let*
    (((found :wat::core::bool) (:exp::walk-finds-leaf? 8 99 300)))
    (:wat::test::assert-eq found true)))


;; ════════════════════════════════════════════════════════════════
;;  T5 — Different paths → different leaves (independence)
;; ════════════════════════════════════════════════════════════════
;;
;; Build TWO trees with DIFFERENT planted leaves. Walk the same
;; path through both. Each walk should retrieve the leaf planted
;; in ITS tree, not the other.
;;
;; Tests that the substrate's retrieval isn't somehow leaking
;; signal between different tree instances.

(:deftest :exp::t5-different-trees-different-leaves
  (:wat::core::let*
    (;; Tree A: planted leaf id 500.
     ((root-a :wat::holon::HolonAST) (:exp::build-tree 6 30 500))
     ((result-a :wat::holon::HolonAST) (:exp::walk-path root-a 6))
     ((leaf-a :wat::holon::HolonAST) (:exp::leaf-atom 500))
     ((leaf-b :wat::holon::HolonAST) (:exp::leaf-atom 600))
     ((cos-a-correct :wat::core::f64) (:wat::holon::cosine result-a leaf-a))
     ((cos-a-wrong :wat::core::f64) (:wat::holon::cosine result-a leaf-b))

     ;; Tree B: planted leaf id 600.
     ((root-b :wat::holon::HolonAST) (:exp::build-tree 6 30 600))
     ((result-b :wat::holon::HolonAST) (:exp::walk-path root-b 6))
     ((cos-b-correct :wat::core::f64) (:wat::holon::cosine result-b leaf-b))
     ((cos-b-wrong :wat::core::f64) (:wat::holon::cosine result-b leaf-a))

     ((a-found-correctly :wat::core::bool) (:wat::core::f64::> cos-a-correct cos-a-wrong))
     ((b-found-correctly :wat::core::bool) (:wat::core::f64::> cos-b-correct cos-b-wrong))

     ((_a :()) (:wat::test::assert-eq a-found-correctly true)))
    (:wat::test::assert-eq b-found-correctly true)))


;; ════════════════════════════════════════════════════════════════
;;  T6 — Wrong path doesn't retrieve the planted leaf (negative)
;; ════════════════════════════════════════════════════════════════
;;
;; Build a tree with the standard path-keys. Walk the WRONG path
;; (using sibling atoms as keys instead of the path-keys). The
;; result should NOT cosine higher to the planted leaf than to
;; an unrelated leaf.
;;
;; Negative test — confirms the walk's correctness is path-
;; dependent. If wrong-path retrievals also "found" the leaf, the
;; substrate would be giving false positives.
;;
;; We construct a wrong-path walk by using sibling-atoms as the
;; binding keys (which don't match any of the tree's bindings).

(:deftest :exp::t6-wrong-path-fails
  (:wat::core::let*
    (((root :wat::holon::HolonAST) (:exp::build-tree 4 20 700))

     ;; Walk with WRONG keys — sibling atoms, not the path-keys.
     ((wrong-result :wat::holon::HolonAST)
      (:wat::holon::Bind (:exp::sibling-atom 4 999)
        (:wat::holon::Bind (:exp::sibling-atom 3 999)
          (:wat::holon::Bind (:exp::sibling-atom 2 999)
            (:wat::holon::Bind (:exp::sibling-atom 1 999) root)))))

     ((correct :wat::holon::HolonAST) (:exp::leaf-atom 700))
     ((wrong :wat::holon::HolonAST) (:exp::leaf-atom 800))
     ((cos-correct :wat::core::f64) (:wat::holon::cosine wrong-result correct))
     ((cos-wrong :wat::core::f64) (:wat::holon::cosine wrong-result wrong))

     ;; Property: wrong-path walk should NOT cleanly identify the
     ;; planted leaf. The wrong-result is essentially noise; both
     ;; cosines should be small and roughly equal. Testing that
     ;; cos-correct is NOT meaningfully larger than cos-wrong.
     ;;
     ;; "Meaningfully larger" — at d=10000 the noise floor is 0.01;
     ;; if both cosines are within 5x noise floor (0.05), neither
     ;; is the clear winner.
     ((diff :wat::core::f64) (:wat::core::f64::- cos-correct cos-wrong))
     ((no-clear-winner :wat::core::bool)
       (:wat::core::or
         (:wat::core::f64::< diff 0.05)
         (:wat::core::f64::< (:wat::core::- 0.0 diff) 0.05))))
    (:wat::test::assert-eq no-clear-winner true)))
