;; broker-thought.wat — the broker-observer's full composed thought.
;; One thought. One encode. One question: do I get out now?
;;
;; Three components bundled:
;; 1. Position observer's facts (from chain — market extraction + lens)
;; 2. Portfolio anxiety (avg age, pressure, unrealized, active count)
;; 3. Phase rhythm (bundled bigrams of trigrams — one vector)

(bundle
  ;; ── 1. Position observer's facts (from chain.position_facts) ───
  ;; Pre-computed. The broker doesn't recompute. Shown as Full lens.

  ;; Regime (8)
  (bind (atom "kama-er")         (linear 0.3 1.0))
  (bind (atom "choppiness")      (linear 45.0 1.0))
  (bind (atom "dfa-alpha")       (linear 0.55 1.0))
  (bind (atom "variance-ratio")  (linear 1.05 1.0))
  (bind (atom "entropy-rate")    (linear 0.8 1.0))
  (bind (atom "aroon-up")        (linear 80.0 1.0))
  (bind (atom "aroon-down")      (linear 20.0 1.0))
  (bind (atom "fractal-dim")     (linear 1.4 1.0))

  ;; Time — parts and composition (3)
  (bind (atom "hour")            (circular 14.0 24.0))
  (bind (atom "day-of-week")     (circular 3.0 7.0))
  (bind
    (bind (atom "hour") (circular 14.0 24.0))
    (bind (atom "day-of-week") (circular 3.0 7.0)))

  ;; Phase current (2)
  (atom "phase-peak")
  (bind (atom "phase-duration")  (log 12.0))

  ;; Phase scalar summaries (2)
  (bind (atom "avg-phase-duration") (linear 28.0 1.0))
  (bind (atom "avg-phase-range")    (linear 0.015 1.0))

  ;; Extracted market facts — anomaly pass (~7)
  (bind (atom "market") (bind (atom "rsi")          (linear 0.68 1.0)))
  (bind (atom "market") (bind (atom "bb-pos")       (linear 0.82 1.0)))
  (bind (atom "market") (bind (atom "adx")          (linear 32.0 1.0)))
  (bind (atom "market") (bind (atom "roc-12")       (linear 0.028 1.0)))
  (bind (atom "market") (bind (atom "obv-slope")    (linear 0.8 1.0)))
  (bind (atom "market") (bind (atom "hurst")        (linear 0.62 1.0)))
  (bind (atom "market") (bind (atom "range-pos-12") (linear 0.85 1.0)))

  ;; Extracted market facts — raw pass (~5)
  (bind (atom "market-raw") (bind (atom "close-sma20")  (linear 0.023 1.0)))
  (bind (atom "market-raw") (bind (atom "rsi")          (linear 0.68 1.0)))
  (bind (atom "market-raw") (bind (atom "macd-hist")    (linear 12.5 1.0)))
  (bind (atom "market-raw") (bind (atom "stoch-k")      (linear 78.0 1.0)))
  (bind (atom "market-raw") (bind (atom "volume-accel") (linear 1.3 1.0)))

  ;; ── 2. Broker-observer's portfolio anxiety (4) ─────────────────

  (bind (atom "avg-paper-age")           (log 145.0))
  (bind (atom "avg-time-pressure")       (linear 0.29 1.0))
  (bind (atom "avg-unrealized-residue")  (linear -0.003 1.0))
  (bind (atom "active-positions")        (log 47.0))

  ;; ── 3. Phase rhythm (1 vector) ─────────────────────────────────
  ;; The bundled bigrams of trigrams. Computed from phase_history.
  ;; This is a pre-encoded Vector, not an AST — it bundles directly
  ;; into the outer thought via vector addition.
  ;;
  ;; See: bullish-momentum.wat, exhaustion-top.wat, breakdown.wat,
  ;;      choppy-range.wat, recovery-bottom.wat
  ;;
  ;; (rhythm-vector)  ;; one slot in this bundle
  )

;; Outer bundle: ~31 position + 4 anxiety + 1 rhythm = ~36 items.
;; Kanerva capacity for D=10,000 is ~100. Plenty of headroom.
;;
;; The rhythm's INTERNAL capacity (bigram-pairs in the rhythm bundle)
;; is a separate sqrt(D) budget. See PROPOSAL.md.
;;
;; One encode of this bundle. One cosine against the gate reckoner.
;; Hold or Exit. The treasury judges the papers.
