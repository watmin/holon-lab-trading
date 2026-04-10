;; ── vocab/market/ichimoku.wat ────────────────────────────────────
;;
;; Cloud position, TK cross, distances. Pure function: candle in, ASTs out.
;; atoms: cloud-position, cloud-thickness, tk-cross-delta, tk-spread,
;;        tenkan-dist, kijun-dist
;; Depends on: candle.

(require candle)

(define (encode-ichimoku-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((close (:close c))
        (cloud-top (:cloud-top c))
        (cloud-bottom (:cloud-bottom c))
        (cloud-mid (/ (+ cloud-top cloud-bottom) 2.0))
        (cloud-width (- cloud-top cloud-bottom))
        (tenkan (:tenkan-sen c))
        (kijun (:kijun-sen c)))
    (list
      ;; Cloud position: where price is relative to the cloud.
      ;; Above cloud = positive, below = negative. Signed percentage distance
      ;; from cloud midpoint, normalized by cloud width (or ATR if cloud is thin).
      '(Linear "cloud-position"
               (if (> cloud-width 0.0)
                   (clamp (/ (- close cloud-mid) (max cloud-width (* close 0.001)))
                          -1.0 1.0)
                   (clamp (/ (- close cloud-mid) (* close 0.01))
                          -1.0 1.0))
               1.0)

      ;; Cloud thickness: width as percentage of price. Unbounded positive. Log-encoded.
      '(Log "cloud-thickness" (max 0.0001 (/ cloud-width close)))

      ;; TK cross delta: pre-computed on candle. Signed rate of change of spread.
      ;; [-1, 1] range.
      '(Linear "tk-cross-delta" (clamp (:tk-cross-delta c) -1.0 1.0) 1.0)

      ;; TK spread: (tenkan - kijun) / price. Signed. Linear.
      '(Linear "tk-spread"
               (clamp (/ (- tenkan kijun) (* close 0.01))
                       -1.0 1.0)
               1.0)

      ;; Tenkan distance: (close - tenkan) / price. Signed percentage.
      '(Linear "tenkan-dist"
               (clamp (/ (- close tenkan) (* close 0.01))
                       -1.0 1.0)
               1.0)

      ;; Kijun distance: (close - kijun) / price. Signed percentage.
      '(Linear "kijun-dist"
               (clamp (/ (- close kijun) (* close 0.01))
                       -1.0 1.0)
               1.0))))
