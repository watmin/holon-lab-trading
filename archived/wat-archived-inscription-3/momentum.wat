;; vocab/market/momentum.wat — CCI, SMA-relative facts.
;;
;; Depends on: Candle, ThoughtAST.
;;
;; Pure: candle in, ASTs out. No state. No zones.
;; CCI as a continuous scalar. SMA-relative facts: close-sma20/50/200
;; as signed distances. No candle-dir signum — the ROC carries the direction.

(require primitives)
(require candle)
(require enums)     ; ThoughtAST

;; ── encode-momentum-facts ───────────────────────────────────────────────

(define (encode-momentum-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; CCI — unbounded, typical range [-200, 200], scale accordingly
    (Linear "cci" (/ (:cci c) 200.0) 2.0)

    ;; SMA-relative — signed distance from close to SMA as fraction
    ;; Positive = above, negative = below. The distance IS the signal.
    (Linear "close-sma20"
            (if (> (:sma20 c) 0.0)
                (/ (- (:close c) (:sma20 c)) (:sma20 c))
                0.0)
            0.1)

    (Linear "close-sma50"
            (if (> (:sma50 c) 0.0)
                (/ (- (:close c) (:sma50 c)) (:sma50 c))
                0.0)
            0.1)

    (Linear "close-sma200"
            (if (> (:sma200 c) 0.0)
                (/ (- (:close c) (:sma200 c)) (:sma200 c))
                0.0)
            0.1)

    ;; SMA stack — the structure of moving averages relative to each other
    (Linear "sma20-sma50"
            (if (> (:sma50 c) 0.0)
                (/ (- (:sma20 c) (:sma50 c)) (:sma50 c))
                0.0)
            0.1)

    (Linear "sma50-sma200"
            (if (> (:sma200 c) 0.0)
                (/ (- (:sma50 c) (:sma200 c)) (:sma200 c))
                0.0)
            0.1)))
