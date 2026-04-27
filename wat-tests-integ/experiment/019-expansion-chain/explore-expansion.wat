;; wat-tests-integ/experiment/019-expansion-chain/explore-expansion.wat
;;
;; Expansion chain — proof 015.
;;
;; Builder framing (2026-04-26):
;;
;;   "we have stated in the book many times... two kinds of lookup
;;    structures... 'does this form terminate' and 'what is this
;;    form's terminal value' — both of these require the recursive
;;    expansion...
;;
;;    as we hit intermediary forms.. we remember their terminal
;;    state and their terminal value.. but we can't know the
;;    terminal value until its recursive expansion completes... so
;;    we can be in a state where the next form is known /but the
;;    terminal value isn't/"
;;
;; This is the foundational substrate model: a surface form's
;; expansion is a linked list through the recursive vector space,
;; where each intermediary form points at its next form. The
;; chain terminates at a primitive value. Two distinct lookup
;; structures coexist: "what's next?" (a cheap chain step) and
;; "what's the terminal?" (the answer, only knowable post-expansion).
;;
;; The intermediate state — next known, terminal not — is the
;; load-bearing observation. It's how memoization actually works
;; in Scheme, Common Lisp, Clojure: terminal values backfill
;; bottom-up after recursive expansion completes.
;;
;; ─── Two distinct lookup primitives ──────────────────────────
;;
;; lookup-next(state, form)     → :Option<HolonAST>  ; the next-step
;; lookup-terminal(state, form) → :Option<HolonAST>  ; the answer
;;
;; They evolve INDEPENDENTLY as evaluation progresses:
;;
;;   Phase 1 (forward expansion):
;;     - record-next(form_0, form_1)  → next-cache grows
;;     - record-next(form_1, form_2)  → next-cache grows
;;     - ...
;;     - At this state: lookup-next has answers; lookup-terminal still None.
;;
;;   Phase 2 (terminal recognition):
;;     - form_n is a primitive (terminal). Record terminal(form_n) = form_n.
;;
;;   Phase 3 (terminal backpropagation):
;;     - For each form in the chain, record terminal = the chain's terminal.
;;     - Now lookup-terminal is O(1) for any form in the chain.
;;
;; ─── Tests ────────────────────────────────────────────────────
;;
;; T1  Empty cache: both lookups return :None for any form.
;; T2  Phase 1 — one step recorded: lookup-next has answer,
;;     lookup-terminal still :None. THE INTERMEDIATE STATE.
;; T3  Phase 1 fully: 3-step chain in next-cache; all forms have
;;     next; no forms have terminal.
;; T4  Phase 2 — record terminal for the leaf form; only that
;;     form has terminal; chain interior still :None.
;; T5  Phase 3 — backpropagate terminal up the chain; all forms
;;     have terminal; lookup-terminal is now O(1).
;; T6  Two independent chains in one cache — no interference.

