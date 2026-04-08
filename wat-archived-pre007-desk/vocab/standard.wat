;; ── vocab/standard.wat — facts every observer sees ──────────────
;;
;; Standard vocabulary: contextual facts that modify the meaning of
;; all other facts. Available to every observer regardless of lens.
;; The noise subspace self-regulates — if a standard fact doesn't
;; matter for this observer, the subspace learns it's boring.
;;
;; Calendar (hour, day-of-week, session) is already standard in
;; thought.wat eval-calendar. This module adds the remaining
;; standard thoughts from proposal 003.
;;
;; All facts are scalar or zone. No comparisons — standard thoughts
;; describe context, not relationships between indicators.

(require facts)

;; ── Recency — time since last event ─────────────────────────────
;;
;; "How long since something interesting happened?"
;; Each recency fact tracks candles since a specific condition was true.
;; Encodes logarithmically — the difference between 5 and 10 candles
;; matters more than the difference between 500 and 510.
;;
;; The observer doesn't know which recency matters. The noise subspace
;; strips the ones that don't. The journal learns from the rest.

(define (eval-recency candles)
  "Time-since-event facts from the candle window."
  (let ((n    (len candles))
        (now  (last candles)))
    (when (>= n 10)
      (let ((facts (list)))

        ;; Candles since RSI was extreme (> 70 or < 30)
        (let ((since-rsi-extreme
                (fold (lambda (dist i)
                  (if (and (> dist 0) (or (> (:rsi (nth candles (- n 1 i))) 70.0)
                                          (< (:rsi (nth candles (- n 1 i))) 30.0)))
                      0 (+ dist 1)))
                  1 (range 1 (min n 200)))))
          (push! facts (fact/scalar "since-rsi-extreme"
                         (/ (ln (+ 1.0 since-rsi-extreme)) (ln 201.0))
                         1.0)))

        ;; Candles since volume spike (vol_accel > 2.0)
        (let ((since-vol-spike
                (fold (lambda (dist i)
                  (if (and (> dist 0) (> (:vol-accel (nth candles (- n 1 i))) 2.0))
                      0 (+ dist 1)))
                  1 (range 1 (min n 200)))))
          (push! facts (fact/scalar "since-vol-spike"
                         (/ (ln (+ 1.0 since-vol-spike)) (ln 201.0))
                         1.0)))

        ;; Candles since large move (|roc_1| > 2 * atr_r)
        (let ((since-large-move
                (fold (lambda (dist i)
                  (let ((c (nth candles (- n 1 i))))
                    (if (and (> dist 0) (> (abs (:roc-1 c)) (* 2.0 (:atr-r c))))
                        0 (+ dist 1))))
                  1 (range 1 (min n 200)))))
          (push! facts (fact/scalar "since-large-move"
                         (/ (ln (+ 1.0 since-large-move)) (ln 201.0))
                         1.0)))

        facts))))

;; ── Distance from structure — tension as scalar ─────────────────
;;
;; Not just above/below SMA — HOW FAR. The distance IS the tension.
;; "Price is 3% below the 24h high" means something different than
;; "price is 0.1% below the 24h high."
;;
;; All distances are percentage of current price, clamped to [-0.1, 0.1]
;; and rescaled to [0, 1] for scalar encoding.

(define (eval-distance candles)
  "Distance-from-structure facts."
  (let ((n   (len candles))
        (now (last candles)))
    (when (>= n 2)
      (let ((close (:close now))
            (facts (list)))

        ;; Distance from window high (24h ~ 288 candles at 5m, use available)
        (let ((window-high (fold max (:high (first candles))
                                 (map :high candles))))
          (push! facts (fact/scalar "dist-from-high"
                         (clamp (/ (- close window-high) close) -0.1 0.1)
                         1.0)))

        ;; Distance from window low
        (let ((window-low (fold min (:low (first candles))
                                (map :low candles))))
          (push! facts (fact/scalar "dist-from-low"
                         (clamp (/ (- close window-low) close) -0.1 0.1)
                         1.0)))

        ;; Distance from window midpoint
        (let ((window-high (fold max (:high (first candles)) (map :high candles)))
              (window-low  (fold min (:low (first candles))  (map :low candles)))
              (midpoint    (/ (+ window-high window-low) 2.0)))
          (push! facts (fact/scalar "dist-from-midpoint"
                         (clamp (/ (- close midpoint) close) -0.1 0.1)
                         1.0)))

        ;; Distance from SMA200 as continuous scalar (not binary above/below)
        (when (> (:sma200 now) 0.0)
          (push! facts (fact/scalar "dist-from-sma200"
                         (clamp (/ (- close (:sma200 now)) close) -0.1 0.1)
                         1.0)))

        facts))))

;; ── Relative participation — is the market paying attention? ────
;;
;; Volume as ratio to its moving average. Continuous, not binary.
;; "Volume is 2.3× average" carries more information than "volume spike."
;; Clamped to [0, 5] and rescaled to [0, 1].

(define (eval-participation candles)
  "Relative volume participation facts."
  (let ((now (last candles)))
    (when (> (:volume-sma-20 now) 0.0)
      (let ((ratio (/ (:volume now) (:volume-sma-20 now))))
        (list
          (fact/scalar "volume-ratio"
            (/ (clamp ratio 0.0 5.0) 5.0)
            1.0))))))

;; ── Session depth — how deep into the current session ───────────
;;
;; First 30 minutes of US open behaves differently than last hour
;; before close. Continuous scalar [0, 1] within the session.

(define (eval-session-depth now)
  "Progress through the current trading session."
  (let ((hour (:hour now)))
    (list
      ;; Fractional position within the 24h cycle
      ;; 0.0 = midnight, 0.5 = noon, 1.0 = midnight again
      ;; Different from encode-circular hour — this is linear progress
      (fact/scalar "session-depth" (/ hour 24.0) 1.0))))

;; ── Combined standard eval ──────────────────────────────────────

(define (eval-standard candles)
  "All standard facts. Called for every observer."
  (append
    (or (eval-recency candles) (list))
    (or (eval-distance candles) (list))
    (or (eval-participation candles) (list))
    (eval-session-depth (last candles))))

;; ── What standard does NOT do ────────────────────────────────────
;; - Does NOT include indicator-specific facts (those are exclusive)
;; - Does NOT include comparison pairs (those are shared)
;; - Does NOT filter noise (that's the observer's noise subspace)
;; - Pure context. Every observer sees it. The subspace judges it.
