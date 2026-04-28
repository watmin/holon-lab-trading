;; :trading::cache::resolve — cache-aware walker (slice 1, minimal).
;;
;; Builds on `:trading::cache::L1/lookup` (pure cache traversal) by
;; falling back to `:wat::eval::walk` on cache miss. The visitor
;; passed to walk currently does NOTHING beyond returning Continue;
;; subsequent slices add recording into L1 so cache hits accumulate.
;;
;; Slice 1 ships the structural composition: cache-first, then walk.
;; The walk produces Some(terminal) on success, None on error. With
;; the no-op visitor, the cache stays empty after a walk — the next
;; resolve on the same form re-walks. The "fills the cache" property
;; lands in the next incremental slice.

;; Visit function for the walker. Top-level define so we can pass
;; by keyword path (matches the probe-022 pattern).
;;
;; Records each step into L1 and returns Continue:
;;   StepTerminal value     → record (form-h → value) in terminal-cache
;;   AlreadyTerminal value  → record (value → value) in terminal-cache (idempotent self-edge)
;;   StepNext next-form-w   → record (form-h → next-h) in next-cache
;;
;; Each match arm uses full variant paths
;; (`:wat::eval::StepResult::StepTerminal` etc.) — the substrate's
;; pattern matcher resolves bare names ambiguously when multiple
;; enums have similarly-named variants; full paths disambiguate.
;;
;; Pos is closed over at FIXED 50.0 for slice-1-minimal. Arc 070's
;; walker doesn't thread per-step pos; threading positional context
;; through the visitor lands in a follow-up arc when the trader
;; surfaces a need.
(:wat::core::define
  (:trading::cache::record-coordinate
    (acc :trading::cache::L1)
    (form-w :wat::WatAST)
    (step :wat::eval::StepResult)
    -> :wat::eval::WalkStep<trading::cache::L1>)
  (:wat::core::let*
    (((current-h :wat::holon::HolonAST)
      (:wat::holon::from-watast form-w)))
    (:wat::core::match step
      -> :wat::eval::WalkStep<trading::cache::L1>
      ((:wat::eval::StepResult::StepTerminal value)
        (:wat::core::let*
          (((_ :()) (:trading::cache::L1/put-terminal acc 50.0 current-h value)))
          (:wat::eval::WalkStep::Continue acc)))
      ((:wat::eval::StepResult::AlreadyTerminal value)
        (:wat::core::let*
          (((_ :()) (:trading::cache::L1/put-terminal acc 50.0 value value)))
          (:wat::eval::WalkStep::Continue acc)))
      ((:wat::eval::StepResult::StepNext next-form-w)
        (:wat::core::let*
          (((next-form-h :wat::holon::HolonAST)
            (:wat::holon::from-watast next-form-w))
           ((_ :()) (:trading::cache::L1/put-next acc 50.0 current-h next-form-h)))
          (:wat::eval::WalkStep::Continue acc))))))

(:wat::core::define
  (:trading::cache::resolve
    (form-h :wat::holon::HolonAST)
    (pos :f64)
    (l1 :trading::cache::L1)
    -> :Option<wat::holon::HolonAST>)
  (:wat::core::match
    (:trading::cache::L1/lookup l1 pos form-h)
    -> :Option<wat::holon::HolonAST>
    ((Some t) (Some t))
    (:None
      ;; Cache miss — invoke walk. Returns Result<(HolonAST, A),
      ;; EvalError>. Pull the terminal out of the Ok arm; map Err
      ;; to None.
      (:wat::core::match
        (:wat::eval::walk
          (:wat::holon::to-watast form-h)
          l1
          :trading::cache::record-coordinate)
        -> :Option<wat::holon::HolonAST>
        ((Ok pair) (Some (:wat::core::first pair)))
        ((Err _) :None)))))