(:wat::test::make-deftest :deftest
  (;; ─── Form-key helper ─────────────────────────────────────
   ;;
   ;; HashMap requires String keys; encode each form to its hex
   ;; representation as the cache key. Same as proof 005's
   ;; Registry pattern.
   (:wat::core::define
     (:exp::form-key (form :wat::holon::HolonAST) -> :String)
     (:wat::core::Bytes::to-hex
       (:wat::holon::vector-bytes (:wat::holon::encode form))))


   ;; ─── ComputeState — the two-cache substrate model ───────
   ;;
   ;; Two HashMaps living in one struct. Lookups are independent;
   ;; updates to one don't touch the other. The "intermediate
   ;; state" is observable by querying both and getting Some/None
   ;; or None/None.
   (:wat::core::struct :exp::ComputeState
     (next-cache :HashMap<String,wat::holon::HolonAST>)
     (terminal-cache :HashMap<String,wat::holon::HolonAST>))

   (:wat::core::define
     (:exp::compute-state-empty -> :exp::ComputeState)
     (:exp::ComputeState/new
       (:wat::core::HashMap :(String,wat::holon::HolonAST))
       (:wat::core::HashMap :(String,wat::holon::HolonAST))))


   ;; ─── Phase 1 op: record a next-step (form → next-form) ──
   ;;
   ;; The chain's forward link. Says "after evaluating form one
   ;; step, you get next." Doesn't say what the terminal is.
   (:wat::core::define
     (:exp::record-next
       (state :exp::ComputeState)
       (form :wat::holon::HolonAST)
       (next :wat::holon::HolonAST)
       -> :exp::ComputeState)
     (:exp::ComputeState/new
       (:wat::core::assoc (:exp::ComputeState/next-cache state)
                          (:exp::form-key form)
                          next)
       (:exp::ComputeState/terminal-cache state)))


   ;; ─── Phase 2/3 op: record a terminal value for a form ───
   ;;
   ;; The answer cache. Once we know form's recursive expansion
   ;; reaches `terminal`, we record it. Subsequent queries are
   ;; O(1) regardless of chain length.
   (:wat::core::define
     (:exp::record-terminal
       (state :exp::ComputeState)
       (form :wat::holon::HolonAST)
       (terminal :wat::holon::HolonAST)
       -> :exp::ComputeState)
     (:exp::ComputeState/new
       (:exp::ComputeState/next-cache state)
       (:wat::core::assoc (:exp::ComputeState/terminal-cache state)
                          (:exp::form-key form)
                          terminal)))


   ;; ─── The two lookup primitives ──────────────────────────
   (:wat::core::define
     (:exp::lookup-next
       (state :exp::ComputeState)
       (form :wat::holon::HolonAST)
       -> :Option<wat::holon::HolonAST>)
     (:wat::core::get (:exp::ComputeState/next-cache state)
                      (:exp::form-key form)))

   (:wat::core::define
     (:exp::lookup-terminal
       (state :exp::ComputeState)
       (form :wat::holon::HolonAST)
       -> :Option<wat::holon::HolonAST>)
     (:wat::core::get (:exp::ComputeState/terminal-cache state)
                      (:exp::form-key form)))


   ;; ─── Helper predicates ──────────────────────────────────
   (:wat::core::define
     (:exp::is-some (o :Option<wat::holon::HolonAST>) -> :bool)
     (:wat::core::match o -> :bool ((Some _) true) (:None false)))

   (:wat::core::define
     (:exp::is-none (o :Option<wat::holon::HolonAST>) -> :bool)
     (:wat::core::match o -> :bool ((Some _) false) (:None true)))


   ;; ─── Test fixtures: a 3-step expansion chain ────────────
   ;;
   ;; Models the canonical example: (double 5) → (* 5 5) → 25.
   ;; Each form is a distinct HolonAST. The chain terminates at
   ;; the primitive 25 (an i64 leaf).
   (:wat::core::define
     (:exp::form-0 -> :wat::holon::HolonAST)
     (:wat::holon::Bind (:wat::holon::Atom "double") (:wat::holon::leaf 5)))

   (:wat::core::define
     (:exp::form-1 -> :wat::holon::HolonAST)
     (:wat::holon::Bind (:wat::holon::Atom "multiply")
       (:wat::holon::Bind (:wat::holon::leaf 5) (:wat::holon::leaf 5))))

   (:wat::core::define
     (:exp::form-2-terminal -> :wat::holon::HolonAST)
     (:wat::holon::leaf 25))


   ;; Independent chain for T6: (square 3) → (* 3 3) → 9
   (:wat::core::define
     (:exp::other-form-0 -> :wat::holon::HolonAST)
     (:wat::holon::Bind (:wat::holon::Atom "square") (:wat::holon::leaf 3)))

   (:wat::core::define
     (:exp::other-form-1 -> :wat::holon::HolonAST)
     (:wat::holon::Bind (:wat::holon::Atom "multiply")
       (:wat::holon::Bind (:wat::holon::leaf 3) (:wat::holon::leaf 3))))

   (:wat::core::define
     (:exp::other-form-2-terminal -> :wat::holon::HolonAST)
     (:wat::holon::leaf 9))))


