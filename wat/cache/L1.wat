;; :trading::cache::L1 — per-thinker dual coordinate cache.
;;
;; Two `:wat::holon::lru::HologramCache` instances threaded through the
;; thinker's tail-recursive loop:
;;
;;   next     — (form-h → next-h) edges of the rewrite chain
;;   terminal — (form-h → terminal-h) cached answers
;;
;; HologramCache is thread-owned mutable; the thinker holds the L1
;; struct directly. No Mutex, no queue, no service for L1 — the
;; whole point is hot-path locality. L2 (cross-thinker) is a
;; separate concern in `Service.wat`.
;;
;; Lifecycle: construct via `make` once at thinker startup; thread
;; through the loop; the inner HologramCaches mutate; the L1 struct
;; itself never changes.
;;
;; Arc 076 + 077: the program's encoding dim is ambient via
;; `(:wat::config::set-dim-count!)`; HologramCache/make reads it. Slot
;; routing is inferred from the form's structure (Thermometer inside
;; → bracket-pair lookup; non-therm → slot 0). No caller-supplied pos.
;; Each LRU is configured with the construction-time filter
;; (filter-coincident — strict, matches the cache's "did I see this
;; exact coordinate before" semantics).

(:wat::core::struct :trading::cache::L1
  (next :wat::holon::lru::HologramCache)
  (terminal :wat::holon::lru::HologramCache))

;; Construct an L1 cache pair with both HologramCaches sharing the
;; ambient program-d (capacity = floor(sqrt(dim-count))). `cap` is
;; the LRU global bound; a reasonable default at dim-count=10000 is
;; `cap = 10000` (~100 entries per slot).
(:wat::core::define
  (:trading::cache::L1/make
    (cap :wat::core::i64)
    -> :trading::cache::L1)
  (:trading::cache::L1/new
    (:wat::holon::lru::HologramCache/make (:wat::holon::filter-coincident) cap)
    (:wat::holon::lru::HologramCache/make (:wat::holon::filter-coincident) cap)))

;; ─── put helpers — record an edge or terminal in L1 ────────────────

;; Record `(form-h → next-h)` in the next-cache. Used by the cache-
;; aware walker (`:trading::cache::resolve`) when `:wat::eval-step!`
;; produces a Next value.
(:wat::core::define
  (:trading::cache::L1/put-next
    (l1 :trading::cache::L1)
    (form-h :wat::holon::HolonAST)
    (next-h :wat::holon::HolonAST)
    -> :())
  (:wat::holon::lru::HologramCache/put
    (:trading::cache::L1/next l1)
    form-h next-h))

;; Record `(form-h → terminal-h)` in the terminal-cache. Used when
;; the walker reaches a Terminal step or AlreadyTerminal step.
(:wat::core::define
  (:trading::cache::L1/put-terminal
    (l1 :trading::cache::L1)
    (form-h :wat::holon::HolonAST)
    (terminal-h :wat::holon::HolonAST)
    -> :())
  (:wat::holon::lru::HologramCache/put
    (:trading::cache::L1/terminal l1)
    form-h terminal-h))

;; ─── get helpers — fuzzy lookup with coincident-floor strictness ──
;;
;; Both caches use the construction-time coincidence filter — strict,
;; matching the substrate's `coincident?` semantics: only return a
;; hit when the candidate's cosine clears the coincident floor.

(:wat::core::define
  (:trading::cache::L1/get-terminal
    (l1 :trading::cache::L1)
    (probe :wat::holon::HolonAST)
    -> :Option<wat::holon::HolonAST>)
  (:wat::holon::lru::HologramCache/get
    (:trading::cache::L1/terminal l1) probe))

(:wat::core::define
  (:trading::cache::L1/get-next
    (l1 :trading::cache::L1)
    (probe :wat::holon::HolonAST)
    -> :Option<wat::holon::HolonAST>)
  (:wat::holon::lru::HologramCache/get
    (:trading::cache::L1/next l1) probe))

;; ─── len — total entries across both caches ──────────────────────
;;
;; Diagnostic / telemetry surface. Returns the sum of the two
;; HologramCaches' lens. The cache service's telemetry counters track
;; per-cache values; this is for whole-L1 size reporting.
(:wat::core::define
  (:trading::cache::L1/len
    (l1 :trading::cache::L1)
    -> :wat::core::i64)
  (:wat::core::i64::+
    (:wat::holon::lru::HologramCache/len (:trading::cache::L1/next l1))
    (:wat::holon::lru::HologramCache/len (:trading::cache::L1/terminal l1))))

;; ─── lookup — cache-only chain traversal ─────────────────────────
;;
;; Walks through the L1 caches WITHOUT invoking the substrate walker.
;; Three outcomes:
;;
;;   1. terminal-cache hit on form-h → return Some(terminal)
;;   2. next-cache hit on form-h → recurse on next-h
;;   3. neither → return None (caller decides what to do)
;;
;; This is the pure-cache primitive. The walker (a separate file
;; that also calls :wat::eval::walk on miss) composes lookup + walk.
;; Splitting the two pieces means we can test cache-traversal
;; semantics independent of the walker integration.
(:wat::core::define
  (:trading::cache::L1/lookup
    (l1 :trading::cache::L1)
    (form-h :wat::holon::HolonAST)
    -> :Option<wat::holon::HolonAST>)
  (:wat::core::match
    (:trading::cache::L1/get-terminal l1 form-h)
    -> :Option<wat::holon::HolonAST>
    ((Some t) (Some t))
    (:None
      (:wat::core::match
        (:trading::cache::L1/get-next l1 form-h)
        -> :Option<wat::holon::HolonAST>
        ((Some next-h) (:trading::cache::L1/lookup l1 next-h))
        (:None :None)))))
