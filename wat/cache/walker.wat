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
;; by keyword path (matches the probe-022 pattern). No-op for
;; this slice: ignore step, return Continue with the same acc.
(:wat::core::define
  (:trading::cache::record-coordinate
    (acc :trading::cache::L1)
    (form-w :wat::WatAST)
    (step :wat::eval::StepResult)
    -> :wat::eval::WalkStep<trading::cache::L1>)
  (:wat::eval::WalkStep::Continue acc))

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
