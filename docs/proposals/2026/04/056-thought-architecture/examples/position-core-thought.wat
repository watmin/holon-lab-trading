;; position-core-thought.wat — Core lens position observer output.
;; Regime + time. The consensus minimum. No phase awareness.
;;
;; The position observer also extracts anomalous market facts via cosine.
;; Those appear as (bind (atom "market") ...) and (bind (atom "market-raw") ...).
;; The count varies per candle — only facts above noise floor pass through.

(bundle
  ;; ── Core lens facts: regime + time (10 facts) ──────────────────

  ;; Regime — character of the market
  (bind (atom "kama-er")         (linear 0.3 1.0))     ; low efficiency — choppy
  (bind (atom "choppiness")      (linear 45.0 1.0))    ; moderate choppiness
  (bind (atom "dfa-alpha")       (linear 0.55 1.0))    ; slightly persistent
  (bind (atom "variance-ratio")  (linear 1.05 1.0))    ; near random walk
  (bind (atom "entropy-rate")    (linear 0.8 1.0))     ; moderate disorder
  (bind (atom "aroon-up")        (linear 80.0 1.0))    ; recent high was recent
  (bind (atom "aroon-down")      (linear 20.0 1.0))    ; recent low was distant
  (bind (atom "fractal-dim")     (linear 1.4 1.0))     ; moderate complexity

  ;; Time — circular scalars
  (bind (atom "hour")            (circular 14.0 24.0))
  (bind (atom "day-of-week")     (circular 3.0 7.0))

  ;; ── Extracted market facts (anomaly pass) ──────────────────────
  ;; These are the market observer's facts that registered above
  ;; the noise floor when cosined against the anomaly vector.
  ;; ~10-20 survive from the original ~33.

  (bind (atom "market") (bind (atom "rsi")          (linear 0.68 1.0)))
  (bind (atom "market") (bind (atom "bb-pos")       (linear 0.82 1.0)))
  (bind (atom "market") (bind (atom "adx")          (linear 32.0 1.0)))
  (bind (atom "market") (bind (atom "roc-12")       (linear 0.028 1.0)))
  (bind (atom "market") (bind (atom "obv-slope")    (linear 0.8 1.0)))
  (bind (atom "market") (bind (atom "hurst")        (linear 0.62 1.0)))
  (bind (atom "market") (bind (atom "range-pos-12") (linear 0.85 1.0)))

  ;; ── Extracted market facts (raw pass) ──────────────────────────
  ;; Same facts cosined against the raw thought vector.
  ;; Different subset may survive — raw includes noise the anomaly stripped.

  (bind (atom "market-raw") (bind (atom "close-sma20")  (linear 0.023 1.0)))
  (bind (atom "market-raw") (bind (atom "rsi")          (linear 0.68 1.0)))
  (bind (atom "market-raw") (bind (atom "macd-hist")    (linear 12.5 1.0)))
  (bind (atom "market-raw") (bind (atom "stoch-k")      (linear 78.0 1.0)))
  (bind (atom "market-raw") (bind (atom "volume-accel") (linear 1.3 1.0))))

;; Total: ~22 facts. Well within Kanerva capacity.
;; The broker-observer will add anxiety (4) + sequence (1 vector).
;; Outer bundle: ~27 items.
