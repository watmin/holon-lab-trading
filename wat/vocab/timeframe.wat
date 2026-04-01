;; ── vocab/timeframe.wat — inter-timeframe structure and narrative ──
;;
;; Split by domain: structure sees geometry (range position, body ratio).
;; Narrative sees the story (direction agreement, return magnitude).
;; Each observer gets the thoughts that belong to its way of seeing.
;;
;; Expert profiles: structure (eval-timeframe-structure),
;;                  narrative (eval-timeframe-narrative)

(require facts)

;; ── Structure facts ────────────────────────────────────────────

(define (eval-timeframe-structure candles)
  "Multi-timeframe geometry. Pre-computed values from Candle."
  (let ((now (last candles)))
    (let ((h-range  (- (:tf-1h-high now) (:tf-1h-low now)))
          (h4-range (- (:tf-4h-high now) (:tf-4h-low now))))
      (append
        ;; Body ratios — how decisive is each timeframe's candle?
        (list (fact/scalar "tf-1h-body" (clamp (:tf-1h-body now) 0.0 1.0) 1.0)
              (fact/scalar "tf-4h-body" (clamp (:tf-4h-body now) 0.0 1.0) 1.0))

        ;; Range position — where is close within the hourly range?
        (if (> h-range 1e-10)
            (list (fact/scalar "tf-1h-range-pos"
                    (clamp (/ (- (:close now) (:tf-1h-low now)) h-range) 0.0 1.0) 1.0))
            (list))

        ;; Range position — where is close within the 4h range?
        (if (> h4-range 1e-10)
            (list (fact/scalar "tf-4h-range-pos"
                    (clamp (/ (- (:close now) (:tf-4h-low now)) h4-range) 0.0 1.0) 1.0))
            (list))))))

;; ── Narrative facts ────────────────────────────────────────────

(define (direction-zone prefix ret strong-threshold)
  "Classify a return into directional zone + scalar."
  (list (fact/zone prefix
          (cond ((> ret strong-threshold)    (format "~a-up-strong" prefix))
                ((> ret 0.0)                 (format "~a-up-mild" prefix))
                ((< ret (- strong-threshold)) (format "~a-down-strong" prefix))
                (else                         (format "~a-down-mild" prefix))))
        (fact/scalar (format "~a-ret" prefix)
          (+ (* (clamp ret -0.05 0.05) 10.0) 0.5) 1.0)))

(define (eval-timeframe-narrative candles)
  "Multi-timeframe story. Pre-computed returns from Candle."
  (let ((now (last candles))
        (n   (len candles)))
    (let ((tf-1h-ret (:tf-1h-ret now))
          (tf-4h-ret (:tf-4h-ret now)))
      (append
        ;; 1-hour return direction and magnitude
        (if (> (abs tf-1h-ret) 1e-10)
            (direction-zone "tf-1h" tf-1h-ret 0.005)
            (list))

        ;; 4-hour return direction and magnitude
        (if (> (abs tf-4h-ret) 1e-10)
            (direction-zone "tf-4h" tf-4h-ret 0.01)
            (list))

        ;; Inter-timeframe agreement — do 5m, 1h, and 4h agree?
        (if (>= n 2)
            (let ((m5-dir    (- (:close now) (:close (nth candles (- n 2)))))
                  (agree-1h  (or (and (> m5-dir 0.0) (> tf-1h-ret 0.0))
                                 (and (< m5-dir 0.0) (< tf-1h-ret 0.0))))
                  (agree-4h  (or (and (> m5-dir 0.0) (> tf-4h-ret 0.0))
                                 (and (< m5-dir 0.0) (< tf-4h-ret 0.0)))))
              (list (fact/bare
                (cond ((and agree-1h agree-4h)       "tf-all-agree")
                      ((and (not agree-1h) (not agree-4h)) "tf-all-disagree")
                      (agree-1h                      "tf-1h-agrees")
                      (else                          "tf-4h-agrees")))))
            (list))))))

;; ── What timeframe does NOT do ─────────────────────────────────
;; - Does NOT aggregate candles (aggregation pre-computed at load time)
;; - Does NOT compute moving averages at higher timeframes
;; - Two functions. Two domains. Same source data.
