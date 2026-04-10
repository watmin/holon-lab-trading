;; ── vocab/market/divergence.wat ──────────────────────────────────
;;
;; RSI divergence via structural peaks. Pure function: candle in, ASTs out.
;; Conditional emission: divergence facts only fire when non-zero.
;; atoms: rsi-divergence-bull, rsi-divergence-bear, divergence-spread
;; Depends on: candle.

(require candle)

(define (encode-divergence-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((bull (:rsi-divergence-bull c))
        (bear (:rsi-divergence-bear c)))
    (filter-map
      (lambda (x) x)
      (list
        ;; Bullish divergence: price makes lower low but RSI makes higher low.
        ;; Magnitude is the divergence strength. [0, 1]. Only emitted when active.
        (when (> bull 0.0)
          '(Linear "rsi-divergence-bull" bull 1.0))

        ;; Bearish divergence: price makes higher high but RSI makes lower high.
        ;; Magnitude is the divergence strength. [0, 1]. Only emitted when active.
        (when (> bear 0.0)
          '(Linear "rsi-divergence-bear" bear 1.0))

        ;; Divergence spread: bull - bear. Signed. Positive = net bullish signal.
        ;; Only emitted when either divergence is active.
        (when (or (> bull 0.0) (> bear 0.0))
          '(Linear "divergence-spread" (- bull bear) 1.0))))))
