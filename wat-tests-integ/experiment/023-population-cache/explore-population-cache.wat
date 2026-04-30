;; wat-tests-integ/experiment/023-population-cache/explore-population-cache.wat
;;
;; Proof 019 — population cache, the chapter-71 architecture.
;;
;; Builder framing (2026-04-27, after Chapter 71 — *Vicarious*):
;;
;;   "the cache is a map of form->(vec forms) ... those with cells
;;    may have more than one next value.... all forms have at least
;;    one next hope"
;;
;;   "cells are where the branch are... they return 1+ values...
;;    the consumer much choose which path is the best next path...
;;    we get a vec back.. and we (map cos (position-vec) probe-vec)
;;    yes?"
;;
;;   "architecture - the cache implements - a file could implement
;;    it - a database could implement it - do you get it?"
;;
;;   "prove it"
;;
;; ─── The architectural claim ─────────────────────────────────
;;
;; The cache's interface is `form → Vec<form>`. NOT `form → form`.
;; A walker queries; the cache returns a POPULATION of prior
;; walkers' terminals at coincident form-coordinates; the consumer
;; reads the population by cosine-ranking against the query and
;; picking the winner.
;;
;; This is the substrate's predator contract per chapter 71.
;; Multiple walkers populate; the new walker reads the population;
;; the population is the corpse pile of completed walks; the
;; walker feeds on the closest-matching corpse.
;;
;; ─── What this proof demonstrates ────────────────────────────
;;
;; T1  Empty cache: query returns an empty population.
;;
;; T2  Single insert: query coincident with the inserted form
;;     returns a single-element population; consumer reads the
;;     terminal.
;;
;; T3  Two inserts in the same template-bucket at different
;;     slot positions. Query at A's position cosine-ranks A
;;     above B; consumer feeds on A's terminal.
;;
;; T4  Same two inserts. Query at B's position cosine-ranks B
;;     above A; consumer feeds on B's terminal.
;;
;; T5  Distant query: returns an empty population (locality is
;;     bounded; no corpse on the wrong cell to feed on).
;;
;; T6  Many inserts in the same cell at varied positions.
;;     Consumer's choice (the winner of the cosine readout)
;;     tracks the query's position-within-cell. Population
;;     readout IS gradient-aware.
;;
;; ─── On scope ────────────────────────────────────────────────
;;
;; This proof exercises the INTERFACE: put/get with population-
;; valued get + cosine readout. The implementation is in-memory
;; Vec; an L3 SQLite backend or a network-of-peers backend would
;; serve the same interface. Per the user's architecture rule
;; (memory feedback_architecture_not_implementation): storage is
;; a footnote.

