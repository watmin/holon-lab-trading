;; ── vocab/market/standard.wat ────────────────────────────────────
;;
;; Universal context for all market observers. Takes the candle WINDOW
;; (a slice of candles), not a single candle. Computes recency and
;; distance measures that require history.
;; atoms: since-rsi-extreme, since-vol-spike, since-large-move,
;;        dist-from-high, dist-from-low, dist-from-midpoint,
;;        dist-from-sma200, session-depth
;; Depends on: candle.

(require candle)

(define (encode-standard-facts [candle-window : Vec<Candle>])
  : Vec<ThoughtAST>
  (let ((current (last candle-window))
        (closes  (map (lambda (c) (:close c)) candle-window))
        (highs   (map (lambda (c) (:high c)) candle-window))
        (lows    (map (lambda (c) (:low c)) candle-window))
        (window-high (apply max highs))
        (window-low  (apply min lows))
        (window-mid  (/ (+ window-high window-low) 2.0))
        (price   (:close current))
        (n       (length candle-window)))
    (list
      ;; Since RSI extreme: candles since RSI was above 80 or below 20.
      ;; RSI is raw [0, 100] scale. Log-encoded — recency decays logarithmically.
      '(Log "since-rsi-extreme"
            (max 1.0
                 (let ((idx (fold-left
                              (lambda (best i)
                                (let ((rsi (:rsi (nth candle-window i))))
                                  (if (or (> rsi 80.0) (< rsi 20.0))
                                      i
                                      best)))
                              0
                              (range 0 n))))
                   (+ 1.0 (- n idx 1)))))

      ;; Since volume spike: candles since volume-accel exceeded a threshold.
      ;; Log-encoded.
      '(Log "since-vol-spike"
            (max 1.0
                 (let ((idx (fold-left
                              (lambda (best i)
                                (if (> (:volume-accel (nth candle-window i)) 2.0)
                                    i
                                    best))
                              0
                              (range 0 n))))
                   (+ 1.0 (- n idx 1)))))

      ;; Since large move: candles since |roc-1| exceeded 2%.
      ;; Log-encoded.
      '(Log "since-large-move"
            (max 1.0
                 (let ((idx (fold-left
                              (lambda (best i)
                                (if (> (abs (:roc-1 (nth candle-window i))) 0.02)
                                    i
                                    best))
                              0
                              (range 0 n))))
                   (+ 1.0 (- n idx 1)))))

      ;; Distance from window high: signed percentage.
      ;; Always <= 0 (current is at or below high).
      '(Linear "dist-from-high"
               (/ (- price window-high) price)
               0.1)

      ;; Distance from window low: signed percentage.
      ;; Always >= 0 (current is at or above low).
      '(Linear "dist-from-low"
               (/ (- price window-low) price)
               0.1)

      ;; Distance from midpoint: signed percentage.
      '(Linear "dist-from-midpoint"
               (/ (- price window-mid) price)
               0.1)

      ;; Distance from SMA200: signed percentage.
      '(Linear "dist-from-sma200"
               (/ (- price (:sma200 current)) price)
               0.1)

      ;; Session depth: how deep into the window are we.
      ;; Normalized to [0, 1]. Log-encoded (early candles matter more).
      '(Log "session-depth" (max 1.0 (+ 1.0 n))))))
