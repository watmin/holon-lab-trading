;; ── vocab/ichimoku.wat — Ichimoku Cloud system ──────────────────
;;
;; Tenkan-sen, Kijun-sen, Senkou Spans, cloud zone, TK cross.
;; Ichimoku levels are streaming per-candle fields on the Candle struct
;; (computed by IndicatorBank from rolling 9/26/52-period high/low buffers).
;;
;; The 7 comparison pairs (close vs tenkan, kijun, cloud, spans) are handled
;; by COMPARISON_PAIRS in eval-comparisons — not duplicated here.
;;
;; This module adds: cloud zone (above/below/in) and TK cross detection.
;; These require window context (previous candle's tenkan/kijun for cross).
;;
;; Lens: structure

(require facts)

(define (eval-ichimoku candles)
  "Ichimoku cloud zone + TK cross. Returns None if levels not yet computed."
  (let ((n   (len candles))
        (now (last candles)))
    ;; Ichimoku fields are 0.0 during warmup (< 52 candles in IndicatorBank).
    ;; field_value filters 0.0 as None for non-derived fields.
    (when (> (:cloud-top now) 0.0)
      (let ((close        (:close now))
            (cloud-top    (:cloud-top now))
            (cloud-bottom (:cloud-bottom now))
            (tenkan       (:tenkan-sen now))
            (kijun        (:kijun-sen now)))
        (append
          ;; Cloud zone — above, below, or inside the cloud
          (list (fact/zone "close"
                  (cond ((> close cloud-top)    "above-cloud")
                        ((< close cloud-bottom) "below-cloud")
                        (else                   "in-cloud"))))

          ;; Tenkan-Kijun cross — needs previous candle
          (if (>= n 2)
              (let ((prev (nth candles (- n 2))))
                (when (> (:tenkan-sen prev) 0.0)
                  (let ((prev-tenkan (:tenkan-sen prev))
                        (prev-kijun  (:kijun-sen prev)))
                    (cond
                      ((and (< prev-tenkan prev-kijun) (>= tenkan kijun))
                       (list (fact/comparison "crosses-above" "tenkan-sen" "kijun-sen")))
                      ((and (> prev-tenkan prev-kijun) (<= tenkan kijun))
                       (list (fact/comparison "crosses-below" "tenkan-sen" "kijun-sen")))
                      (else (list))))))
              (list)))))))

;; ── What ichimoku does NOT do ──────────────────────────────────
;; - Does NOT project spans forward (standard Ichimoku shifts by 26 — we don't)
;; - Does NOT compute Chikou span (lagging span — backwards projection)
;; - Does NOT emit scalars (all relationships are positional)
;; - Pure function. Candles in, facts out.