;; ════════════════════════════════════════════════════════════════
;;  T1 — Empty cache: both lookups return :None
;; ════════════════════════════════════════════════════════════════
;;
;; Sanity check. A fresh ComputeState has no entries; lookup-next
;; and lookup-terminal both return :None for any form. The substrate
;; doesn't fabricate cached values.

(:deftest :exp::t1-empty-cache-both-none
  (:wat::core::let*
    (((state :exp::ComputeState) (:exp::compute-state-empty))
     ((next-result :Option<wat::holon::HolonAST>)
      (:exp::lookup-next state (:exp::form-0)))
     ((terminal-result :Option<wat::holon::HolonAST>)
      (:exp::lookup-terminal state (:exp::form-0)))
     ((_n :()) (:wat::test::assert-eq (:exp::is-none next-result) true)))
    (:wat::test::assert-eq (:exp::is-none terminal-result) true)))


;; ════════════════════════════════════════════════════════════════
;;  T2 — THE INTERMEDIATE STATE: next known, terminal not
;; ════════════════════════════════════════════════════════════════
;;
;; The load-bearing observation. After Phase 1's first
;; record-next, lookup-next has an answer for form_0 — but
;; lookup-terminal still returns :None because the recursive
;; expansion hasn't completed yet.
;;
;; This state is REAL and OBSERVABLE. The substrate models it
;; explicitly. Memoization in Scheme, CL, Clojure all pass
;; through this state; the substrate names it as a first-class
;; query distinction.

(:deftest :exp::t2-intermediate-state-next-known-terminal-not
  (:wat::core::let*
    (((state :exp::ComputeState) (:exp::compute-state-empty))
     ;; Phase 1: record one expansion step.
     ((state-1 :exp::ComputeState)
      (:exp::record-next state (:exp::form-0) (:exp::form-1)))

     ;; Two queries for the same form.
     ((next-result :Option<wat::holon::HolonAST>)
      (:exp::lookup-next state-1 (:exp::form-0)))
     ((terminal-result :Option<wat::holon::HolonAST>)
      (:exp::lookup-terminal state-1 (:exp::form-0)))

     ;; Next IS known. Terminal is NOT.
     ((_n :()) (:wat::test::assert-eq (:exp::is-some next-result) true)))
    (:wat::test::assert-eq (:exp::is-none terminal-result) true)))


;; ════════════════════════════════════════════════════════════════
;;  T3 — Phase 1 fully: chain known, no terminals yet
;; ════════════════════════════════════════════════════════════════
;;
;; Record all next-steps for the 3-form chain. Each form has its
;; next pointer in the cache. None has a terminal recorded.
;; The full chain is walkable forward; terminal answers still
;; require expansion.

(:deftest :exp::t3-full-chain-no-terminals
  (:wat::core::let*
    (((state :exp::ComputeState) (:exp::compute-state-empty))
     ((state-1 :exp::ComputeState)
      (:exp::record-next state (:exp::form-0) (:exp::form-1)))
     ((state-2 :exp::ComputeState)
      (:exp::record-next state-1 (:exp::form-1) (:exp::form-2-terminal)))

     ;; All next pointers known.
     ((next-0 :bool) (:exp::is-some (:exp::lookup-next state-2 (:exp::form-0))))
     ((next-1 :bool) (:exp::is-some (:exp::lookup-next state-2 (:exp::form-1))))

     ;; No terminals yet.
     ((term-0 :bool) (:exp::is-none (:exp::lookup-terminal state-2 (:exp::form-0))))
     ((term-1 :bool) (:exp::is-none (:exp::lookup-terminal state-2 (:exp::form-1))))
     ((term-2 :bool) (:exp::is-none (:exp::lookup-terminal state-2 (:exp::form-2-terminal))))

     ((_n0 :()) (:wat::test::assert-eq next-0 true))
     ((_n1 :()) (:wat::test::assert-eq next-1 true))
     ((_t0 :()) (:wat::test::assert-eq term-0 true))
     ((_t1 :()) (:wat::test::assert-eq term-1 true)))
    (:wat::test::assert-eq term-2 true)))


