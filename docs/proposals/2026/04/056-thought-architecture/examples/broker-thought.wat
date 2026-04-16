;; broker-thought.wat — the broker-observer's full composed thought.
;; One thought. One encode. One question: do I get out now?
;;
;; Four components:
;; 1. Market indicator rhythms (from market observer, via regime observer)
;; 2. Regime rhythms (from regime observer's lens)
;; 3. Broker's own portfolio rhythms (from its own internal window)
;; 4. Phase rhythm (bundled bigrams of trigrams)
;;
;; All rhythms have atoms factored to the outer level.
;; Each rhythm = (bind (atom name) raw-rhythm). One atom per indicator.

(define (broker-thought regime-chain broker-window phase-rhythm dims)
  (bundle
    ;; ── 1. Market indicator rhythms (~15 vectors) ────────────────
    ;; Each one: (bind (atom "rsi") raw-rsi-rhythm), etc.
    (:market-rhythms regime-chain)

    ;; ── 2. Regime rhythms (~10-13 vectors) ───────────────────────
    ;; Each one: (bind (atom "kama-er") raw-kama-rhythm), etc.
    ;; Time rhythms: (bind (atom "hour") raw-circular-rhythm)
    (:regime-rhythms regime-chain)

    ;; ── 3. Broker's portfolio rhythms (~5 vectors) ───────────────
    ;; The broker keeps its own window of portfolio snapshots.
    ;; Thermometer encoding. Bounds from the data's nature.
    (indicator-rhythm broker-window "avg-paper-age"
      (lambda (s) (:avg-age s))
      0.0 500.0 100.0 dims)
    (indicator-rhythm broker-window "avg-time-pressure"
      (lambda (s) (:avg-tp s))
      0.0 1.0 0.2 dims)
    (indicator-rhythm broker-window "avg-unrealized-residue"
      (lambda (s) (:avg-unrealized s))
      -0.1 0.1 0.05 dims)
    (indicator-rhythm broker-window "grace-rate"
      (lambda (s) (:grace-rate s))
      0.0 1.0 0.2 dims)
    (indicator-rhythm broker-window "active-positions"
      (lambda (s) (:active-count s))
      0.0 500.0 100.0 dims)

    ;; ── 4. Phase rhythm (1 vector) ───────────────────────────────
    phase-rhythm))

;; The broker's portfolio snapshot — pushed each candle:
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
;; Every rhythm vector has its atom factored to the outer level.
;; The raw rhythm inside each (bind (atom ...) ...) captures the
;; progression without the constant atom inflating the cosine.
