;; position-full-thought.wat — Full lens position observer output.
;; Regime + time + phase current + phase scalar summaries.
;; No sequence — the broker-observer owns that.

(bundle
  ;; ── Full lens facts: regime + time + phase (13 facts) ──────────

  ;; Regime — same as Core (8 facts)
  (bind (atom "kama-er")         (linear 0.3 1.0))
  (bind (atom "choppiness")      (linear 45.0 1.0))
  (bind (atom "dfa-alpha")       (linear 0.55 1.0))
  (bind (atom "variance-ratio")  (linear 1.05 1.0))
  (bind (atom "entropy-rate")    (linear 0.8 1.0))
  (bind (atom "aroon-up")        (linear 80.0 1.0))
  (bind (atom "aroon-down")      (linear 20.0 1.0))
  (bind (atom "fractal-dim")     (linear 1.4 1.0))

  ;; Time — parts and composition (3 facts)
  (bind (atom "hour")            (circular 14.0 24.0))
  (bind (atom "day-of-week")     (circular 3.0 7.0))
  (bind
    (bind (atom "hour") (circular 14.0 24.0))
    (bind (atom "day-of-week") (circular 3.0 7.0)))

  ;; Phase current — what the labeler says RIGHT NOW (2 facts)
  (atom "phase-peak")                                    ; current label
  (bind (atom "phase-duration")  (log 12.0))             ; 12 candles in this phase

  ;; Phase scalar summaries — aggregate properties of the history (variable)
  (bind (atom "avg-phase-duration") (linear 28.0 1.0))
  (bind (atom "avg-phase-range")    (linear 0.015 1.0))

  ;; ── Extracted market facts (anomaly pass) ──────────────────────
  (bind (atom "market") (bind (atom "rsi")          (linear 0.68 1.0)))
  (bind (atom "market") (bind (atom "bb-pos")       (linear 0.82 1.0)))
  (bind (atom "market") (bind (atom "adx")          (linear 32.0 1.0)))
  (bind (atom "market") (bind (atom "roc-12")       (linear 0.028 1.0)))
  (bind (atom "market") (bind (atom "obv-slope")    (linear 0.8 1.0)))
  (bind (atom "market") (bind (atom "hurst")        (linear 0.62 1.0)))
  (bind (atom "market") (bind (atom "range-pos-12") (linear 0.85 1.0)))

  ;; ── Extracted market facts (raw pass) ──────────────────────────
  (bind (atom "market-raw") (bind (atom "close-sma20")  (linear 0.023 1.0)))
  (bind (atom "market-raw") (bind (atom "rsi")          (linear 0.68 1.0)))
  (bind (atom "market-raw") (bind (atom "macd-hist")    (linear 12.5 1.0)))
  (bind (atom "market-raw") (bind (atom "stoch-k")      (linear 78.0 1.0)))
  (bind (atom "market-raw") (bind (atom "volume-accel") (linear 1.3 1.0))))

;; Total: ~28 facts. The broker-observer adds anxiety (4) + rhythm (1).
;; Outer bundle: ~33 items.
