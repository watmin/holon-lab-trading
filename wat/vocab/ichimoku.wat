;; ── vocab/ichimoku.wat — Ichimoku Cloud system ──────────────────
;;
;; Tenkan-sen, Kijun-sen, Senkou Spans, cloud zone, TK cross.
;; Window-dependent — all levels computed from raw candles, not pre-baked.
;;
;; Expert profile: structure

(require vocab/mod)

;; ── Atoms introduced ───────────────────────────────────────────

;; Indicators:   close, tenkan-sen, kijun-sen, cloud-top, cloud-bottom,
;;               senkou-span-a, senkou-span-b
;; Predicates:   above, below, crosses-above, crosses-below
;; Zones:        above-cloud, below-cloud, in-cloud

;; ── Ichimoku levels ────────────────────────────────────────────
;;
;; Tenkan-sen:    (max_high + min_low) / 2 over  9 periods — conversion line
;; Kijun-sen:     (max_high + min_low) / 2 over 26 periods — base line
;; Senkou Span A: (tenkan + kijun) / 2                     — leading span A
;; Senkou Span B: (max_high + min_low) / 2 over full window — leading span B
;; Cloud top:     max(span_a, span_b)
;; Cloud bottom:  min(span_a, span_b)
;;
;; Periods: 9, 26. Traditional Ichimoku settings (from Hosoda, 1960s).
;; Span B uses full window instead of traditional 52 — adapts to expert's scale.

;; ── Facts produced ─────────────────────────────────────────────

; rune:gaze(phantom) — fact/comparison is not in the wat language
; rune:gaze(phantom) — fact/zone is not in the wat language
; rune:gaze(phantom) — cond is not in the wat language
(define (eval-ichimoku candles)
  "Ichimoku cloud facts. Returns Some(Vec<Fact>) or None if < 26 candles."

  ;; 7 comparison pairs — each emits above or below:
  ;;   (above/below close tenkan-sen)
  ;;   (above/below close kijun-sen)
  ;;   (above/below close cloud-top)
  ;;   (above/below close cloud-bottom)
  ;;   (above/below tenkan-sen kijun-sen)
  ;;   (above/below close senkou-span-a)
  ;;   (above/below close senkou-span-b)
  (for-each (lambda (a-name b-name a-val b-val)
    (fact/comparison (if (> a-val b-val) "above" "below") a-name b-name))
    comparison-pairs)

  ;; Cloud zone — where is price relative to the cloud?
  ;; Zone: (at close above-cloud)  when close > cloud_top
  ;;        (at close below-cloud)  when close < cloud_bottom
  ;;        (at close in-cloud)     when between
  (fact/zone "close" (cond
    ((> close cloud-top)    "above-cloud")
    ((< close cloud-bottom) "below-cloud")
    (else                   "in-cloud")))

  ;; Tenkan-Kijun cross — needs >= 27 candles for previous period
  ;; Recomputes tenkan/kijun for previous candle to detect sign change.
  ;; Comparison: (crosses-above tenkan-sen kijun-sen) — bullish TK cross
  ;;              (crosses-below tenkan-sen kijun-sen) — bearish TK cross
  ;; No threshold. Pure sign change detection.
  (when (>= n 27)
    (when (and (< prev-tenkan prev-kijun) (>= tenkan kijun))
      (fact/comparison "crosses-above" "tenkan-sen" "kijun-sen"))
    (when (and (> prev-tenkan prev-kijun) (<= tenkan kijun))
      (fact/comparison "crosses-below" "tenkan-sen" "kijun-sen"))))

;; ── Minimum: 26 candles ────────────────────────────────────────
;; Kijun-sen needs 26. TK cross needs 27.

;; ── What ichimoku does NOT do ──────────────────────────────────
;; - Does NOT project spans forward (standard Ichimoku shifts by 26 — we don't)
;; - Does NOT compute Chikou span (lagging span — backwards projection)
;; - Does NOT emit scalars (all relationships are positional)
;; - Does NOT import holon or create vectors
;; - Pure function. Candles in, facts out.
