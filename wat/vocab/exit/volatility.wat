;; volatility.wat — ATR regime, ATR ratio, squeeze ratio
;;
;; Depends on: candle
;; Domain: exit (ExitLens :volatility)
;;
;; Volatility determines distance. High ATR = wider stops.
;; The exit observer learns the relationship between volatility
;; state and optimal exit distance.

(require primitives)
(require enums)       ; ThoughtAST constructors
(require candle)

;; ATR ratio (atr-r) — pre-computed on Candle. ATR / close.
;; Log-encoded because ratio. The difference between 1% and 2% ATR
;; matters more than 10% and 11%.
;;
;; ATR rate of change — how is volatility changing?
;; Pre-computed on Candle at 6 and 12 period scales. Signed.
;; Positive = expanding. Negative = contracting.
;;
;; Squeeze ratio — bb-width / keltner-width. Continuous.
;; < 1.0 = BB inside Keltner (volatility compressed). > 1.0 = BB wider.
;; The ratio preserves how MUCH compression, not just whether.
;; Log-encoded because ratio.
;;
;; BB width — band width as fraction of price. Log-encoded.

;; rune:sever(overlap) — exit-bb-width encodes the same Candle field as
;; market keltner's bb-width. Different atom names, different observer domains.
;; Market observers and exit observers live in separate subspaces — they
;; never meet in the same bundle. The overlap is by design.

(define (encode-exit-volatility-facts [candle : Candle])
  : Vec<ThoughtAST>
  (let* ((kelt-width (- (:kelt-upper candle) (:kelt-lower candle))))
    ;; Guard: skip squeeze facts during Keltner warmup (kelt values are zero)
    (if (> (:kelt-upper candle) 0.0)
      (let* ((squeeze-ratio (/ (:bb-width candle) (max kelt-width 0.0001))))
        (list
          (Log "exit-atr-ratio" (max (:atr-r candle) 0.0001))
          (Linear "exit-atr-roc-6" (:atr-roc-6 candle) 1.0)
          (Linear "exit-atr-roc-12" (:atr-roc-12 candle) 1.0)
          (Log "exit-squeeze-ratio" (max squeeze-ratio 0.0001))
          (Log "exit-bb-width" (max (:bb-width candle) 0.0001))))
      ;; Warmup: only ATR facts (ATR warms up faster than Keltner)
      (list
        (Log "exit-atr-ratio" (max (:atr-r candle) 0.0001))
        (Linear "exit-atr-roc-6" (:atr-roc-6 candle) 1.0)
        (Linear "exit-atr-roc-12" (:atr-roc-12 candle) 1.0)))))