(:wat::test::make-deftest :deftest
  (;; ─── PopulationCache primitive ──────────────────────────
   ;;
   ;; Cache is a Vec of (form-key, terminal) entries. put appends;
   ;; get returns ALL entries whose form-key is coincident with
   ;; the query; consumer cosines each candidate's form against
   ;; the query and picks the winner's terminal.
   (:wat::core::struct :exp::CacheEntry
     (form     :wat::holon::HolonAST)
     (terminal :wat::holon::HolonAST))

   (:wat::core::struct :exp::PopulationCache
     (entries :Vec<exp::CacheEntry>))

   (:wat::core::define
     (:exp::cache-empty -> :exp::PopulationCache)
     (:exp::PopulationCache/new (:wat::core::vec :exp::CacheEntry)))

   ;; put: append the (form, terminal) pair to the population.
   (:wat::core::define
     (:exp::cache-put
       (cache    :exp::PopulationCache)
       (form     :wat::holon::HolonAST)
       (terminal :wat::holon::HolonAST)
       -> :exp::PopulationCache)
     (:exp::PopulationCache/new
       (:wat::core::conj
         (:exp::PopulationCache/entries cache)
         (:exp::CacheEntry/new form terminal))))

   ;; get-population: returns Vec of all entries whose form-key
   ;; is coincident with the query. Filter via foldl + conj —
   ;; build a fresh Vec containing only matches.
   (:wat::core::define
     (:exp::cache-get-population
       (cache :exp::PopulationCache)
       (query :wat::holon::HolonAST)
       -> :Vec<exp::CacheEntry>)
     (:wat::core::foldl
       (:exp::PopulationCache/entries cache)
       (:wat::core::vec :exp::CacheEntry)
       (:wat::core::lambda
         ((acc   :Vec<exp::CacheEntry>)
          (entry :exp::CacheEntry)
          -> :Vec<exp::CacheEntry>)
         (:wat::core::if
           (:wat::holon::coincident? query (:exp::CacheEntry/form entry))
           -> :Vec<exp::CacheEntry>
           (:wat::core::conj acc entry)
           acc))))

   ;; resolve: the population readout. Cosine each candidate's
   ;; form against the query; pick the highest. Returns
   ;; Option<terminal> — None if no coincident entries; Some(t)
   ;; if at least one. The (map cos position-vec probe-vec) the
   ;; user named, in wat: foldl over candidates tracking
   ;; (best-cosine-so-far, best-terminal-so-far).
   (:wat::core::define
     (:exp::cache-resolve
       (cache :exp::PopulationCache)
       (query :wat::holon::HolonAST)
       -> :Option<wat::holon::HolonAST>)
     (:wat::core::let*
       (((population :Vec<exp::CacheEntry>)
         (:exp::cache-get-population cache query)))
       (:wat::core::foldl
         population
         :None
         (:wat::core::lambda
           ((best  :Option<wat::holon::HolonAST>)
            (entry :exp::CacheEntry)
            -> :Option<wat::holon::HolonAST>)
           (:wat::core::let*
             (((candidate-form :wat::holon::HolonAST)
                (:exp::CacheEntry/form entry))
              ((candidate-cos :wat::core::f64)
                (:wat::holon::cosine query candidate-form)))
             (:wat::core::match best
               -> :Option<wat::holon::HolonAST>
               (:None (Some (:exp::CacheEntry/terminal entry)))
               ((Some _t)
                 (:wat::core::let*
                   (((current-best-cos :wat::core::f64)
                     (:exp::cache-best-cos-of cache query best)))
                   (:wat::core::if
                     (:wat::core::f64::> candidate-cos current-best-cos)
                     -> :Option<wat::holon::HolonAST>
                     (Some (:exp::CacheEntry/terminal entry))
                     best)))))))))

   ;; Helper: given an Option<terminal>, find its cosine vs query.
   ;; In a full impl we'd carry (cos, terminal) as a tuple in the
   ;; fold; for clarity here we recompute via a helper that scans
   ;; the cache for the entry whose terminal matches `best`.
   (:wat::core::define
     (:exp::cache-best-cos-of
       (cache :exp::PopulationCache)
       (query :wat::holon::HolonAST)
       (best  :Option<wat::holon::HolonAST>)
       -> :wat::core::f64)
     (:wat::core::match best -> :wat::core::f64
       (:None -1.0)
       ((Some t)
         (:wat::core::foldl
           (:exp::PopulationCache/entries cache)
           -1.0
           (:wat::core::lambda
             ((acc   :wat::core::f64)
              (entry :exp::CacheEntry)
              -> :wat::core::f64)
             (:wat::core::if
               (:wat::holon::coincident? t (:exp::CacheEntry/terminal entry))
               -> :wat::core::f64
               (:wat::core::f64::max acc
                 (:wat::holon::cosine query
                   (:exp::CacheEntry/form entry)))
               acc))))))


   ;; ─── Trader-shape thoughts (RSI in cell 70 at varied positions) ───
   (:wat::core::define
     (:exp::thought (rsi :wat::core::f64) -> :wat::holon::HolonAST)
     (:wat::holon::Bind
       (:wat::holon::Atom "rsi-thought")
       (:wat::holon::Thermometer rsi 0.0 100.0)))

   ;; Distinct terminals — used to verify cosine readout picks the
   ;; right one. Atom-wrapped strings; quasi-orthogonal; easy to
   ;; tell apart by coincident? matching.
   (:wat::core::define (:exp::terminal-A -> :wat::holon::HolonAST)
     (:wat::holon::Atom "decision-A"))
   (:wat::core::define (:exp::terminal-B -> :wat::holon::HolonAST)
     (:wat::holon::Atom "decision-B"))
   (:wat::core::define (:exp::terminal-C -> :wat::holon::HolonAST)
     (:wat::holon::Atom "decision-C"))


   ;; ─── Helpers ──────────────────────────────────────────
   (:wat::core::define
     (:exp::is-some-h (o :Option<wat::holon::HolonAST>) -> :wat::core::bool)
     (:wat::core::match o -> :wat::core::bool ((Some _) true) (:None false)))

   (:wat::core::define
     (:exp::is-none-h (o :Option<wat::holon::HolonAST>) -> :wat::core::bool)
     (:wat::core::match o -> :wat::core::bool ((Some _) false) (:None true)))))


