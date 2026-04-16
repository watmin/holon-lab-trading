;; broker-thought.wat — the broker-observer's full composed thought.
;; One thought. One encode. One question: do I get out now?
;;
;; Four components bundled:
;; 1. Market indicator rhythms (from market observer, via position observer)
;; 2. Position regime rhythms (from position observer's lens)
;; 3. Portfolio anxiety (age spread, pressure, P&L, track record)
;; 4. Phase rhythm (bundled bigrams of trigrams)
;;
;; Everything is pre-computed rhythm vectors except the anxiety facts.

(define (broker-thought position-chain anxiety phase-rhythm)
  (bundle
    ;; ── 1. Market indicator rhythms (~15 vectors) ────────────────
    ;; Pre-computed by the market observer. Passed through the position
    ;; observer (possibly filtered by anomaly). Each one is the evolution
    ;; of one market indicator across the market observer's window.
    ;; See: market-observer-thought.wat
    position-chain.market-rhythms

    ;; ── 2. Position regime rhythms (~10-13 vectors) ──────────────
    ;; Pre-computed by the position observer. Each one is the evolution
    ;; of one regime indicator across the position observer's window.
    ;; See: position-core-thought.wat or position-full-thought.wat
    position-chain.regime-rhythms

    ;; ── 3. Portfolio anxiety (~11 facts) ─────────────────────────
    ;; The broker's self-awareness. Computed from active receipts.
    ;; These are scalars, not rhythms — the broker's portfolio state
    ;; at this moment.

    ;; Counts
    (bind (atom "active-positions")        (log 47.0))

    ;; Age distribution
    (bind (atom "avg-paper-age")           (log 145.0))
    (bind (atom "min-paper-age")           (log 12.0))
    (bind (atom "max-paper-age")           (log 380.0))

    ;; Time pressure
    (bind (atom "avg-time-pressure")       (linear 0.29 1.0))
    (bind (atom "max-time-pressure")       (linear 0.76 1.0))

    ;; Unrealized P&L
    (bind (atom "avg-unrealized-residue")  (linear -0.003 1.0))
    (bind (atom "min-unrealized-residue")  (linear -0.018 1.0))
    (bind (atom "max-unrealized-residue")  (linear 0.012 1.0))

    ;; Track record
    (bind (atom "grace-rate")              (linear 0.0 1.0))
    (bind (atom "trade-count")             (log 230.0))

    ;; ── 4. Phase rhythm (1 vector) ───────────────────────────────
    ;; Bundled bigrams of trigrams from the phase history.
    ;; See: bullish-momentum.wat, exhaustion-top.wat, etc.
    phase-rhythm))

;; Capacity at D=10,000 (budget: 100):
;;   ~15 market rhythms
;;   ~10-13 regime rhythms
;;   ~11 anxiety facts
;;   ~1 phase rhythm
;;   ─────────────────
;;   ~37-40 items. Well within budget.
;;
;; Each rhythm vector (market or regime) is already encoded —
;; it carries the full indicator evolution inside it. The broker
;; bundles pre-computed vectors with its own anxiety scalars.
;; One encode of the anxiety facts + one vector bundle operation.
;;
;; The gate reckoner cosines against this one vector.
;; Hold or Exit. The treasury judges the papers.
