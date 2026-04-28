;; :trading::cache::resolve — cache-aware walker (slice 1, minimal).
;;
;; Builds on `:trading::cache::L1/lookup` (pure cache traversal) by
;; falling back to `:wat::eval::walk` on cache miss. The visitor
;; passed to walk records each StepResult into L1 so subsequent
;; queries hit the cache.
;;
;; Arc 076 + 077: slot routing is inferred from the form's structure
;; (the substrate does it inside HologramLRU on every put / get); no
;; caller-supplied pos. The visitor records (form, value) pairs;
;; Hologram routes each one by inspecting the key.

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
          (((_ :()) (:trading::cache::L1/put-terminal acc current-h value)))
          (:wat::eval::WalkStep::Continue acc)))
      ((:wat::eval::StepResult::AlreadyTerminal value)
        (:wat::core::let*
          (((_ :()) (:trading::cache::L1/put-terminal acc value value)))
          (:wat::eval::WalkStep::Continue acc)))
      ((:wat::eval::StepResult::StepNext next-form-w)
        (:wat::core::let*
          (((next-form-h :wat::holon::HolonAST)
            (:wat::holon::from-watast next-form-w))
           ((_ :()) (:trading::cache::L1/put-next acc current-h next-form-h)))
          (:wat::eval::WalkStep::Continue acc))))))

(:wat::core::define
  (:trading::cache::resolve
    (form-h :wat::holon::HolonAST)
    (l1 :trading::cache::L1)
    -> :Option<wat::holon::HolonAST>)
  (:wat::core::match
    (:trading::cache::L1/lookup l1 form-h)
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