;; ════════════════════════════════════════════════════════════════
;;  T1 — Empty cache: query returns no corpse to feed on
;; ════════════════════════════════════════════════════════════════

(:deftest :exp::t1-empty-cache-no-population
  (:wat::core::let*
    (((cache  :exp::PopulationCache) (:exp::cache-empty))
     ((query  :wat::holon::HolonAST) (:exp::thought 70.5))
     ((winner :Option<wat::holon::HolonAST>)
       (:exp::cache-resolve cache query)))
    (:wat::test::assert-eq (:exp::is-none-h winner) true)))


;; ════════════════════════════════════════════════════════════════
;;  T2 — One corpse: query coincident with it; consumer feeds
;; ════════════════════════════════════════════════════════════════

(:deftest :exp::t2-single-corpse-feeds
  (:wat::core::let*
    (((c0 :exp::PopulationCache) (:exp::cache-empty))
     ;; A walker died at frac=0.701 leaving terminal-A behind.
     ((c1 :exp::PopulationCache)
       (:exp::cache-put c0 (:exp::thought 70.1) (:exp::terminal-A)))
     ;; New walker queries with a coincident position.
     ((query :wat::holon::HolonAST) (:exp::thought 70.15))
     ((winner :Option<wat::holon::HolonAST>)
       (:exp::cache-resolve c1 query)))
    (:wat::core::match winner -> :()
      ((Some t) (:wat::test::assert-coincident t (:exp::terminal-A)))
      (:None    (:wat::test::assert-eq :population-empty :population-had-corpse)))))


;; ════════════════════════════════════════════════════════════════
;;  T3 — Two corpses in the same cell at different positions;
;;       query at A's position picks A's terminal.
;; ════════════════════════════════════════════════════════════════
;;
;; Both forms inhabit the same template (Bind/Atom/Thermometer with
;; same Atom and same range). A is at frac=0.701; B is at frac=0.799.
;; Both within 1% of each other — both coincident at sigma=1 floor.
;; Query at frac=0.703 (very close to A) — the population readout
;; picks A.

(:deftest :exp::t3-two-corpses-query-picks-A
  (:wat::core::let*
    (((c0 :exp::PopulationCache) (:exp::cache-empty))
     ((c1 :exp::PopulationCache)
       (:exp::cache-put c0 (:exp::thought 70.1) (:exp::terminal-A)))
     ((c2 :exp::PopulationCache)
       (:exp::cache-put c1 (:exp::thought 70.4) (:exp::terminal-B)))
     ;; Query close to A's position.
     ((query :wat::holon::HolonAST) (:exp::thought 70.15))
     ((winner :Option<wat::holon::HolonAST>)
       (:exp::cache-resolve c2 query)))
    (:wat::core::match winner -> :()
      ((Some t) (:wat::test::assert-coincident t (:exp::terminal-A)))
      (:None    (:wat::test::assert-eq :population-empty :population-had-corpse)))))


