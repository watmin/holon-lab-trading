;; wat-tests-integ/experiment/022-fuzzy-on-both-stores/explore-fuzzy-on-both-stores.wat
;;
;; Two cache instances per tier — proof 018.
;;
;; Builder direction (2026-04-27, mid-flight on the trader's
;; coordinate-cache architecture):
;;
;;   "we'll only be using thermometer values for the thoughts we'll
;;    have - the point is to be tolerant to 'this is close enough
;;    to be the same' - the probability of two RSIs being /perfectly
;;    the same as a float/ is like zero - i don't want to round to
;;    2 digits - i want them system to recognize something its seen
;;    within tolerance..
;;
;;    ascend out of strict equality - the substrate prefers you use
;;    it as it is - we've gone beyond classical computing"
;;
;;   "for argument's sake let's just do L1.... l1-form-to-next-form
;;    and l1-form-to-value
;;
;;    /both/ must be utilized..."
;;
;; ─── The architecture (locked) ────────────────────────────────
;;
;; At every tier, TWO cache instances:
;;   - one for `form → next-form` (the chain pointer)
;;   - one for `form → terminal-value` (the answer)
;;
;; Both fuzzy-only — Vec of (form, value) pairs scanned with
;; coincident?. No exact bucket. Byte-identical hits trivially via
;; cos=1.0; near-equivalent thoughts hit too. Strict equality is a
;; degenerate case of coincidence, not a separate concern. The
;; cache caps at sqrt(d) entries (~100 at d=10000) per the
;; substrate's Kanerva budget.
;;
;; Within-tier priority:
;;   1. terminal lookup — hit: done (the answer)
;;   2. next-form lookup — hit: hop and recurse
;;   3. miss: eval-step!; backfill both stores
;;
;; This proof models ONE tier (L1). L2+ are structurally identical;
;; proving L1 is sufficient.
;;
;; ─── On the thoughts in this proof ───────────────────────────
;;
;; Trader thoughts are Thermometers from the moment they exist.
;; A thinker doesn't call a function with f64 args; it constructs
;; a HolonAST directly:
;;
;;     (Bind (Atom "rsi-thought") (Thermometer rsi-val 0.0 100.0))
;;
;; The thought IS the holon constructor expression. Stepping it via
;; eval-step! fires the constructors in one shot — single-step
;; from the cache's perspective. The cache key is the thought's
;; HolonAST identity, with Thermometer leaves throughout.
;;
;; F64 leaves do not appear in trader thoughts. Strict-byte equality
;; on cache keys would be silly — two RSI values are essentially
;; never byte-identical floats. The substrate's coincident? predicate
;; is the relation; the cache uses it natively.

