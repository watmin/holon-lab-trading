;; ── generalist ─────────────────────────────────────────────────────
;;
;; The team's composite voice. Sees ALL 150+ facts simultaneously.
;; Fixed window (args.window, default 48). Own journal, own proof gate.
;;
;; The generalist is Observer[5] with lens "generalist". It thinks every
;; thought the specialists think, bundled into one vector. It finds
;; cross-vocabulary patterns no specialist can see — "RSI divergence
;; + volume exhaustion + regime shift" is a thought only the generalist
;; thinks.

(require core/primitives)
(require core/structural)
(require facts)
(require patterns)

;; ── Lens ────────────────────────────────────────────────

(define (encode-generalist candles)
  "Generalist's thought: the union of all specialist dispatches."
  (append
    ;; momentum
    (eval-comparisons candles)
    (eval-rsi-sma candles)
    (eval-stochastic candles)
    (eval-momentum candles)
    (eval-divergence candles)
    (eval-oscillators candles)
    ;; structure
    (eval-segment-narrative candles)
    (eval-range-position candles)
    (eval-ichimoku candles)
    (eval-fibonacci candles)
    (eval-keltner candles)
    (eval-timeframe-structure candles)
    ;; volume
    (eval-volume-confirmation candles)
    (eval-volume-analysis candles)
    (eval-price-action candles)
    (eval-flow-module candles)
    ;; narrative
    (eval-temporal candles)
    (eval-calendar candles)
    (eval-timeframe-narrative candles)
    ;; regime
    (eval-regime-module candles)
    (eval-persistence-module candles)))

;; ── observer ──────────────────────────────────────────────────────

(define generalist
  (new-observer "generalist" dims refit-interval :seed-generalist ["Buy" "Sell"]))

;; Fixed window: WindowSampler(min=48, max=48) — always the same depth.
;; The specialists explore [12, 2016] and discover their own scale.
;; The generalist is the anchor. The specialists are the explorers.

;; ── Example thoughts ────────────────────────────────────────────────
;;
;; Cross-vocabulary patterns only the generalist sees:
;; (fact/zone "rsi" "overbought")                       ; from momentum
;; (fact/zone "volume" "volume-drought")                 ; from volume
;; (fact/zone "dfa-alpha" "random-walk-dfa")             ; from regime
;; (fact/bare "us")                                      ; from narrative
;; (fact/zone "close" "above-cloud")                     ; from structure
;; Together: "overbought + no volume + random walk + US session + above cloud"

;; ── RESOLVED ────────────────────────────────────────────────────────
;;
;; Previously: curve_valid was borrowed from the manager's resolved_preds.
;; Now: the generalist is a proper Observer with its own journal, own
;; resolved deque, own proof gate (accuracy > 52% at high conviction).
;; The datamancer overruled the designers who recommended dissolving it.
;; The generalist sees cross-vocabulary geometry. The designers saw a
;; categorical orphan. The datamancer saw unique signal.

;; ── What the generalist does NOT do ─────────────────────────────────
;; - Does NOT discover its own window (fixed, not sampled)
;; - Does NOT see a different vocabulary than the union of all specialists
;; - Does NOT have higher authority than the specialists (one voice among six)
