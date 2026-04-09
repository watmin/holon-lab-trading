;; vocab/market/ichimoku.wat — cloud zone, TK cross.
;;
;; Depends on: Candle, ThoughtAST.
;;
;; Pure: candle in, ASTs out. No state.
;; Cloud position is conditional — above, below, or inside the cloud.
;; TK cross delta is the signed change from previous candle.

(require primitives)
(require candle)
(require enums)     ; ThoughtAST

;; ── encode-ichimoku-facts ───────────────────────────────────────────────

(define (encode-ichimoku-facts [c : Candle])
  : Vec<ThoughtAST>
  (let* ((cloud-thickness (- (:cloud-top c) (:cloud-bottom c)))
         (facts (list)))

    ;; Cloud position — conditional on where close is relative to cloud
    (cond
      ;; Above cloud — how far above (log, positive)
      ((> (:close c) (:cloud-top c))
        (when (> (:cloud-top c) 0.0)
          (push! facts (Log "ichi-above-cloud"
                            (/ (- (:close c) (:cloud-top c)) (:cloud-top c))))))
      ;; Below cloud — how far below (log, positive)
      ((< (:close c) (:cloud-bottom c))
        (when (> (:cloud-bottom c) 0.0)
          (push! facts (Log "ichi-below-cloud"
                            (/ (- (:cloud-bottom c) (:close c)) (:cloud-bottom c))))))
      ;; Inside cloud — position within as linear [-1, 1]
      (else
        (if (> cloud-thickness 0.0)
            (push! facts (Linear "ichi-in-cloud"
                                 (/ (- (:close c) (:cloud-bottom c)) cloud-thickness)
                                 1.0))
            (push! facts (Linear "ichi-in-cloud" 0.5 1.0)))))

    ;; TK cross delta — signed change of (tenkan - kijun) from prev candle
    (push! facts (Linear "tk-cross-delta" (:tk-cross-delta c) 0.01))

    ;; Cloud thickness as volatility signal
    (when (> (:close c) 0.0)
      (push! facts (Log "ichi-cloud-width" (/ cloud-thickness (:close c)))))

    facts))
