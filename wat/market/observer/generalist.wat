;; ── generalist ─────────────────────────────────────────────────────
;;
;; The team's composite voice. Sees ALL 150+ facts simultaneously.
;; Fixed window (args.window, default 48). Own journal, own proof gate.
;;
;; The generalist is Observer[5] with profile "full". It thinks every
;; thought the specialists think, bundled into one vector. It finds
;; cross-vocabulary patterns no specialist can see — "RSI divergence
;; + volume exhaustion + regime shift" is a thought only the generalist
;; thinks.

(require core/primitives)
(require core/structural)
(require patterns)

;; ── The expert ──────────────────────────────────────────────────────

;; expert: shorthand for (new-observer profile dims refit-interval seed labels).
;; See market/observer.wat for the Observer struct.
(define generalist
  (new-observer "generalist" dims refit-interval :seed-generalist ["Buy" "Sell"]))

;; Fixed window: WindowSampler(min=48, max=48) — always the same depth.
;; The specialists explore [12, 2016] and discover their own scale.
;; The generalist is the anchor. The specialists are the explorers.

;; ── All eval methods ────────────────────────────────────────────────
;;
;; The "full" profile fires every eval method from every specialist:
;;   momentum:  comparisons, rsi-sma, stochastic, momentum, divergence, oscillators
;;   structure: comparisons, segments, range, ichimoku, fibonacci, keltner, timeframe
;;   volume:    confirmation, analysis, price-action, flow
;;   narrative: temporal, calendar, timeframe-narrative
;;   regime:    regime-module, persistence-module

;; ── Role in the manager ─────────────────────────────────────────────
;;
;; Reports as one of 6 voices via the opinion → gate pattern:
;;   (gate (opinion (predict (:journal generalist) thought)
;;                  (atom "generalist"))
;;         (atom "generalist")
;;         (:curve-valid generalist))
;;
;; The generalist provides discriminant-strength to the manager's
;; context encoding — how well the generalist's discriminant separates
;; the buy and sell prototypes.

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
