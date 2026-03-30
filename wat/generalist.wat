;; ── generalist ─────────────────────────────────────────────────────
;;
;; The team's composite voice. Sees ALL 150+ facts simultaneously.
;; Fixed window (48 candles). Gated like every other voice.
;;
;; The generalist is not a manager. Not an expert. It's the summary
;; of all thoughts before they're separated into specialties. When
;; the generalist agrees with the majority, the signal is strong.
;; When it disagrees, something the specialists missed is visible
;; in the whole.

;; ── Eval methods ────────────────────────────────────────────────────
;; ALL of them. The "full" profile fires every eval method:
;;   eval_comparisons_cached   (momentum, structure)
;;   eval_rsi_sma_cached       (momentum)
;;   eval_stochastic           (momentum)
;;   eval_momentum             (momentum)
;;   eval_divergence           (momentum)
;;   eval_oscillators_module   (momentum)
;;   eval_segment_narrative    (structure)
;;   eval_range_position       (structure)
;;   eval_ichimoku             (structure)
;;   eval_fibonacci            (structure)
;;   eval_keltner              (structure)
;;   eval_timeframe_structure  (structure)
;;   eval_volume_confirmation  (volume)
;;   eval_volume_analysis      (volume)
;;   eval_price_action         (volume)
;;   eval_flow_module          (volume)
;;   eval_temporal             (narrative)
;;   eval_calendar             (narrative)
;;   eval_timeframe_narrative  (narrative)
;;   eval_regime_module        (regime)
;;   eval_persistence_module   (regime)

;; ── ~150 facts per candle ───────────────────────────────────────────
;;
;; The generalist's thought is the densest vector in the enterprise.
;; ~30 comparison facts + ~40 zone checks + ~20 PELT segment facts +
;; ~7 calendar facts + ~15 advanced indicators + ~20 temporal crosses +
;; ~20 misc (volume, fibonacci, keltner, divergence, range position)

;; ── Fixed window ────────────────────────────────────────────────────
;;
;; The generalist uses args.window (default 48) — NOT the sampled
;; window. This gives it a STABLE view while the experts explore
;; different scales. The generalist is the anchor. The experts are
;; the explorers.

;; ── Role in the enterprise ──────────────────────────────────────────
;;
;; The generalist reports to the manager as one of 6 voices:
;;   (bind generalist-atom (encode-log |conviction|))  ; BUY
;;   (bind (permute generalist-atom) (encode-log |conviction|))  ; SELL
;;
;; It's gated by its own curve_valid — currently using tht_journal's
;; Kelly fit. If the generalist's direction accuracy doesn't validate,
;; its gate closes and the manager doesn't hear it.

;; ── DISCOVERY ───────────────────────────────────────────────────────
;;
;; 1. The generalist was REDUNDANT in the gated test. Same gate
;;    breathing pattern, same accuracy, with or without it. The
;;    specialist subset already captures the signal.
;;
;; 2. The generalist at 150 facts is very dense. The discriminant
;;    over 150 facts must separate a HUGE space. The specialists
;;    at 30-40 facts each have an easier separation problem.
;;    Specialization helps because it REDUCES dimensionality.
;;
;; 3. The generalist's gate uses curve_valid from the old resolved_preds
;;    which now tracks the MANAGER's profitability, not the generalist's
;;    own direction accuracy. This is a bug — the generalist needs
;;    its own accuracy tracking independent of the manager.
;;
;; 4. Should the generalist exist at all? It was proven redundant.
;;    Its compute cost (~150 facts, 6× more than any specialist) is
;;    significant. The argument for keeping it: it might find signal
;;    that NO specialist sees — emergent patterns from the interaction
;;    of all 150 facts simultaneously. But the data says otherwise so far.
;;
;; 5. Alternative role: the generalist could be the GENERALIST of the
;;    RISK team instead of the MARKET team. A holistic portfolio
;;    health assessment using all dimensions. That role is unfilled.