;; ════════════════════════════════════════════════════════════════
;;  T4 — Phase 2: terminal recognized at the leaf
;; ════════════════════════════════════════════════════════════════
;;
;; The expansion reaches a primitive — form_2 is a leaf. We
;; record terminal(form_2) = form_2. Only the leaf has a
;; terminal recorded; the interior of the chain still doesn't.
;; The model captures the moment of "we just learned the answer
;; for this one form, but haven't propagated it yet."

(:deftest :exp::t4-leaf-terminal-recognized-interior-still-unknown
  (:wat::core::let*
    (((state :exp::ComputeState) (:exp::compute-state-empty))
     ((state-1 :exp::ComputeState)
      (:exp::record-next state (:exp::form-0) (:exp::form-1)))
     ((state-2 :exp::ComputeState)
      (:exp::record-next state-1 (:exp::form-1) (:exp::form-2-terminal)))

     ;; Phase 2: leaf terminal recognized.
     ((state-3 :exp::ComputeState)
      (:exp::record-terminal state-2 (:exp::form-2-terminal) (:exp::form-2-terminal)))

     ;; Leaf has terminal.
     ((leaf-has-terminal :bool)
      (:exp::is-some (:exp::lookup-terminal state-3 (:exp::form-2-terminal))))

     ;; Interior of chain still doesn't.
     ((interior-1-has-terminal :bool)
      (:exp::is-some (:exp::lookup-terminal state-3 (:exp::form-1))))
     ((interior-0-has-terminal :bool)
      (:exp::is-some (:exp::lookup-terminal state-3 (:exp::form-0))))

     ((_l :()) (:wat::test::assert-eq leaf-has-terminal true))
     ((_i1 :()) (:wat::test::assert-eq interior-1-has-terminal false)))
    (:wat::test::assert-eq interior-0-has-terminal false)))


;; ════════════════════════════════════════════════════════════════
;;  T5 — Phase 3: terminal backpropagated; all forms O(1)
;; ════════════════════════════════════════════════════════════════
;;
;; Backpropagate the terminal up the chain. Now lookup-terminal
;; returns Some(value) for every form in the chain. This is the
;; memoization-complete state — any future query for any form
;; is O(1) instead of requiring chain walk.
;;
;; The substrate's two queries diverged in T2 (next had answer,
;; terminal didn't). They re-converge here as the memoization
;; completes. The model captures both phases honestly.

(:deftest :exp::t5-terminals-backpropagated-all-O-of-1
  (:wat::core::let*
    (((state :exp::ComputeState) (:exp::compute-state-empty))
     ((state-1 :exp::ComputeState)
      (:exp::record-next state (:exp::form-0) (:exp::form-1)))
     ((state-2 :exp::ComputeState)
      (:exp::record-next state-1 (:exp::form-1) (:exp::form-2-terminal)))
     ((state-3 :exp::ComputeState)
      (:exp::record-terminal state-2 (:exp::form-2-terminal) (:exp::form-2-terminal)))

     ;; Phase 3: backpropagate.
     ((state-4 :exp::ComputeState)
      (:exp::record-terminal state-3 (:exp::form-1) (:exp::form-2-terminal)))
     ((state-5 :exp::ComputeState)
      (:exp::record-terminal state-4 (:exp::form-0) (:exp::form-2-terminal)))

     ;; ALL forms have terminal recorded now.
     ((t0 :bool) (:exp::is-some (:exp::lookup-terminal state-5 (:exp::form-0))))
     ((t1 :bool) (:exp::is-some (:exp::lookup-terminal state-5 (:exp::form-1))))
     ((t2 :bool) (:exp::is-some (:exp::lookup-terminal state-5 (:exp::form-2-terminal))))

     ;; Next pointers also still recorded (orthogonal cache state).
     ((n0 :bool) (:exp::is-some (:exp::lookup-next state-5 (:exp::form-0))))
     ((n1 :bool) (:exp::is-some (:exp::lookup-next state-5 (:exp::form-1))))

     ((_t0 :()) (:wat::test::assert-eq t0 true))
     ((_t1 :()) (:wat::test::assert-eq t1 true))
     ((_t2 :()) (:wat::test::assert-eq t2 true))
     ((_n0 :()) (:wat::test::assert-eq n0 true)))
    (:wat::test::assert-eq n1 true)))


