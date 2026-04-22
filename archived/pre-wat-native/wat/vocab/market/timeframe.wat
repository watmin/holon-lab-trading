;; ── vocab/market/timeframe.wat ───────────────────────────────────
;;
;; 1h/4h structure + inter-timeframe agreement.
;; Pure function: candle in, ASTs out.
;; atoms: tf-1h-trend, tf-1h-ret, tf-4h-trend, tf-4h-ret,
;;        tf-agreement, tf-5m-1h-align
;; Depends on: candle.

(require candle)

(define (encode-timeframe-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; 1h trend: body / range of the 1h candle. Signed. [-1, 1].
    ;; Positive = bullish body, negative = bearish.
    '(Linear "tf-1h-trend" (:tf-1h-body c) 1.0)

    ;; 1h return: signed percentage return over 1h. Linear.
    '(Linear "tf-1h-ret" (:tf-1h-ret c) 0.1)

    ;; 4h trend: body / range of the 4h candle. Signed. [-1, 1].
    '(Linear "tf-4h-trend" (:tf-4h-body c) 1.0)

    ;; 4h return: signed percentage return over 4h. Linear.
    '(Linear "tf-4h-ret" (:tf-4h-ret c) 0.1)

    ;; Timeframe agreement: [0, 1] — how aligned are the timeframes.
    ;; 1.0 = all timeframes agree, 0.0 = disagreement.
    '(Linear "tf-agreement" (:tf-agreement c) 1.0)

    ;; 5m-1h alignment: signed. Agreement between 5m direction and 1h trend.
    ;; Positive = aligned, negative = counter-trend.
    '(Linear "tf-5m-1h-align"
             (* (signum (:tf-1h-body c))
                (/ (- (:close c) (:open c)) (:close c)))
             0.1)))
