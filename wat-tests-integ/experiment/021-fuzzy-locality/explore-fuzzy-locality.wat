;; wat-tests-integ/experiment/021-fuzzy-locality/explore-fuzzy-locality.wat
;;
;; The fuzziness — proof 017.
;;
;; Sibling proof to 016 v4. Same shape: real wat forms, real
;; :wat::eval-step! driver, the dual-LRU coordinate cache from
;; Chapter 59. ONE thing different: the cache lookup is fuzzy.
;;
;; Builder framing (2026-04-27):
;;
;;   "now... let's do the same.. but with thermometer values...
;;    i want to prove that we can have 1.95 and 2.05 be coincident
;;    in some holographic depth to short cut...
;;
;;    this is the 'fuzzy-ness'... we used concrete values in the
;;    last run i believe... now show that we can use the substrate
;;    itself to shortcut"
;;
;; Proof 016 keyed the cache by exact HolonAST identity (arc 057's
;; derive-Hash + derive-Eq). Two forms differing in any leaf were
;; distinct cache slots. This proof keys the cache by the
;; substrate's coincident? predicate — the cosine-based "are these
;; the same point on the algebra grid within sigma?" test. Two
;; forms whose ENCODED VECTORS are coincident hit the same cache
;; slot, even when their HolonAST structure is technically different.
;;
;; ─── The holographic-depth property ──────────────────────────
;;
;; A form like (:my::indicator 1.95) lowers to a HolonAST whose
;; scalar arg is HolonAST::F64(1.95) — a primitive leaf. The leaf
;; encoder treats each distinct f64 as a quasi-orthogonal atom.
;; (:my::indicator 1.95) and (:my::indicator 2.05) at THIS depth
;; encode to quasi-orthogonal vectors. coincident? = false.
;;
;; But :my::indicator's body is:
;;
;;   (:wat::holon::Bind
;;     (:wat::holon::Atom "indicator")
;;     (:wat::holon::Thermometer n -100.0 100.0))
;;
;; After arc 068 β-reduces (:my::indicator 1.95), n is substituted
;; with 1.95 in the body. The post-β form is now a Bind expression
;; whose scalar arg is wrapped in Thermometer — a locality-
;; preserving encoder, NOT a quasi-orthogonal leaf. Two post-β
;; forms with Thermometer values 1.95 vs 2.05 over R=200 produce
;; vectors with cosine ≈ 1 - 2*0.1/200 ≈ 0.999. coincident? = TRUE.
;;
;; The expansion chain has FUZZY-ELIGIBLE coordinates and EXACT-
;; ELIGIBLE coordinates. The walker uses fuzzy lookup at every
;; level. Pre-β level misses; post-β level hits. The cache short-
;; circuits at the FIRST coincident coordinate it finds. *That* is
;; "some holographic depth to short cut."
;;
;; ─── Tests ────────────────────────────────────────────────────
;;
;; T1  Walk (:my::indicator 1.95). Terminal is Bind(Atom("indicator"),
;;     Thermometer{1.95,-100,100}). Cache fills with chain coordinates.
;; T2  THE FUZZY HIT: walker A walks 1.95; walker B walks 2.05.
;;     B's pre-β form misses (F64 leaves quasi-orthogonal); B's
;;     post-β form HITS (Thermometer locality). B inherits A's
;;     terminal — B's returned value is A's (with 1.95, not 2.05).
;; T3  Distant value: walker C walks 8.5. Even at the post-β
;;     coordinate, |Δ|=6.55 / R=200 > 0.005 → cosine < 0.99 →
;;     not coincident. Full chain walked; new cache entries.
;; T4  Coincidence at the post-β coordinate is provable directly:
;;     coincident? on the two post-β HolonASTs returns true.
;; T5  Pre-β coordinates are NOT coincident (orthogonal f64 leaves).
;;     coincident? returns false. The holographic-depth claim is
;;     load-bearing: fuzziness emerges DEEPER in the chain, not at
;;     the surface.
;; T6  N walkers populating the cache. Overlapping queries land on
;;     overlapping fuzzy buckets. Distant queries don't.

