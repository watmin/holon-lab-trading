;; ── vocab/exit/structure.wat ─────────────────────────────────────
;;
;; Trend consistency and ADX strength. Exit observers use these
;; to gauge how orderly the market is. Pure function: candle in, ASTs out.
;; atoms: trend-consistency-6, trend-consistency-12, trend-consistency-24,
;;        adx, exit-kama-er
;; Depends on: candle.

(require candle)

(define (encode-exit-structure-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Trend consistency (6 period): [-1, 1].
    ;; Fraction of recent candles that moved in the same direction.
    '(Linear "trend-consistency-6" (:trend-consistency-6 c) 1.0)

    ;; Trend consistency (12 period): [-1, 1].
    '(Linear "trend-consistency-12" (:trend-consistency-12 c) 1.0)

    ;; Trend consistency (24 period): [-1, 1].
    '(Linear "trend-consistency-24" (:trend-consistency-24 c) 1.0)

    ;; ADX: [0, 100]. Trend strength. Normalize to [0, 1].
    '(Linear "adx" (/ (:adx c) 100.0) 1.0)

    ;; KAMA efficiency ratio for exit context: [0, 1].
    ;; Named exit-kama-er to distinguish from market regime's kama-er.
    ;; Same underlying field, different atom name — the observer's lens
    ;; gives it exit-specific meaning.
    '(Linear "exit-kama-er" (:kama-er c) 1.0)))
