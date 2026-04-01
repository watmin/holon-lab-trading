;; ── vocab/ichimoku.wat — Ichimoku Cloud system ──────────────────
;;
;; Tenkan-sen, Kijun-sen, Senkou Spans, cloud zone, TK cross.
;; Window-dependent — all levels computed from raw candles, not pre-baked.
;;
;; Lens: structure

(require facts)

(define (midpoint candles)
  "Midpoint of a candle window: (highest-high + lowest-low) / 2."
  (let ((hi (fold max (first (map :high candles)) (rest (map :high candles))))
        (lo (fold min (first (map :low candles))  (rest (map :low candles)))))
    (/ (+ hi lo) 2.0)))

(define (eval-ichimoku candles)
  "Ichimoku cloud facts. Returns None if < 26 candles."
  (when (>= (len candles) 26)
    (let ((n      (len candles))
          (now    (last candles))
          (close  (:close now))
          (tenkan (midpoint (last-n candles 9)))
          (kijun  (midpoint (last-n candles 26)))
          (span-a (/ (+ tenkan kijun) 2.0))
          (span-b (midpoint candles))
          (cloud-top    (max span-a span-b))
          (cloud-bottom (min span-a span-b)))
      (append
        ;; 7 comparison pairs — close vs ichimoku levels
        (fold-left
          (lambda (facts quad)
            (let ((a-name (first quad))
                  (b-name (second quad))
                  (a-val  (nth quad 2))
                  (b-val  (nth quad 3)))
              (append facts
                (list (fact/comparison (if (> a-val b-val) "above" "below")
                                      a-name b-name)))))
          (list)
          [("close"      "tenkan-sen"   close  tenkan)
           ("close"      "kijun-sen"    close  kijun)
           ("close"      "cloud-top"    close  cloud-top)
           ("close"      "cloud-bottom" close  cloud-bottom)
           ("tenkan-sen" "kijun-sen"    tenkan kijun)
           ("close"      "senkou-span-a" close span-a)
           ("close"      "senkou-span-b" close span-b)])

        ;; Cloud zone
        (list (fact/zone "close"
                (cond ((> close cloud-top)    "above-cloud")
                      ((< close cloud-bottom) "below-cloud")
                      (else                   "in-cloud"))))

        ;; Tenkan-Kijun cross — needs >= 27 candles for previous period
        (if (>= n 27)
            (let ((prev-tenkan (midpoint (take 9  (last-n candles 10))))
                  (prev-kijun  (midpoint (take 26 (last-n candles 27)))))
              (cond
                ((and (< prev-tenkan prev-kijun) (>= tenkan kijun))
                 (list (fact/comparison "crosses-above" "tenkan-sen" "kijun-sen")))
                ((and (> prev-tenkan prev-kijun) (<= tenkan kijun))
                 (list (fact/comparison "crosses-below" "tenkan-sen" "kijun-sen")))
                (else (list))))
            (list))))))

;; ── What ichimoku does NOT do ──────────────────────────────────
;; - Does NOT project spans forward (standard Ichimoku shifts by 26 — we don't)
;; - Does NOT compute Chikou span (lagging span — backwards projection)
;; - Does NOT emit scalars (all relationships are positional)
;; - Pure function. Candles in, facts out.