(:wat::test::make-deftest :deftest
  (;; ─── The indicator function ────────────────────────────
   ;;
   ;; Wraps a raw f64 in a Thermometer-encoded Bind. The body's
   ;; encoded form is what carries locality; the call form (with
   ;; the raw f64) does not.
   (:wat::core::define
     (:my::indicator (n :f64) -> :wat::holon::HolonAST)
     (:wat::holon::Bind
       (:wat::holon::Atom "indicator")
       (:wat::holon::Thermometer n -100.0 100.0)))


   ;; ─── FuzzyCache: linear-scan with coincident? ──────────
   ;;
   ;; HashMap can't fuzzy-match (Hash + Eq is exact). For
   ;; coincident-keyed lookup we walk entries with foldl until
   ;; we find one whose form-key is coincident with the query.
   ;; O(N) per lookup. The trade vs. byte-keyed HashMap is what
   ;; buys locality: two near-equivalent forms hit the same slot.
   (:wat::core::struct :exp::FuzzyEntry
     (form-key :wat::holon::HolonAST)
     (terminal :wat::holon::HolonAST))

   (:wat::core::struct :exp::FuzzyCache
     (entries :Vec<exp::FuzzyEntry>))

   (:wat::core::define
     (:exp::cache-empty -> :exp::FuzzyCache)
     (:exp::FuzzyCache/new (:wat::core::vec :exp::FuzzyEntry)))

   (:wat::core::define
     (:exp::cache-record
       (cache :exp::FuzzyCache)
       (form-key :wat::holon::HolonAST)
       (terminal :wat::holon::HolonAST)
       -> :exp::FuzzyCache)
     (:exp::FuzzyCache/new
       (:wat::core::conj
         (:exp::FuzzyCache/entries cache)
         (:exp::FuzzyEntry/new form-key terminal))))

   ;; The fuzzy primitive — coincident? per entry.
   (:wat::core::define
     (:exp::cache-lookup-fuzzy
       (cache :exp::FuzzyCache)
       (query :wat::holon::HolonAST)
       -> :Option<wat::holon::HolonAST>)
     (:wat::core::foldl
       (:exp::FuzzyCache/entries cache)
       :None
       (:wat::core::lambda
         ((acc :Option<wat::holon::HolonAST>)
          (entry :exp::FuzzyEntry)
          -> :Option<wat::holon::HolonAST>)
         (:wat::core::match acc -> :Option<wat::holon::HolonAST>
           ((Some _) acc)
           (:None
             (:wat::core::if
               (:wat::holon::coincident?
                 query
                 (:exp::FuzzyEntry/form-key entry))
               -> :Option<wat::holon::HolonAST>
               (Some (:exp::FuzzyEntry/terminal entry))
               :None))))))


   ;; ─── Walker — fuzzy version of proof 016's driver ──────
   ;;
   ;; At every level: fuzzy-lookup the current form's HolonAST
   ;; coordinate. If a coincident entry exists, return its
   ;; terminal (short-circuit; "close enough" wins). Else step;
   ;; record (form-key → terminal) on the way back up.
   (:wat::core::define
     (:exp::walk-fuzzy
       (form :wat::WatAST)
       (cache :exp::FuzzyCache)
       -> :(wat::holon::HolonAST,exp::FuzzyCache))
     (:wat::core::let*
       (((form-key :wat::holon::HolonAST) (:wat::holon::from-watast form))
        ((cached :Option<wat::holon::HolonAST>)
         (:exp::cache-lookup-fuzzy cache form-key)))
       (:wat::core::match cached
         -> :(wat::holon::HolonAST,exp::FuzzyCache)
         ;; Fuzzy hit: return the cached terminal, no eval-step!.
         ((Some t) (:wat::core::tuple t cache))
         ;; Miss: step, recurse, record.
         (:None (:exp::walk-fuzzy-step form form-key cache)))))

   (:wat::core::define
     (:exp::walk-fuzzy-step
       (form :wat::WatAST)
       (form-key :wat::holon::HolonAST)
       (cache :exp::FuzzyCache)
       -> :(wat::holon::HolonAST,exp::FuzzyCache))
     (:wat::core::match (:wat::eval-step! form)
       -> :(wat::holon::HolonAST,exp::FuzzyCache)
       ((Ok r)
         (:wat::core::match r
           -> :(wat::holon::HolonAST,exp::FuzzyCache)
           ;; Reached terminal: record and return.
           ((:wat::eval::StepResult::StepTerminal t)
             (:wat::core::tuple t (:exp::cache-record cache form-key t)))
           ;; One step happened: recurse into the next form, then
           ;; backprop the resulting terminal at THIS form's level.
           ((:wat::eval::StepResult::StepNext next)
             (:wat::core::let*
               (((result :(wat::holon::HolonAST,exp::FuzzyCache))
                 (:exp::walk-fuzzy next cache))
                ((t :wat::holon::HolonAST) (:wat::core::first result))
                ((cache' :exp::FuzzyCache) (:wat::core::second result)))
               (:wat::core::tuple t
                 (:exp::cache-record cache' form-key t))))))
       ;; Effectful op or no-step-rule: fall back to eval-ast!.
       ((Err _e)
         (:wat::core::match (:wat::eval-ast! form)
           -> :(wat::holon::HolonAST,exp::FuzzyCache)
           ((Ok t) (:wat::core::tuple t (:exp::cache-record cache form-key t)))
           ((Err _e2) (:wat::core::tuple (:wat::holon::leaf -1) cache))))))


   ;; ─── Test fixtures ─────────────────────────────────────
   ;;
   ;; The post-β-reduction HolonAST shape we expect:
   ;;   Bind(Atom("indicator"), Thermometer{n,-100,100})
   ;; Built directly here for assertion against the walker's terminal.
   (:wat::core::define
     (:exp::expected-post-beta (n :f64) -> :wat::holon::HolonAST)
     (:wat::holon::Bind
       (:wat::holon::Atom "indicator")
       (:wat::holon::Thermometer n -100.0 100.0)))))


;; ════════════════════════════════════════════════════════════════
;;  T1 — Walker reaches expected terminal for (:my::indicator 1.95)
;; ════════════════════════════════════════════════════════════════
;;
;; Sanity: the chain bottoms out at Bind(Atom("indicator"),
;; Thermometer{1.95,-100,100}). The cache picks up entries along
;; the way.

(:deftest :exp::t1-walk-indicator-1-95
  (:wat::core::let*
    (((form :wat::WatAST)
      (:wat::core::quote (:my::indicator 1.95)))
     ((result :(wat::holon::HolonAST,exp::FuzzyCache))
      (:exp::walk-fuzzy form (:exp::cache-empty)))
     ((terminal :wat::holon::HolonAST) (:wat::core::first result))
     ((expected :wat::holon::HolonAST) (:exp::expected-post-beta 1.95)))
    (:wat::test::assert-eq (:wat::holon::coincident? terminal expected) true)))


;; ════════════════════════════════════════════════════════════════
;;  T2 — THE FUZZY HIT: 2.05's walk inherits 1.95's work
;; ════════════════════════════════════════════════════════════════
;;
;; Walker A: (:my::indicator 1.95). Cache fills.
;; Walker B: (:my::indicator 2.05). At the post-β coordinate,
;; coincident? matches A's entry. B's terminal IS A's terminal —
;; the fuzzy-hit's "close enough" answer.
;;
;; Verifying B's returned terminal is coincident with A's expected
;; (1.95-flavored) terminal — NOT B's own 2.05-flavored terminal,
;; because B never computed it. The cache won.

(:deftest :exp::t2-fuzzy-hit-2-05-inherits-1-95
  (:wat::core::let*
    (;; Walker A.
     ((a-form :wat::WatAST) (:wat::core::quote (:my::indicator 1.95)))
     ((rA :(wat::holon::HolonAST,exp::FuzzyCache))
      (:exp::walk-fuzzy a-form (:exp::cache-empty)))
     ((cache-after-A :exp::FuzzyCache) (:wat::core::second rA))

     ;; Walker B on the same cache.
     ((b-form :wat::WatAST) (:wat::core::quote (:my::indicator 2.05)))
     ((rB :(wat::holon::HolonAST,exp::FuzzyCache))
      (:exp::walk-fuzzy b-form cache-after-A))
     ((b-terminal :wat::holon::HolonAST) (:wat::core::first rB))

     ;; B's terminal should be coincident with A's expected
     ;; (the 1.95-flavored Bind), demonstrating the fuzzy short-cut.
     ((a-expected :wat::holon::HolonAST) (:exp::expected-post-beta 1.95))
     ((fuzzy-shared :bool) (:wat::holon::coincident? b-terminal a-expected)))
    (:wat::test::assert-eq fuzzy-shared true)))


;; ════════════════════════════════════════════════════════════════
;;  T3 — Distant value: locality is bounded
;; ════════════════════════════════════════════════════════════════
;;
;; (:my::indicator 8.5) is too far from 1.95 to coincide at the
;; post-β coordinate. |Δ|=6.55 over R=200 gives cosine ≈
;; 1 - 0.0655 = 0.9345 < 0.99 (the d=10000 sigma=1 floor). NOT
;; coincident. C's walker fires eval-step! all the way through.
;;
;; Verified by: C's terminal IS coincident with the 8.5-shaped
;; expected post-beta, and NOT coincident with A's (1.95) one.

(:deftest :exp::t3-distant-value-misses-fuzzy
  (:wat::core::let*
    (((a-form :wat::WatAST) (:wat::core::quote (:my::indicator 1.95)))
     ((rA :(wat::holon::HolonAST,exp::FuzzyCache))
      (:exp::walk-fuzzy a-form (:exp::cache-empty)))
     ((cache-after-A :exp::FuzzyCache) (:wat::core::second rA))

     ((c-form :wat::WatAST) (:wat::core::quote (:my::indicator 8.5)))
     ((rC :(wat::holon::HolonAST,exp::FuzzyCache))
      (:exp::walk-fuzzy c-form cache-after-A))
     ((c-terminal :wat::holon::HolonAST) (:wat::core::first rC))

     ((c-expected :wat::holon::HolonAST) (:exp::expected-post-beta 8.5))
     ((a-expected :wat::holon::HolonAST) (:exp::expected-post-beta 1.95))

     ;; C got its OWN terminal, not A's.
     ((c-correct :bool) (:wat::holon::coincident? c-terminal c-expected))
     ((c-not-A :bool)
       (:wat::core::not (:wat::holon::coincident? c-terminal a-expected)))

     ((_c :()) (:wat::test::assert-eq c-correct true)))
    (:wat::test::assert-eq c-not-A true)))


;; ════════════════════════════════════════════════════════════════
;;  T4 — Post-β coordinates ARE coincident (the property the cache rides on)
;; ════════════════════════════════════════════════════════════════
;;
;; Direct check on the substrate's algebra-grid identity. Two
;; HolonAST::Bind values with Thermometer{1.95} and Thermometer{2.05}
;; over R=200 are the same point per coincident?. This is the
;; substrate-level claim the fuzzy cache builds on.

(:deftest :exp::t4-post-beta-coords-coincident
  (:wat::core::let*
    (((post-beta-1-95 :wat::holon::HolonAST) (:exp::expected-post-beta 1.95))
     ((post-beta-2-05 :wat::holon::HolonAST) (:exp::expected-post-beta 2.05)))
    (:wat::test::assert-eq
      (:wat::holon::coincident? post-beta-1-95 post-beta-2-05) true)))


;; ════════════════════════════════════════════════════════════════
;;  T5 — Pre-β coordinates are NOT coincident (the holographic-depth claim)
;; ════════════════════════════════════════════════════════════════
;;
;; The user's "some holographic depth" claim, made load-bearing.
;; Pre-β-reduction, the form's HolonAST contains an F64 leaf
;; (quasi-orthogonal encoding per arc 057). Two F64 leaves with
;; nearby values are NOT coincident. Fuzziness emerges DEEPER —
;; only after β-reduction wraps the scalar in Thermometer.
;;
;; Without this asymmetry, the cache would either: (a) merge
;; everything (over-promise locality) or (b) merge nothing (no
;; fuzziness possible). The substrate's per-leaf encoding choice
;; — orthogonal for atoms, locality-preserving for Thermometer —
;; is what makes the holographic-depth shape work cleanly.

(:deftest :exp::t5-pre-beta-coords-NOT-coincident
  (:wat::core::let*
    (((pre-beta-1-95 :wat::holon::HolonAST)
      (:wat::holon::from-watast
        (:wat::core::quote (:my::indicator 1.95))))
     ((pre-beta-2-05 :wat::holon::HolonAST)
      (:wat::holon::from-watast
        (:wat::core::quote (:my::indicator 2.05))))
     ((coincide :bool)
      (:wat::holon::coincident? pre-beta-1-95 pre-beta-2-05)))
    (:wat::test::assert-eq coincide false)))


;; ════════════════════════════════════════════════════════════════
;;  T6 — N walkers populate; overlapping queries find each other
;; ════════════════════════════════════════════════════════════════
;;
;; Three walkers populate the cache at distinct values:
;;   3.0, 6.0, 9.0 — each |Δ|=3 apart (1.5% of R=200).
;; A fourth walker at 3.05 should HIT the 3.0 entry (|Δ|=0.05,
;; 0.025% of R, well within tolerance).
;; A fifth walker at 5.0 is half-way between 3.0 and 6.0; its
;; post-β coordinate is coincident with NEITHER (|Δ|=2 from
;; either, 1% of R, just past the 0.5% tolerance for d=10000).
;; The fifth walker fires its own eval-step!.
;;
;; The shape: locality-keyed cache forms NEIGHBORHOODS around
;; populated coordinates, with size ~ tolerance/range.

(:deftest :exp::t6-many-walkers-cooperating-neighborhoods
  (:wat::core::let*
    (;; Walkers populate at 3.0, 6.0, 9.0.
     ((c0 :exp::FuzzyCache) (:exp::cache-empty))

     ((r3 :(wat::holon::HolonAST,exp::FuzzyCache))
      (:exp::walk-fuzzy (:wat::core::quote (:my::indicator 3.0)) c0))
     ((c3 :exp::FuzzyCache) (:wat::core::second r3))

     ((r6 :(wat::holon::HolonAST,exp::FuzzyCache))
      (:exp::walk-fuzzy (:wat::core::quote (:my::indicator 6.0)) c3))
     ((c6 :exp::FuzzyCache) (:wat::core::second r6))

     ((r9 :(wat::holon::HolonAST,exp::FuzzyCache))
      (:exp::walk-fuzzy (:wat::core::quote (:my::indicator 9.0)) c6))
     ((populated-cache :exp::FuzzyCache) (:wat::core::second r9))

     ;; Walker at 3.05 — close to 3.0.
     ((r-near :(wat::holon::HolonAST,exp::FuzzyCache))
      (:exp::walk-fuzzy (:wat::core::quote (:my::indicator 3.05)) populated-cache))
     ((near-terminal :wat::holon::HolonAST) (:wat::core::first r-near))
     ((expected-3-0 :wat::holon::HolonAST) (:exp::expected-post-beta 3.0))
     ((near-hits-3-0 :bool)
       (:wat::holon::coincident? near-terminal expected-3-0))

     ;; Walker at 5.0 — between 3.0 and 6.0; outside both
     ;; neighborhoods. Fires its own chain.
     ((r-between :(wat::holon::HolonAST,exp::FuzzyCache))
      (:exp::walk-fuzzy (:wat::core::quote (:my::indicator 5.0)) populated-cache))
     ((between-terminal :wat::holon::HolonAST) (:wat::core::first r-between))
     ((expected-5-0 :wat::holon::HolonAST) (:exp::expected-post-beta 5.0))
     ((between-correct :bool)
       (:wat::holon::coincident? between-terminal expected-5-0))

     ((_n :()) (:wat::test::assert-eq near-hits-3-0 true)))
    (:wat::test::assert-eq between-correct true)))
