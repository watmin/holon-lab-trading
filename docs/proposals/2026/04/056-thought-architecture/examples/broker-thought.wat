;; broker-thought.wat — the broker-observer's full composed thought.
;; One thought. One encode. One question: do I get out now?
;;
;; Four components:
;; 1. Market indicator rhythms (from market observer, via regime observer)
;; 2. Regime rhythms (from regime observer's lens)
;; 3. Broker's own portfolio rhythms (from its own internal window)
;; 4. Phase rhythm (bundled bigrams of trigrams)
;;
;; Everything is rhythms. No snapshots. The broker thinks in movies.

(define (broker-thought regime-chain broker-window phase-rhythm dims)
  (bundle
    ;; ── 1. Market indicator rhythms (~15 vectors) ────────────────
    ;; Pre-computed by the market observer. Each one is one indicator's
    ;; evolution across the market observer's window.
    (:market-rhythms regime-chain)

    ;; ── 2. Regime rhythms (~10-13 vectors) ──────────────
    ;; Pre-computed by the regime observer. Each one is one regime
    ;; indicator's evolution across the regime observer's window.
    (:regime-rhythms regime-chain)

    ;; ── 3. Broker's portfolio rhythms (~5 vectors) ───────────────
    ;; The broker keeps its own window of portfolio snapshots.
    ;; Each candle it computes a snapshot from active receipts and
    ;; pushes it. The rhythms capture how the portfolio state evolved.
    (indicator-rhythm broker-window "avg-paper-age"
      (lambda (s) (:avg-age s)) dims)
    (indicator-rhythm broker-window "avg-time-pressure"
      (lambda (s) (:avg-tp s)) dims)
    (indicator-rhythm broker-window "avg-unrealized-residue"
      (lambda (s) (:avg-unrealized s)) dims)
    (indicator-rhythm broker-window "grace-rate"
      (lambda (s) (:grace-rate s)) dims)
    (indicator-rhythm broker-window "active-positions"
      (lambda (s) (:active-count s)) dims)

    ;; ── 4. Phase rhythm (1 vector) ───────────────────────────────
    ;; Bundled bigrams of trigrams from the phase history.
    ;; See: bullish-momentum.wat, exhaustion-top.wat, etc.
    phase-rhythm))

;; The broker's portfolio snapshot — pushed to broker-window each candle:
(struct portfolio-snapshot
  avg-age avg-tp avg-unrealized grace-rate active-count)

;; Capacity at D=10,000 (budget: 100):
;;   ~15 market rhythms
;;   ~10-13 regime rhythms
;;   ~5 portfolio rhythms
;;   ~1 phase rhythm
;;   ─────────────────
;;   ~31-34 items. Comfortable headroom.
;;
;; Compare to the snapshot approach (~37-40 with 11 scalar facts).
;; Rhythms use fewer slots AND carry more information — the evolution,
;; not just the current value.
;;
;; The gate reckoner cosines against this one vector.
;; Hold or Exit. The treasury judges the papers.