(:wat::test::make-deftest :deftest
  (;; ─── Trader-shape thoughts ───────────────────────────────
   ;;
   ;; Each helper returns a HolonAST — the thought is constructed
   ;; by RUNNING the holon constructors directly:
   ;;   (Bind (Atom "rsi-thought") (Thermometer rsi-value 0.0 100.0))
   ;; This is how trader thinkers produce thoughts. We do not quote
   ;; the form: `(quote ...)` lowers a List into Bundle of leaves
   ;; (Symbol/F64/...), destroying the locality-preserving Thermometer
   ;; leaf and replacing it with quasi-orthogonal F64 tokens. Two
   ;; near-equivalent thoughts would differ only in F64 leaves, which
   ;; are encoded independently of numeric value, and the cache would
   ;; never see them as coincident. Direct construction returns the
   ;; proper Bind/Atom/Thermometer tree.
   ;;
   ;; Calibration at d=10000, sigma=1: the coincident floor is
   ;; |delta|/range < 0.005. Over R=100 (RSI's natural range), that
   ;; means |delta| < 0.5 for coincidence at default sigma. Tuning
   ;; tolerance to "RSI within 5%" requires sigma=10 or wider
   ;; conceptual range — Phase 2 calibration. This proof uses values
   ;; that comfortably coincide at default sigma.
   (:wat::core::define
     (:exp::thought-rsi-70 -> :wat::holon::HolonAST)
     (:wat::holon::Bind
       (:wat::holon::Atom "rsi-thought")
       (:wat::holon::Thermometer 70.0 0.0 100.0)))

   (:wat::core::define
     (:exp::thought-rsi-70-3 -> :wat::holon::HolonAST)
     ;; |70.3 - 70.0|/100 = 0.003 — comfortably inside coincident
     ;; floor (0.005 of range).
     (:wat::holon::Bind
       (:wat::holon::Atom "rsi-thought")
       (:wat::holon::Thermometer 70.3 0.0 100.0)))

   (:wat::core::define
     (:exp::thought-rsi-30 -> :wat::holon::HolonAST)
     ;; |30.0 - 70.0|/100 = 0.4 — well outside coincident floor.
     (:wat::holon::Bind
       (:wat::holon::Atom "rsi-thought")
       (:wat::holon::Thermometer 30.0 0.0 100.0)))


   ;; ─── Coordinate cache: one fuzzy backing per instance ───
   (:wat::core::struct :exp::CacheEntry
     (form-key :wat::holon::HolonAST)
     (value :wat::holon::HolonAST))

   (:wat::core::struct :exp::CoordinateCache
     (entries :Vec<exp::CacheEntry>))

   (:wat::core::define
     (:exp::cache-empty -> :exp::CoordinateCache)
     (:exp::CoordinateCache/new (:wat::core::vec :exp::CacheEntry)))

   (:wat::core::define
     (:exp::cache-record
       (cache :exp::CoordinateCache)
       (form-key :wat::holon::HolonAST)
       (value :wat::holon::HolonAST)
       -> :exp::CoordinateCache)
     (:exp::CoordinateCache/new
       (:wat::core::conj
         (:exp::CoordinateCache/entries cache)
         (:exp::CacheEntry/new form-key value))))

   ;; The fuzzy lookup. Linear scan; first coincident match wins.
   ;; This is the ONLY lookup primitive — no exact-fallback path.
   (:wat::core::define
     (:exp::cache-lookup
       (cache :exp::CoordinateCache)
       (query :wat::holon::HolonAST)
       -> :Option<wat::holon::HolonAST>)
     (:wat::core::foldl
       (:exp::CoordinateCache/entries cache)
       :None
       (:wat::core::lambda
         ((acc :Option<wat::holon::HolonAST>)
          (entry :exp::CacheEntry)
          -> :Option<wat::holon::HolonAST>)
         (:wat::core::match acc -> :Option<wat::holon::HolonAST>
           ((Some _) acc)
           (:None
             (:wat::core::if
               (:wat::holon::coincident?
                 query
                 (:exp::CacheEntry/form-key entry))
               -> :Option<wat::holon::HolonAST>
               (Some (:exp::CacheEntry/value entry))
               :None))))))


   ;; ─── L1 tier: TWO cache instances; both utilized ─────────
   (:wat::core::struct :exp::L1Tier
     (next-cache :exp::CoordinateCache)
     (terminal-cache :exp::CoordinateCache))

   (:wat::core::define
     (:exp::tier-empty -> :exp::L1Tier)
     (:exp::L1Tier/new (:exp::cache-empty) (:exp::cache-empty)))


   ;; ─── Walker driver — :wat::eval::walk per arc 070 ────────
   ;;
   ;; The substrate ships the walker as a fold (arc 070): caller
   ;; supplies an init accumulator + a visit-fn that fires once per
   ;; coordinate with (acc, current-form-watast, step-result). The
   ;; visit-fn returns Continue(acc') to keep walking or
   ;; Skip(terminal, acc') to short-circuit on a known terminal.
   ;;
   ;; The visit-fn handles all THREE step-result variants:
   ;;
   ;;   AlreadyTerminal t  — form was a holon-value-shape; the
   ;;     substrate's recognizer rebuilt the canonical HolonAST as
   ;;     `t`. Cache (t → t) in terminal-cache. Trader-shape
   ;;     thoughts (Bind(Atom, Thermometer)) all hit this path.
   ;;
   ;;   StepTerminal t  — form stepped (one β) to a terminal value.
   ;;     Cache (form-h → t) in terminal-cache, where form-h is the
   ;;     syntactic shape of the pre-step form. Multi-step
   ;;     computations land here at their final coordinate.
   ;;
   ;;   StepNext next-w  — form took one β; chain continues.
   ;;     Cache (form-h → next-h) in next-cache. The walker's loop
   ;;     handles recursion; visit-fn just records this coordinate.
   ;;
   ;; If eval-step! errors mid-chain, walk returns Result::Err; the
   ;; visit-fn never sees the error. Silent-Err-swallow is now
   ;; structurally impossible.
   (:wat::core::define
     (:exp::record-coordinate
       (tier :exp::L1Tier)
       (form-w :wat::WatAST)
       (step :wat::eval::StepResult)
       -> :wat::eval::WalkStep<exp::L1Tier>)
     (:wat::core::match step -> :wat::eval::WalkStep<exp::L1Tier>
       ((:wat::eval::StepResult::AlreadyTerminal t)
         (:wat::eval::WalkStep::Continue
           (:exp::L1Tier/new
             (:exp::L1Tier/next-cache tier)
             (:exp::cache-record (:exp::L1Tier/terminal-cache tier) t t))))
       ((:wat::eval::StepResult::StepTerminal t)
         (:wat::core::let*
           (((form-h :wat::holon::HolonAST) (:wat::holon::from-watast form-w)))
           (:wat::eval::WalkStep::Continue
             (:exp::L1Tier/new
               (:exp::L1Tier/next-cache tier)
               (:exp::cache-record (:exp::L1Tier/terminal-cache tier) form-h t)))))
       ((:wat::eval::StepResult::StepNext next-w)
         (:wat::core::let*
           (((form-h :wat::holon::HolonAST) (:wat::holon::from-watast form-w))
            ((next-h :wat::holon::HolonAST) (:wat::holon::from-watast next-w)))
           (:wat::eval::WalkStep::Continue
             (:exp::L1Tier/new
               (:exp::cache-record (:exp::L1Tier/next-cache tier) form-h next-h)
               (:exp::L1Tier/terminal-cache tier)))))))

   ;; Probe visitor: copies walk_w1's exact pattern. If walker fires,
   ;; count = 1.
   (:wat::core::define
     (:exp::count-visit
       (acc :i64)
       (form :wat::WatAST)
       (step :wat::eval::StepResult)
       -> :wat::eval::WalkStep<i64>)
     (:wat::core::let*
       (((next-acc :i64) (:wat::core::i64::+ acc 1)))
       (:wat::eval::WalkStep::Continue next-acc)))

   ;; Thin wrapper: lifts the HolonAST input to WatAST, calls walk,
   ;; unwraps the Result. Tests retain the (HolonAST, L1Tier) shape.
   (:wat::core::define
     (:exp::walk-and-record
       (form-h :wat::holon::HolonAST)
       (tier :exp::L1Tier)
       -> :(wat::holon::HolonAST,exp::L1Tier))
     (:wat::core::match
       (:wat::eval::walk
         (:wat::holon::to-watast form-h)
         tier
         :exp::record-coordinate)
       -> :(wat::holon::HolonAST,exp::L1Tier)
       ((Ok r) r)
       ((Err _e) (:wat::core::tuple (:wat::holon::leaf -1) tier))))


   ;; ─── Helpers ──────────────────────────────────────────
   (:wat::core::define
     (:exp::is-some-h (o :Option<wat::holon::HolonAST>) -> :bool)
     (:wat::core::match o -> :bool ((Some _) true) (:None false)))

   (:wat::core::define
     (:exp::is-none-h (o :Option<wat::holon::HolonAST>) -> :bool)
     (:wat::core::match o -> :bool ((Some _) false) (:None true)))

))


;; ════════════════════════════════════════════════════════════════
;;  T0 — Trader thoughts return AlreadyTerminal (arc 070)
;; ════════════════════════════════════════════════════════════════
;;
;; A thought built directly via holon constructors —
;; Bind(Atom, Thermometer) — is a value-shape. The substrate's
;; eval-step! recognizer (arc 070) classifies it as
;; StepResult::AlreadyTerminal, with the rebuilt canonical
;; HolonAST as its payload.
;;
;; Two load-bearing claims in one test:
;;   1. eval-step! returns Ok(AlreadyTerminal _) — not StepTerminal,
;;      not StepNext, not Err.
;;   2. The rebuilt HolonAST is coincident with the original thought
;;      (the recognizer faithfully reconstructs the holon tree).
;;
;; Before arc 070, eval-step! returned Err on this case and callers
;; had to infer "this is a value, not a failure" from the absence
;; of a step rule. Arc 070 names it.

(:deftest :exp::t0-thought-is-already-terminal
  (:wat::core::let*
    (((thought-h :wat::holon::HolonAST) (:exp::thought-rsi-70))
     ((form :wat::WatAST) (:wat::holon::to-watast thought-h)))
    (:wat::core::match (:wat::eval-step! form) -> :()
      ((Ok r)
        (:wat::core::match r -> :()
          ((:wat::eval::StepResult::AlreadyTerminal t)
            (:wat::test::assert-coincident t thought-h))
          ((:wat::eval::StepResult::StepTerminal _t)
            (:wat::test::assert-eq :want-already-terminal :got-step-terminal))
          ((:wat::eval::StepResult::StepNext _next)
            (:wat::test::assert-eq :want-already-terminal :got-step-next))))
      ((Err _e)
        (:wat::test::assert-eq :want-already-terminal :got-err)))))


;; ════════════════════════════════════════════════════════════════
;;  T0b — Probe: walker records using its own returned terminal as key
;; ════════════════════════════════════════════════════════════════
;;
;; If walker IS firing the visitor and the visitor's tier-update is
;; propagating, then looking up with the walker's OWN returned
;; terminal must hit (cache stores (t,t); query with t).

(:deftest :exp::t0b-walker-records-self-key
  (:wat::core::let*
    (((thought-h :wat::holon::HolonAST) (:exp::thought-rsi-70))
     ((result :(wat::holon::HolonAST,exp::L1Tier))
      (:exp::walk-and-record thought-h (:exp::tier-empty)))
     ((rebuilt-t :wat::holon::HolonAST) (:wat::core::first result))
     ((tier :exp::L1Tier) (:wat::core::second result))
     ((found :Option<wat::holon::HolonAST>)
       (:exp::cache-lookup (:exp::L1Tier/terminal-cache tier) rebuilt-t)))
    (:wat::core::match found -> :()
      ((Some v) (:wat::test::assert-coincident v rebuilt-t))
      (:None    (:wat::test::assert-eq :want-some-via-rebuilt :got-none)))))


;; Probe: does walker fire visitor at all? Count-visit pattern (walk_w1).
(:deftest :exp::t0c-probe-walk-fires
  (:wat::core::let*
    (((thought-h :wat::holon::HolonAST) (:exp::thought-rsi-70))
     ((form-w :wat::WatAST) (:wat::holon::to-watast thought-h))
     ((walk-result :Result<(wat::holon::HolonAST,i64),wat::core::EvalError>)
      (:wat::eval::walk form-w 0 :exp::count-visit)))
    (:wat::core::match walk-result -> :()
      ((Ok pair)
        (:wat::core::let*
          (((count :i64) (:wat::core::second pair)))
          (:wat::test::assert-eq count 1)))
      ((Err _e) (:wat::test::assert-eq :walk-ok :walk-err)))))


;; ════════════════════════════════════════════════════════════════
;;  T1 — Walker fills terminal-cache from a trader-shape thought
;; ════════════════════════════════════════════════════════════════
;;
;; The thought is a direct holon-constructor expression with a
;; Thermometer leaf. eval-step! returns StepTerminal in ONE step.
;; terminal-cache populates; next-cache stays empty (no
;; intermediate to record).

(:deftest :exp::t1-walker-fills-terminal-cache
  (:wat::core::let*
    (((thought-h :wat::holon::HolonAST) (:exp::thought-rsi-70))
     ((result :(wat::holon::HolonAST,exp::L1Tier))
      (:exp::walk-and-record thought-h (:exp::tier-empty)))
     ((tier :exp::L1Tier) (:wat::core::second result))
     ((found :Option<wat::holon::HolonAST>)
       (:exp::cache-lookup
         (:exp::L1Tier/terminal-cache tier) thought-h)))
    (:wat::core::match found -> :()
      ((Some v) (:wat::test::assert-coincident v thought-h))
      (:None    (:wat::test::assert-eq :cache-empty :cache-had-entry)))))


;; ════════════════════════════════════════════════════════════════
;;  T2 — Byte-identical query hits terminal-cache (cos=1)
;; ════════════════════════════════════════════════════════════════
;;
;; Walker A walks rsi=70.0. A second query rebuilds the exact same
;; thought independently. Coincident? returns true (cos=1.0).
;; The cache hits via the same fuzzy mechanism — exact byte-identity
;; is a degenerate case of coincidence.

(:deftest :exp::t2-byte-identical-hits
  (:wat::core::let*
    (((a-thought-h :wat::holon::HolonAST) (:exp::thought-rsi-70))
     ((rA :(wat::holon::HolonAST,exp::L1Tier))
      (:exp::walk-and-record a-thought-h (:exp::tier-empty)))
     ((tier :exp::L1Tier) (:wat::core::second rA))

     ;; Same exact thought, rebuilt.
     ((b-key :wat::holon::HolonAST) (:exp::thought-rsi-70))

     ((found :Option<wat::holon::HolonAST>)
       (:exp::cache-lookup (:exp::L1Tier/terminal-cache tier) b-key)))
    (:wat::core::match found -> :()
      ((Some v) (:wat::test::assert-coincident v a-thought-h))
      (:None    (:wat::test::assert-eq :cache-empty :cache-had-entry)))))


;; ════════════════════════════════════════════════════════════════
;;  T3a — Probe: are the two thoughts coincident at the substrate?
;; ════════════════════════════════════════════════════════════════
;;
;; Before testing the cache lookup, probe the substrate's actual
;; coincidence judgement on the pair we expect to coincide. If
;; this fails, arc 069's assert-coincident renders the diagnostic
;; (cosine, floor, sigma, dim, min-sigma-to-pass) directly into
;; the failure payload — telling us whether we're in calibration
;; territory (small min-sigma-to-pass) or structurally distant
;; (large min-sigma-to-pass with low cosine).

(:deftest :exp::t3a-probe-coincidence-near-equivalent
  (:wat::core::let*
    (((a-key :wat::holon::HolonAST) (:exp::thought-rsi-70))
     ((b-key :wat::holon::HolonAST) (:exp::thought-rsi-70-3)))
    (:wat::test::assert-coincident a-key b-key)))


;; ════════════════════════════════════════════════════════════════
;;  T3 — Near-equivalent thought hits terminal-cache via coincident?
;; ════════════════════════════════════════════════════════════════
;;
;; THE LOAD-BEARING TEST. Walker A walks rsi=70.0; terminal-cache
;; fills. Walker B asks about rsi=70.3 — different bytes (different
;; Thermometer value); the cache uses coincident? per arc 023 +
;; arc 017 to match against the stored entry. If T3a passes (the
;; substrate's coincident? returns true on the pair), T3 should
;; pass by transitivity.

(:deftest :exp::t3-near-equivalent-hits-fuzzy
  (:wat::core::let*
    (((a-thought-h :wat::holon::HolonAST) (:exp::thought-rsi-70))
     ((rA :(wat::holon::HolonAST,exp::L1Tier))
      (:exp::walk-and-record a-thought-h (:exp::tier-empty)))
     ((tier :exp::L1Tier) (:wat::core::second rA))

     ;; Query with a different RSI value, structurally identical.
     ((b-key :wat::holon::HolonAST) (:exp::thought-rsi-70-3))

     ((found :Option<wat::holon::HolonAST>)
       (:exp::cache-lookup (:exp::L1Tier/terminal-cache tier) b-key)))
    (:wat::core::match found -> :()
      ((Some v) (:wat::test::assert-coincident v a-thought-h))
      (:None    (:wat::test::assert-eq :cache-empty :cache-had-entry)))))


;; ════════════════════════════════════════════════════════════════
;;  T4 — Distant thought misses — locality is bounded
;; ════════════════════════════════════════════════════════════════
;;
;; rsi=30.0 vs rsi=70.0: delta=40 over R=100 = 40% of range.
;; cos = 1 - 0.8 = 0.20. Way outside the d=10000 sigma=1 floor
;; (cos > 0.99 needed). NOT coincident. Cache correctly misses.

(:deftest :exp::t4-distant-thought-misses
  (:wat::core::let*
    (((a-thought-h :wat::holon::HolonAST) (:exp::thought-rsi-70))
     ((rA :(wat::holon::HolonAST,exp::L1Tier))
      (:exp::walk-and-record a-thought-h (:exp::tier-empty)))
     ((tier :exp::L1Tier) (:wat::core::second rA))

     ((c-key :wat::holon::HolonAST) (:exp::thought-rsi-30))

     ((term-miss :bool)
       (:exp::is-none-h
         (:exp::cache-lookup (:exp::L1Tier/terminal-cache tier) c-key))))
    (:wat::test::assert-eq term-miss true)))


;; ════════════════════════════════════════════════════════════════
;;  T5 — Cache fills without neighborhood interference
;; ════════════════════════════════════════════════════════════════
;;
;; The substrate's algebra grid hosts ~sqrt(d) distinguishable
;; neighborhoods at d=10000. Populate 20 entries at well-separated
;; RSI values (5 apart, from 5.0 to 100.0). Each entry's lookup
;; answers correctly without false positives from neighbors.

(:deftest :exp::t5-fills-without-interference
  (:wat::core::let*
    (((c0 :exp::CoordinateCache) (:exp::cache-empty))

     ;; Populate 20 entries at well-separated RSIs (5.0, 10.0,
     ;; 15.0, ...). Neighbor distance = 5; well outside the 0.5
     ;; coincident floor at R=100, sigma=1.
     ((c1 :exp::CoordinateCache)
       (:wat::core::foldl (:wat::core::range 1 21) c0
         (:wat::core::lambda
           ((acc :exp::CoordinateCache) (i :i64) -> :exp::CoordinateCache)
           (:wat::core::let*
             (((v :f64)
               (:wat::core::i64::to-f64 (:wat::core::i64::* i 5)))
              ((form-h :wat::holon::HolonAST)
                (:wat::holon::Bind
                  (:wat::holon::Atom "rsi-thought")
                  (:wat::holon::Thermometer v 0.0 100.0)))
              ((value-h :wat::holon::HolonAST) (:wat::holon::leaf i)))
             (:exp::cache-record acc form-h value-h)))))

     ;; Query for the entry at v = 50.0 (i=10).
     ((query :wat::holon::HolonAST)
       (:wat::holon::Bind
         (:wat::holon::Atom "rsi-thought")
         (:wat::holon::Thermometer 50.0 0.0 100.0)))
     ((found :Option<wat::holon::HolonAST>)
       (:exp::cache-lookup c1 query))
     ((expected :wat::holon::HolonAST) (:wat::holon::leaf 10)))
    (:wat::core::match found -> :()
      ((Some v) (:wat::test::assert-coincident v expected))
      (:None    (:wat::test::assert-eq :cache-empty :cache-had-entry)))))


;; ════════════════════════════════════════════════════════════════
;;  T6 — next-cache fuzzy capability (architectural completeness)
;; ════════════════════════════════════════════════════════════════
;;
;; Trader-shape thoughts are typically single-step (eval-step!
;; returns StepTerminal in one rewrite), so next-cache stays
;; empty for them. But the architecture provides next-cache for
;; multi-step computations. This test verifies next-cache uses
;; the SAME fuzzy lookup mechanism as terminal-cache:
;;
;; - Directly populate next-cache with one entry.
;; - The KEY is a thought (Thermometer-wrapped Bind).
;; - The VALUE is some next-form HolonAST.
;; - Query a near-equivalent thought.
;; - The fuzzy lookup hits via coincident?.
;;
;; The trader's typical workload may not exercise this code path
;; often — but the architecture is the same primitive, used the
;; same way, regardless of which store is asking.

(:deftest :exp::t6-next-cache-uses-same-fuzzy-mechanism
  (:wat::core::let*
    (;; Directly construct a (key, value) for next-cache.
     ((key-h :wat::holon::HolonAST)
       (:wat::holon::Bind
         (:wat::holon::Atom "rsi-thought")
         (:wat::holon::Thermometer 70.0 0.0 100.0)))
     ((next-form-h :wat::holon::HolonAST)
       (:wat::holon::Atom "some-next-form-placeholder"))

     ;; Populate next-cache directly.
     ((c0 :exp::CoordinateCache) (:exp::cache-empty))
     ((c1 :exp::CoordinateCache)
       (:exp::cache-record c0 key-h next-form-h))

     ;; Query a near-equivalent thought.
     ((query :wat::holon::HolonAST)
       (:wat::holon::Bind
         (:wat::holon::Atom "rsi-thought")
         (:wat::holon::Thermometer 70.3 0.0 100.0)))
     ((found :Option<wat::holon::HolonAST>)
       (:exp::cache-lookup c1 query)))
    (:wat::core::match found -> :()
      ((Some v) (:wat::test::assert-coincident v next-form-h))
      (:None    (:wat::test::assert-eq :cache-empty :cache-had-entry)))))
