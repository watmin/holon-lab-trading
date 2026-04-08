;; vocab/market/timeframe.wat — 1h/4h structure + narrative + inter-timeframe agreement.
;;
;; Depends on: Candle, ThoughtAST.
;;
;; Pure: candle in, ASTs out. No state.
;; Multi-timeframe structure: what the higher timeframes say about
;; direction and body strength. Inter-timeframe agreement: how aligned
;; are the 5m, 1h, and 4h signals?

(require primitives)
(require candle)
(require enums)     ; ThoughtAST

;; ── encode-timeframe-facts ──────────────────────────────────────────────

(define (encode-timeframe-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; 1h return — signed, the direction of the 1h candle
    (Linear "tf-1h-ret" (:tf-1h-ret c) 0.1)

    ;; 1h body — how decisive the 1h candle was
    (Linear "tf-1h-body" (:tf-1h-body c) 0.1)

    ;; 4h return — signed, the direction of the 4h candle
    (Linear "tf-4h-ret" (:tf-4h-ret c) 0.1)

    ;; 4h body — how decisive the 4h candle was
    (Linear "tf-4h-body" (:tf-4h-body c) 0.1)

    ;; 1h range position — where close is within the 1h range
    (Linear "tf-1h-range-pos"
            (if (> (- (:tf-1h-high c) (:tf-1h-low c)) 0.0)
                (/ (- (:close c) (:tf-1h-low c))
                   (- (:tf-1h-high c) (:tf-1h-low c)))
                0.5)
            1.0)

    ;; 4h range position — where close is within the 4h range
    (Linear "tf-4h-range-pos"
            (if (> (- (:tf-4h-high c) (:tf-4h-low c)) 0.0)
                (/ (- (:close c) (:tf-4h-low c))
                   (- (:tf-4h-high c) (:tf-4h-low c)))
                0.5)
            1.0)

    ;; Inter-timeframe agreement — how aligned are 5m/1h/4h directions
    ;; Pre-computed by IndicatorBank. [-1, 1]: +1 = all agree up, -1 = all agree down
    (Linear "tf-agreement" (:tf-agreement c) 1.0)))