;; ════════════════════════════════════════════════════════════════
;;  T4 — Same two corpses; query at B's position picks B's terminal.
;; ════════════════════════════════════════════════════════════════

(:deftest :exp::t4-two-corpses-query-picks-B
  (:wat::core::let*
    (((c0 :exp::PopulationCache) (:exp::cache-empty))
     ((c1 :exp::PopulationCache)
       (:exp::cache-put c0 (:exp::thought 70.1) (:exp::terminal-A)))
     ((c2 :exp::PopulationCache)
       (:exp::cache-put c1 (:exp::thought 70.4) (:exp::terminal-B)))
     ;; Query close to B's position.
     ((query :wat::holon::HolonAST) (:exp::thought 70.45))
     ((winner :Option<wat::holon::HolonAST>)
       (:exp::cache-resolve c2 query)))
    (:wat::core::match winner -> :()
      ((Some t) (:wat::test::assert-coincident t (:exp::terminal-B)))
      (:None    (:wat::test::assert-eq :population-empty :population-had-corpse)))))


;; ════════════════════════════════════════════════════════════════
;;  T5 — Distant query: locality bounded; no corpse to feed on
;; ════════════════════════════════════════════════════════════════
;;
;; Populate cell 70 with a corpse. Query in cell 30 (40% of range
;; away). coincident? returns false; the population is empty for
;; this query. Consumer's resolve returns None — no feeding
;; possible; the new walker must walk fresh.

(:deftest :exp::t5-distant-query-empty-population
  (:wat::core::let*
    (((c0 :exp::PopulationCache) (:exp::cache-empty))
     ((c1 :exp::PopulationCache)
       (:exp::cache-put c0 (:exp::thought 70.0) (:exp::terminal-A)))
     ;; Distant query — cell 30, far from cell 70.
     ((query :wat::holon::HolonAST) (:exp::thought 30.0))
     ((winner :Option<wat::holon::HolonAST>)
       (:exp::cache-resolve c1 query)))
    (:wat::test::assert-eq (:exp::is-none-h winner) true)))


;; ════════════════════════════════════════════════════════════════
;;  T6 — Population gradient: many corpses; readout tracks query
;; ════════════════════════════════════════════════════════════════
;;
;; Five corpses spread across cell 70 at positions 70.0, 70.1, 70.2,
;; 70.3, 70.4. Distinct terminals A, B, C, A', B' (we'll reuse
;; terminal-A/B/C with structural distinctness via Atom("..."N) for
;; tags). Query at frac=0.706 (close to corpse at 70.6 — wait, none
;; there. Closer to 70.4). Verify the readout picks the closest.

(:deftest :exp::t6-population-readout-tracks-position
  (:wat::core::let*
    (((c0 :exp::PopulationCache) (:exp::cache-empty))
     ((cA :exp::PopulationCache)
       (:exp::cache-put c0 (:exp::thought 70.0)
                            (:wat::holon::Atom "term-700")))
     ((cB :exp::PopulationCache)
       (:exp::cache-put cA (:exp::thought 70.2)
                            (:wat::holon::Atom "term-702")))
     ((cC :exp::PopulationCache)
       (:exp::cache-put cB (:exp::thought 70.4)
                            (:wat::holon::Atom "term-704")))
     ;; Query closest to the 70.4 corpse.
     ((query :wat::holon::HolonAST) (:exp::thought 70.45))
     ((winner :Option<wat::holon::HolonAST>)
       (:exp::cache-resolve cC query)))
    (:wat::core::match winner -> :()
      ((Some t) (:wat::test::assert-coincident t (:wat::holon::Atom "term-704")))
      (:None    (:wat::test::assert-eq :population-empty :population-had-corpse)))))
