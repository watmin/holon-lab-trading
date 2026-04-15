;; broker-thought.wat — the broker-observer's full composed thought.
;; One thought. One encode. One question: do I get out now?
;;
;; The broker-observer receives position facts from the chain,
;; adds its own portfolio anxiety, adds the capacity-trimmed
;; phase sequence, and encodes the whole thing once.

(bundle
  ;; ── Position observer's facts (from chain.position_facts) ──────
  ;; These arrive pre-computed. The broker doesn't recompute them.
  ;; Shown here as the Full lens output for illustration.

  ;; Regime
  (bind (atom "kama-er")         (linear 0.3 1.0))
  (bind (atom "choppiness")      (linear 45.0 1.0))
  (bind (atom "dfa-alpha")       (linear 0.55 1.0))
  (bind (atom "variance-ratio")  (linear 1.05 1.0))
  (bind (atom "entropy-rate")    (linear 0.8 1.0))
  (bind (atom "aroon-up")        (linear 80.0 1.0))
  (bind (atom "aroon-down")      (linear 20.0 1.0))
  (bind (atom "fractal-dim")     (linear 1.4 1.0))

  ;; Time
  (bind (atom "hour")            (circular 14.0 24.0))
  (bind (atom "day-of-week")     (circular 3.0 7.0))

  ;; Phase current
  (atom "phase-peak")
  (bind (atom "phase-duration")  (log 12.0))

  ;; Phase scalar summaries
  (bind (atom "avg-phase-duration") (linear 28.0 1.0))
  (bind (atom "avg-phase-range")    (linear 0.015 1.0))

  ;; Extracted market facts (anomaly)
  (bind (atom "market") (bind (atom "rsi")          (linear 0.68 1.0)))
  (bind (atom "market") (bind (atom "bb-pos")       (linear 0.82 1.0)))
  (bind (atom "market") (bind (atom "adx")          (linear 32.0 1.0)))
  (bind (atom "market") (bind (atom "roc-12")       (linear 0.028 1.0)))
  (bind (atom "market") (bind (atom "obv-slope")    (linear 0.8 1.0)))
  (bind (atom "market") (bind (atom "hurst")        (linear 0.62 1.0)))
  (bind (atom "market") (bind (atom "range-pos-12") (linear 0.85 1.0)))

  ;; Extracted market facts (raw)
  (bind (atom "market-raw") (bind (atom "close-sma20")  (linear 0.023 1.0)))
  (bind (atom "market-raw") (bind (atom "rsi")          (linear 0.68 1.0)))
  (bind (atom "market-raw") (bind (atom "macd-hist")    (linear 12.5 1.0)))
  (bind (atom "market-raw") (bind (atom "stoch-k")      (linear 78.0 1.0)))
  (bind (atom "market-raw") (bind (atom "volume-accel") (linear 1.3 1.0)))

  ;; ── Broker-observer's own thoughts ─────────────────────────────

  ;; Portfolio anxiety — aggregated across active papers
  (bind (atom "avg-paper-age")           (log 145.0))       ; papers are ~145 candles old
  (bind (atom "avg-time-pressure")       (linear 0.29 1.0)) ; 29% through avg deadline
  (bind (atom "avg-unrealized-residue")  (linear -0.003 1.0)) ; slightly underwater
  (bind (atom "active-positions")        (log 47.0))        ; 47 active papers

  ;; ── Phase sequence (one vector — the whole sequence) ───────────
  ;; The Sequential encodes as one vector via positional permutation.
  ;; It occupies ONE slot in this outer bundle.
  ;; Trimmed to sqrt(dims) items from the right (most recent).
  ;;
  ;; See: bullish-momentum.wat, exhaustion-top.wat, breakdown.wat
  ;; for fully worked sequence examples with all deltas.

  (sequential
    ;; ... most recent phases, each a bundle of 4-10 facts ...
    ;; ... trimmed from the right to fit capacity ...
    ;; (shown fully in the scenario examples)
    ))

;; Total outer bundle: ~32 position facts + 4 anxiety + 1 sequence = ~37 items.
;; Kanerva capacity for D=10,000 is ~100. Plenty of headroom.
;;
;; The sequence's INTERNAL capacity is also ~100 items (sqrt(D)).
;; Each phase record is one item in the Sequential.
;; Typical week: 40-80 phase records. Within budget.
