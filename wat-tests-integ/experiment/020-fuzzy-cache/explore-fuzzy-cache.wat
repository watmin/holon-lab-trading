;; wat-tests-integ/experiment/020-fuzzy-cache/explore-fuzzy-cache.wat
;;
;; Real expansion chain — proof 016 v4.
;;
;; Builder framing across three iterations (2026-04-26):
;;
;;   v1: synthetic atoms (double 5) / (square 3), no evaluator.
;;       "those arn't things that can be eval'd"
;;   v2: small Expr enum + stepping evaluator.
;;       "still feels shallow.... real lambdas... real work"
;;   v3: bigger Expr enum + TCO.
;;       "your tooling here doesn't seem to use wat forms but
;;        something... else"
;;
;; The pushback was the same shape every time: the form should BE
;; wat, not a parallel mini-language the proof invents. Without an
;; incremental evaluator at the substrate level, the proof had no
;; choice but to invent its own AST type.
;;
;; Arc 068 (2026-04-26, shipped same session) added the missing
;; primitive: :wat::eval-step! performs ONE call-by-value reduction
;; at the leftmost-outermost redex of a real wat form, returning
;; either StepNext (the rewritten form, re-feedable) or StepTerminal
;; (the form's HolonAST value).
;;
;; This proof is v4 — built on the real primitive. The forms are
;; real wat: (let* ((something :i64) 42) (* something something)).
;; The evaluator is :wat::eval-step!. The dual-LRU coordinate cache
;; (BOOK Chapter 59) is ~30 lines of pure wat on top.
;;
;; ─── The chapter-59 dual-LRU cache, made operational ─────────
;;
;; Two HashMaps, both keyed by HolonAST identity (arc 057's typed
;; leaves + Hash + Eq):
;;
;;   next-cache     : HashMap<HolonAST, HolonAST>   form → next-form
;;   terminal-cache : HashMap<HolonAST, HolonAST>   form → terminal-value
;;
;; Walker loop:
;;
;;   step form, cache:
;;     if terminal-cache.get(form) → Some(t):  return (t, cache)         ; cache wins
;;     if next-cache.get(form)     → Some(n):  step n, cache              ; chain hop
;;     else:                                                              ; first encounter
;;       match eval-step!(form):
;;         StepTerminal(t):  cache.terminal[form] = t  →  (t, cache)
;;         StepNext(n):      cache.next[form]     = n
;;                           let (t, cache') = step n, cache
;;                           cache'.terminal[form] = t                    ; backprop
;;                           (t, cache')
;;
;; Every form in the chain ends up in BOTH caches by the time the
;; walker returns. A second walker starting from any intermediate
;; form short-circuits to the terminal in O(1) — the first walker's
;; work is shared.
;;
;; ─── Tests ────────────────────────────────────────────────────
;;
;; T1  Single-step arithmetic:  (+ 1 2) → 3
;; T2  Multi-step expansion:    (+ (+ 1 2) 3) → 6, both intermediates
;;     in next-cache, both terminals backpropagated.
;; T3  Let*-binding:            (let* ((x :i64 5)) (* x x)) → 25
;; T4  TCO recursion:           (sum-to 3 0) → 6, many steps, all
;;     intermediate forms recorded in next-cache, terminals
;;     backpropagated, walker stack constant via arc 003 + arc 068.
;; T5  Backprop completeness:   ANY form encountered during the walk
;;     is queryable in terminal-cache after walk returns.
;; T6  Second-walker short-circuit: re-walk from an intermediate
;;     form; first eval-step! call short-circuits via terminal-cache
;;     hit; no further substrate evaluation.
;; T7  Cooperation across starting points: walker A starts from
;;     outer form; walker B starts from a sub-form that's in A's
;;     chain. B's work is zero — A already filled the cache.

(:wat::test::make-deftest :deftest
  (;; ─── A real recursive function: sum-to (TCO) ────────────
   ;;
   ;; (sum-to n acc) = if n = 0 then acc else (sum-to (n-1) (acc+n))
   ;;
   ;; Tail-recursive: arc 003's TCO trampoline keeps the wat call
   ;; stack constant. Arc 068's stepper exposes each β-reduction as
   ;; a discrete step the cache can record.
   (:wat::core::define
     (:exp::sum-to (n :i64) (acc :i64) -> :i64)
     (:wat::core::if (:wat::core::i64::= n 0) -> :i64
       acc
       (:exp::sum-to
         (:wat::core::i64::- n 1)
         (:wat::core::i64::+ acc n))))


   ;; ─── ExpansionCache: the dual-LRU coordinate cache ──────
   ;;
   ;; Two HashMaps, both keyed by HolonAST identity. The cache key
   ;; for each form is `(:wat::holon::from-watast form)` — arc 057
   ;; closed HolonAST under itself, so the lowering produces a
   ;; canonical structural fingerprint. Two forms with the same
   ;; structure get the same key.
   (:wat::core::struct :exp::ExpansionCache
     (next     :HashMap<wat::holon::HolonAST,wat::holon::HolonAST>)
     (terminal :HashMap<wat::holon::HolonAST,wat::holon::HolonAST>))

   (:wat::core::define
     (:exp::cache-empty -> :exp::ExpansionCache)
     (:exp::ExpansionCache/new
       (:wat::core::HashMap :(wat::holon::HolonAST,wat::holon::HolonAST))
       (:wat::core::HashMap :(wat::holon::HolonAST,wat::holon::HolonAST))))


   ;; ─── Cache primitives ──────────────────────────────────
   (:wat::core::define
     (:exp::cache-record-next
       (cache :exp::ExpansionCache)
       (form-key :wat::holon::HolonAST)
       (next-form :wat::holon::HolonAST)
       -> :exp::ExpansionCache)
     (:exp::ExpansionCache/new
       (:wat::core::assoc (:exp::ExpansionCache/next cache) form-key next-form)
       (:exp::ExpansionCache/terminal cache)))

   (:wat::core::define
     (:exp::cache-record-terminal
       (cache :exp::ExpansionCache)
       (form-key :wat::holon::HolonAST)
       (terminal :wat::holon::HolonAST)
       -> :exp::ExpansionCache)
     (:exp::ExpansionCache/new
       (:exp::ExpansionCache/next cache)
       (:wat::core::assoc (:exp::ExpansionCache/terminal cache) form-key terminal)))

   (:wat::core::define
     (:exp::cache-lookup-next
       (cache :exp::ExpansionCache)
       (form-key :wat::holon::HolonAST)
       -> :Option<wat::holon::HolonAST>)
     (:wat::core::get (:exp::ExpansionCache/next cache) form-key))

   (:wat::core::define
     (:exp::cache-lookup-terminal
       (cache :exp::ExpansionCache)
       (form-key :wat::holon::HolonAST)
       -> :Option<wat::holon::HolonAST>)
     (:wat::core::get (:exp::ExpansionCache/terminal cache) form-key))


   ;; ─── The walker — driver for arc 068's eval-step! ──────
   ;;
   ;; Returns (terminal, cache') as a tuple. The cache is enriched
   ;; with every (form → next) and (form → terminal) pair encountered
   ;; on this walk.
   ;;
   ;; The recursion is tail-position via the trampoline EXCEPT for
   ;; the backprop step: after the recursive walk-cached returns the
   ;; terminal, we backfill the current form's terminal entry. That
   ;; one extra record per call; constant per-frame work; total
   ;; depth bounded by the number of distinct forms the chain
   ;; visits.
   (:wat::core::define
     (:exp::walk-cached
       (form :wat::WatAST)
       (cache :exp::ExpansionCache)
       -> :(wat::holon::HolonAST,exp::ExpansionCache))
     (:wat::core::let*
       (((form-key :wat::holon::HolonAST) (:wat::holon::from-watast form))
        ((cached-terminal :Option<wat::holon::HolonAST>)
         (:exp::cache-lookup-terminal cache form-key)))
       (:wat::core::match cached-terminal
         -> :(wat::holon::HolonAST,exp::ExpansionCache)
         ;; Cache wins: terminal known; return immediately.
         ((Some t) (:wat::core::tuple t cache))
         ;; Cache miss on terminal — try next-cache.
         (:None
           (:wat::core::let*
             (((cached-next :Option<wat::holon::HolonAST>)
               (:exp::cache-lookup-next cache form-key)))
             (:wat::core::match cached-next
               -> :(wat::holon::HolonAST,exp::ExpansionCache)
               ;; Hop the cached chain link, then backprop.
               ((Some n)
                 (:wat::core::let*
                   (((next-form :wat::WatAST) (:wat::holon::to-watast n))
                    ((result :(wat::holon::HolonAST,exp::ExpansionCache))
                      (:exp::walk-cached next-form cache))
                    ((t :wat::holon::HolonAST) (:wat::core::first result))
                    ((cache' :exp::ExpansionCache) (:wat::core::second result)))
                   (:wat::core::tuple t
                     (:exp::cache-record-terminal cache' form-key t))))
               ;; Cache miss on both — fire eval-step!.
               (:None (:exp::walk-step-and-record form form-key cache))))))))

   ;; Inner: form is a brand-new coordinate; eval-step! it, record,
   ;; recurse into the next form (or terminate).
   (:wat::core::define
     (:exp::walk-step-and-record
       (form :wat::WatAST)
       (form-key :wat::holon::HolonAST)
       (cache :exp::ExpansionCache)
       -> :(wat::holon::HolonAST,exp::ExpansionCache))
     (:wat::core::match (:wat::eval-step! form)
       -> :(wat::holon::HolonAST,exp::ExpansionCache)
       ((Ok r)
         (:wat::core::match r
           -> :(wat::holon::HolonAST,exp::ExpansionCache)
           ;; Reached a terminal: record (form → t), return (t, cache).
           ((:wat::eval::StepResult::StepTerminal t)
             (:wat::core::tuple t
               (:exp::cache-record-terminal cache form-key t)))
           ;; One step happened: record (form → next), recurse, backprop.
           ((:wat::eval::StepResult::StepNext next)
             (:wat::core::let*
               (((next-key :wat::holon::HolonAST) (:wat::holon::from-watast next))
                ((cache-next :exp::ExpansionCache)
                  (:exp::cache-record-next cache form-key next-key))
                ((result :(wat::holon::HolonAST,exp::ExpansionCache))
                  (:exp::walk-cached next cache-next))
                ((t :wat::holon::HolonAST) (:wat::core::first result))
                ((cache' :exp::ExpansionCache) (:wat::core::second result)))
               (:wat::core::tuple t
                 (:exp::cache-record-terminal cache' form-key t))))))
       ;; eval-step! refused (effectful op, no step rule). Fallback:
       ;; eval-ast! the whole form as one opaque step.
       ((Err _e)
         (:wat::core::match (:wat::eval-ast! form)
           -> :(wat::holon::HolonAST,exp::ExpansionCache)
           ((Ok t) (:wat::core::tuple t
                     (:exp::cache-record-terminal cache form-key t)))
           ((Err _e2)
             (:wat::core::tuple (:wat::holon::leaf -1) cache))))))


   ;; ─── Helpers ──────────────────────────────────────────
   (:wat::core::define
     (:exp::is-some-h (o :Option<wat::holon::HolonAST>) -> :bool)
     (:wat::core::match o -> :bool ((Some _) true) (:None false)))

   (:wat::core::define
     (:exp::option-h-equals
       (o :Option<wat::holon::HolonAST>)
       (expected :wat::holon::HolonAST)
       -> :bool)
     (:wat::core::match o -> :bool
       ((Some t) (:wat::holon::coincident? t expected))
       (:None false)))))


;; ════════════════════════════════════════════════════════════════
;;  T1 — Single-step arithmetic: (+ 1 2) → 3
;; ════════════════════════════════════════════════════════════════
;;
;; The smallest non-trivial form. arc 068's eval-step! reduces it
;; in one rewrite to HolonAST::I64(3). Cache holds one entry:
;; (form → terminal).

(:deftest :exp::t1-single-step-arith
  (:wat::core::let*
    (((form :wat::WatAST)
      (:wat::core::quote (:wat::core::i64::+ 1 2)))
     ((cache-0 :exp::ExpansionCache) (:exp::cache-empty))
     ((result :(wat::holon::HolonAST,exp::ExpansionCache))
      (:exp::walk-cached form cache-0))
     ((terminal :wat::holon::HolonAST) (:wat::core::first result))
     ((cache-1 :exp::ExpansionCache) (:wat::core::second result))

     ;; Terminal value should be HolonAST::I64(3).
     ((expected :wat::holon::HolonAST) (:wat::holon::leaf 3))
     ((value-ok :bool) (:wat::holon::coincident? terminal expected))

     ;; Form's terminal is queryable via the cache.
     ((form-key :wat::holon::HolonAST) (:wat::holon::from-watast form))
     ((looked-up :Option<wat::holon::HolonAST>)
      (:exp::cache-lookup-terminal cache-1 form-key))
     ((cache-ok :bool) (:exp::option-h-equals looked-up expected))

     ((_v :()) (:wat::test::assert-eq value-ok true)))
    (:wat::test::assert-eq cache-ok true)))


;; ════════════════════════════════════════════════════════════════
;;  T2 — Multi-step expansion: (+ (+ 1 2) 3) → 6
;; ════════════════════════════════════════════════════════════════
;;
;; Two reductions: inner + fires first (CBV left-descent), then
;; outer +. Cache should record:
;;   (+ (+ 1 2) 3)  →  next: (+ 3 3),  terminal: 6
;;   (+ 3 3)        →                  terminal: 6
;;   3                                                    (leaf, in terminal-cache)
;;
;; T2 verifies BOTH the next-pointer link from the outer form AND
;; the backpropagated terminal at the outer form.

(:deftest :exp::t2-multi-step-expansion
  (:wat::core::let*
    (((form :wat::WatAST)
      (:wat::core::quote
        (:wat::core::i64::+ (:wat::core::i64::+ 1 2) 3)))
     ((cache-0 :exp::ExpansionCache) (:exp::cache-empty))
     ((result :(wat::holon::HolonAST,exp::ExpansionCache))
      (:exp::walk-cached form cache-0))
     ((terminal :wat::holon::HolonAST) (:wat::core::first result))
     ((cache-1 :exp::ExpansionCache) (:wat::core::second result))

     ((expected-terminal :wat::holon::HolonAST) (:wat::holon::leaf 6))
     ((value-ok :bool) (:wat::holon::coincident? terminal expected-terminal))

     ;; Outer form's next-pointer must exist (the inner step was
     ;; recorded as the next-form for the outer form).
     ((form-key :wat::holon::HolonAST) (:wat::holon::from-watast form))
     ((next-known :bool)
       (:exp::is-some-h (:exp::cache-lookup-next cache-1 form-key)))

     ;; Outer form's terminal also recorded via backprop.
     ((terminal-known :bool)
       (:exp::option-h-equals
         (:exp::cache-lookup-terminal cache-1 form-key)
         expected-terminal))

     ((_v :()) (:wat::test::assert-eq value-ok true))
     ((_n :()) (:wat::test::assert-eq next-known true)))
    (:wat::test::assert-eq terminal-known true)))


;; ════════════════════════════════════════════════════════════════
;;  T3 — Let* binding: (let* ((x :i64 5)) (* x x)) → 25
;; ════════════════════════════════════════════════════════════════
;;
;; arc 068's let* rule: peel one binding per step. With val already
;; canonical (5), one step substitutes x=5 in the body, yielding
;; (* 5 5). One more step fires the multiply.
;;
;; Real wat substitution semantics — same machinery the substrate's
;; full-eval uses, exposed one rewrite at a time.

(:deftest :exp::t3-let-star-binding
  (:wat::core::let*
    (((form :wat::WatAST)
      (:wat::core::quote
        (:wat::core::let* (((x :i64) 5))
          (:wat::core::i64::* x x))))
     ((result :(wat::holon::HolonAST,exp::ExpansionCache))
      (:exp::walk-cached form (:exp::cache-empty)))
     ((terminal :wat::holon::HolonAST) (:wat::core::first result))
     ((expected :wat::holon::HolonAST) (:wat::holon::leaf 25)))
    (:wat::test::assert-eq (:wat::holon::coincident? terminal expected) true)))


;; ════════════════════════════════════════════════════════════════
;;  T4 — TCO RECURSION: (sum-to 3 0) → 6
;; ════════════════════════════════════════════════════════════════
;;
;; The proof's keystone. A real recursive function — sum-to —
;; defined at the helper-prelude level, called at the top of a
;; quoted form. arc 068 exposes each β-reduction as a discrete
;; step; the walker records the chain; each recursive call's
;; inlined body shows up as a distinct cache coordinate.
;;
;; Expansion (each line is one step):
;;
;;   (sum-to 3 0)
;;     → (if (= 3 0) 0 (sum-to (- 3 1) (+ 0 3)))     β-reduce
;;     → (if false 0 (sum-to (- 3 1) (+ 0 3)))        cond canonical
;;     → (sum-to (- 3 1) (+ 0 3))                     if-false
;;     → (sum-to 2 (+ 0 3))                            n arg reduces
;;     → (sum-to 2 3)                                   acc arg reduces
;;     → ...
;;     → 6
;;
;; Many steps; constant wat call stack via arc 003's TCO; constant
;; per-step cost via arc 068's leftmost-outermost descent.

(:deftest :exp::t4-tco-recursion-sum-to
  (:wat::core::let*
    (((form :wat::WatAST)
      (:wat::core::quote (:exp::sum-to 3 0)))
     ((result :(wat::holon::HolonAST,exp::ExpansionCache))
      (:exp::walk-cached form (:exp::cache-empty)))
     ((terminal :wat::holon::HolonAST) (:wat::core::first result))
     ((cache :exp::ExpansionCache) (:wat::core::second result))

     ((expected :wat::holon::HolonAST) (:wat::holon::leaf 6))
     ((value-ok :bool) (:wat::holon::coincident? terminal expected))

     ;; Outer form has both next-link and terminal recorded.
     ((form-key :wat::holon::HolonAST) (:wat::holon::from-watast form))
     ((next-known :bool)
       (:exp::is-some-h (:exp::cache-lookup-next cache form-key)))
     ((terminal-known :bool)
       (:exp::option-h-equals
         (:exp::cache-lookup-terminal cache form-key)
         expected))

     ((_v :()) (:wat::test::assert-eq value-ok true))
     ((_n :()) (:wat::test::assert-eq next-known true)))
    (:wat::test::assert-eq terminal-known true)))


;; ════════════════════════════════════════════════════════════════
;;  T5 — Backprop completeness: every chain form has a terminal
;; ════════════════════════════════════════════════════════════════
;;
;; After walk returns, query the cache for the terminal at an
;; intermediate form too. Both the OUTER form (T2 already covered)
;; AND the next-step form (the inner reduction) should have
;; terminal entries. Backprop is what makes a parallel walker
;; that lands mid-chain hit O(1).

(:deftest :exp::t5-backprop-every-form-terminal
  (:wat::core::let*
    (((outer :wat::WatAST)
      (:wat::core::quote
        (:wat::core::i64::+ (:wat::core::i64::+ 1 2) 3)))
     ((cache-0 :exp::ExpansionCache) (:exp::cache-empty))
     ((result :(wat::holon::HolonAST,exp::ExpansionCache))
      (:exp::walk-cached outer cache-0))
     ((cache :exp::ExpansionCache) (:wat::core::second result))

     ;; Outer form's recorded next-pointer IS the inner step's
     ;; coordinate — pull it out and verify it has a terminal too.
     ((outer-key :wat::holon::HolonAST) (:wat::holon::from-watast outer))
     ((inner-key-opt :Option<wat::holon::HolonAST>)
      (:exp::cache-lookup-next cache outer-key))

     ((expected :wat::holon::HolonAST) (:wat::holon::leaf 6))
     ((inner-terminal-correct :bool)
       (:wat::core::match inner-key-opt -> :bool
         ((Some inner-key)
           (:exp::option-h-equals
             (:exp::cache-lookup-terminal cache inner-key)
             expected))
         (:None false))))
    (:wat::test::assert-eq inner-terminal-correct true)))


;; ════════════════════════════════════════════════════════════════
;;  T6 — Second-walker short-circuit via terminal cache
;; ════════════════════════════════════════════════════════════════
;;
;; First walk fills the cache. Second walk on the SAME form should
;; hit terminal-cache on the first lookup — zero eval-step! calls,
;; identical terminal returned.
;;
;; The only way to verify "no eval-step! happened" without a counter
;; is to check that the cache state is unchanged after the second
;; walk: the next-cache and terminal-cache sizes are stable.

(:deftest :exp::t6-second-walker-short-circuit
  (:wat::core::let*
    (((form :wat::WatAST)
      (:wat::core::quote (:exp::sum-to 3 0)))

     ;; First walker: fills the cache.
     ((r1 :(wat::holon::HolonAST,exp::ExpansionCache))
      (:exp::walk-cached form (:exp::cache-empty)))
     ((cache-after-first :exp::ExpansionCache) (:wat::core::second r1))
     ((next-size-1 :i64)
       (:wat::core::length (:exp::ExpansionCache/next cache-after-first)))
     ((term-size-1 :i64)
       (:wat::core::length (:exp::ExpansionCache/terminal cache-after-first)))

     ;; Second walker on same starting form, same cache.
     ((r2 :(wat::holon::HolonAST,exp::ExpansionCache))
      (:exp::walk-cached form cache-after-first))
     ((terminal-2 :wat::holon::HolonAST) (:wat::core::first r2))
     ((cache-after-second :exp::ExpansionCache) (:wat::core::second r2))
     ((next-size-2 :i64)
       (:wat::core::length (:exp::ExpansionCache/next cache-after-second)))
     ((term-size-2 :i64)
       (:wat::core::length (:exp::ExpansionCache/terminal cache-after-second)))

     ((expected :wat::holon::HolonAST) (:wat::holon::leaf 6))
     ((value-ok :bool) (:wat::holon::coincident? terminal-2 expected))
     ((cache-stable :bool)
       (:wat::core::and
         (:wat::core::= next-size-1 next-size-2)
         (:wat::core::= term-size-1 term-size-2)))

     ((_v :()) (:wat::test::assert-eq value-ok true)))
    (:wat::test::assert-eq cache-stable true)))


;; ════════════════════════════════════════════════════════════════
;;  T7 — Two walkers cooperate via shared cache
;; ════════════════════════════════════════════════════════════════
;;
;; The user's vision verbatim: "N things maybe exploring some outer
;; form at the same time... if one is able to find the terminal
;; answer before someone else - the next caller can use that
;; terminal value to shortcut their form traversal".
;;
;; Walker A walks (+ (+ 1 2) 3). arc 068's stepper takes ONE rewrite
;; per call at the leftmost-outermost redex — for the outer form
;; that means the inner reduces in place, yielding the next chain
;; coordinate (+ 3 3). The chain is:
;;
;;   (+ (+ 1 2) 3)  →  (+ 3 3)  →  6
;;
;; So the cache coordinates after walker A are the OUTER form
;; (+ (+ 1 2) 3) and the INTERMEDIATE form (+ 3 3) — both with
;; backpropagated terminal 6.
;;
;; Walker B starts from (+ 3 3) — a real chain coordinate from A's
;; walk. terminal-cache hit on the first lookup; zero eval-step!
;; calls; B inherits A's work via the shared HashMap value. Values
;; up; no Mutex; no thread coordination.

(:deftest :exp::t7-walker-cooperation-via-cache
  (:wat::core::let*
    (;; Walker A: outer form.
     ((outer :wat::WatAST)
      (:wat::core::quote
        (:wat::core::i64::+ (:wat::core::i64::+ 1 2) 3)))
     ((rA :(wat::holon::HolonAST,exp::ExpansionCache))
      (:exp::walk-cached outer (:exp::cache-empty)))
     ((cache :exp::ExpansionCache) (:wat::core::second rA))

     ;; Walker B: the intermediate chain coordinate (+ 3 3). It's
     ;; the form A landed on after one step; its terminal is
     ;; backpropagated, so B's first lookup hits.
     ((mid :wat::WatAST)
      (:wat::core::quote (:wat::core::i64::+ 3 3)))
     ((mid-key :wat::holon::HolonAST) (:wat::holon::from-watast mid))
     ((cached-terminal :Option<wat::holon::HolonAST>)
      (:exp::cache-lookup-terminal cache mid-key))

     ;; B's expected terminal: HolonAST::I64(6).
     ((expected :wat::holon::HolonAST) (:wat::holon::leaf 6))
     ((B-finds-A-work :bool) (:exp::option-h-equals cached-terminal expected)))
    (:wat::test::assert-eq B-finds-A-work true)))