;; ════════════════════════════════════════════════════════════════
;;  T6 — Two independent chains coexist; no interference
;; ════════════════════════════════════════════════════════════════
;;
;; Add (square 3) → (* 3 3) → 9 alongside (double 5) → (* 5 5) → 25
;; in the same ComputeState. Verify both chains are reachable;
;; their terminals are distinct; no cross-contamination.
;;
;; This is the substrate's "many computations cached side-by-side"
;; story made operational. Real systems will accumulate many
;; (form → next, form → terminal) pairs; the two-cache model
;; supports this trivially.

(:deftest :exp::t6-two-chains-no-interference
  (:wat::core::let*
    (;; Build state with chain A fully memoized.
     ((s-a-0 :exp::ComputeState) (:exp::compute-state-empty))
     ((s-a-1 :exp::ComputeState)
      (:exp::record-next s-a-0 (:exp::form-0) (:exp::form-1)))
     ((s-a-2 :exp::ComputeState)
      (:exp::record-next s-a-1 (:exp::form-1) (:exp::form-2-terminal)))
     ((s-a-3 :exp::ComputeState)
      (:exp::record-terminal s-a-2 (:exp::form-0) (:exp::form-2-terminal)))

     ;; Chain B added to same state.
     ((s-b-1 :exp::ComputeState)
      (:exp::record-next s-a-3 (:exp::other-form-0) (:exp::other-form-1)))
     ((s-b-2 :exp::ComputeState)
      (:exp::record-next s-b-1 (:exp::other-form-1) (:exp::other-form-2-terminal)))
     ((s-b-3 :exp::ComputeState)
      (:exp::record-terminal s-b-2 (:exp::other-form-0) (:exp::other-form-2-terminal)))

     ;; Each chain's terminal is independently retrievable.
     ((a-terminal :Option<wat::holon::HolonAST>)
      (:exp::lookup-terminal s-b-3 (:exp::form-0)))
     ((b-terminal :Option<wat::holon::HolonAST>)
      (:exp::lookup-terminal s-b-3 (:exp::other-form-0)))

     ((a-correct :bool)
       (:wat::core::match a-terminal -> :bool
         ((Some t) (:wat::holon::coincident? t (:exp::form-2-terminal)))
         (:None false)))
     ((b-correct :bool)
       (:wat::core::match b-terminal -> :bool
         ((Some t) (:wat::holon::coincident? t (:exp::other-form-2-terminal)))
         (:None false)))

     ;; Cross-check: form-0's terminal isn't 9; other-form-0's terminal isn't 25.
     ((a-not-b :bool)
       (:wat::core::match a-terminal -> :bool
         ((Some t) (:wat::core::not (:wat::holon::coincident? t (:exp::other-form-2-terminal))))
         (:None false)))

     ((_a :()) (:wat::test::assert-eq a-correct true))
     ((_b :()) (:wat::test::assert-eq b-correct true)))
    (:wat::test::assert-eq a-not-b true)))
