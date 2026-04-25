;; wat/sim/labels.wat — Continuous label coordinates (Chapters 56–57).
;;
;; Lab arc 025 slice 3 (2026-04-25). Two basis atoms (`outcome-axis`,
;; `direction-axis`) + a Thermometer-encoded label builder + four
;; corner reference labels.
;;
;; Per Chapter 57, labels are continuous positions in a 2D plane —
;; not discrete tokens. The 2×2 corner grid `(:Grace :Up)` etc. is
;; the four extreme `(±0.05, ±0.05)` vertices of a continuous space.
;; The substrate's Thermometer encoder smoothly interpolates positions
;; between corners; cosine reflects axis-decomposed similarity.
;;
;; Range `[-0.05, +0.05]` per DESIGN sub-fog 5h: 5-min BTC papers
;; rarely move >5% within a 1-day deadline; round-trip cost floor is
;; 0.7%, so the band gives ~10× the noise-floor resolution. If real
;; data shows the band is wrong, tighten — the simulator records
;; actual magnitudes from the first run, so the data exists to
;; revise from.
;;
;; ── Construction style ──
;; Style B per Chapter 56 (explicit axis-bindings) — the substrate
;; honors axis-decomposition queries via unbind. Style A (implicit
;; AST-as-label) would also work; B is more powerful for the
;; queries the future Predictor will care about ("how outcome-Grace-
;; ish is this surface, independent of direction?").
;;
;; ── Future cache-friendly form ──
;; `paper-label`'s Bundle could flow through the substrate's
;; termination cache (Chapter 55) once that wire-up ships. The shape
;; here doesn't change; the cache just observes more "this pattern
;; terminates" hits as labels accumulate.

;; Standalone-loadable: pull in our deps.
(:wat::load-file! "types.wat")


;; ─── force — local BundleResult unwrap ────────────────────────────
;;
;; `:wat::holon::Bundle` returns a `:wat::holon::BundleResult` —
;; `:Result<HolonAST, CapacityExceeded>`. At d=10000 with two axes
;; the error path is unreachable; we sentinel-fallback to a marker
;; atom so the function signature stays clean.
;;
;; PORTABILITY NOTE: this helper is generic — it takes any
;; `:wat::holon::BundleResult` and unwraps to `:wat::holon::HolonAST`.
;; If a second consumer materializes (e.g. a future `wat/sim/paper.wat`
;; that builds Bundle-shaped surfaces, or a treasury/broker module
;; doing the same), lift this define into a shared
;; `wat/sim/helpers.wat` (or `wat/helpers.wat` if it grows beyond the
;; sim subtree). No call-site change required — just the file path.
(:wat::core::define
  (:trading::sim::force
    (r :wat::holon::BundleResult)
    -> :wat::holon::HolonAST)
  (:wat::core::match r -> :wat::holon::HolonAST
    ((Ok h) h)
    ((Err _) (:wat::holon::Atom "_BUNDLE_ERROR_"))))


;; ─── Basis atoms — outcome-axis and direction-axis ────────────────
;;
;; Two named atoms span the 2D label space. Same role as Chapter 51's
;; `axis-x` / `axis-y` — different basis, different content.
(:wat::core::define
  (:trading::sim::outcome-axis -> :wat::holon::HolonAST)
  (:wat::holon::Atom (:wat::core::quote :outcome)))

(:wat::core::define
  (:trading::sim::direction-axis -> :wat::holon::HolonAST)
  (:wat::holon::Atom (:wat::core::quote :direction)))


;; ─── paper-label — continuous coordinate from (residue, price-move)
;;
;; Both axes Thermometer-encoded over `[-0.05, +0.05]`. Signed inputs:
;;   - residue   : +Grace, -Violence (per principal)
;;   - price-move: +Up, -Down ((final - entry) / entry)
;;
;; The result is a Bundle of two Bind(axis, Therm(value)). The
;; future Predictor's argmax-over-corner-references is a cosine
;; query against this label; a learned reckoner will accumulate
;; (surface, this-label) pairs and match continuous positions
;; directly.
(:wat::core::define
  (:trading::sim::paper-label
    (residue :f64)
    (price-move :f64)
    -> :wat::holon::HolonAST)
  (:trading::sim::force
    (:wat::holon::Bundle
      (:wat::core::vec :wat::holon::HolonAST
        (:wat::holon::Bind
          (:trading::sim::outcome-axis)
          (:wat::holon::Thermometer residue -0.05 0.05))
        (:wat::holon::Bind
          (:trading::sim::direction-axis)
          (:wat::holon::Thermometer price-move -0.05 0.05))))))


;; ─── Corner reference labels — the four (±0.05, ±0.05) vertices ──
;;
;; Hand-coded predictors in v1 cosine surfaces against these four
;; references for argmax classification. The reckoner-backed
;; successor learns from continuous labels directly; the corners
;; remain as named query targets ("is this surface most aligned with
;; Grace-Up?").
(:wat::core::define
  (:trading::sim::corner-grace-up -> :wat::holon::HolonAST)
  (:trading::sim::paper-label  0.05  0.05))

(:wat::core::define
  (:trading::sim::corner-grace-dn -> :wat::holon::HolonAST)
  (:trading::sim::paper-label  0.05 -0.05))

(:wat::core::define
  (:trading::sim::corner-violence-up -> :wat::holon::HolonAST)
  (:trading::sim::paper-label -0.05  0.05))

(:wat::core::define
  (:trading::sim::corner-violence-dn -> :wat::holon::HolonAST)
  (:trading::sim::paper-label -0.05 -0.05))
