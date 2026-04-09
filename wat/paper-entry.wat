;; paper-entry.wat — PaperEntry struct
;; Depends on: distances.wat

(require primitives)
(require distances)

;; ── PaperEntry ─────────────────────────────────────────────────────
;; A "what if" trade. Every candle, every broker gets one.
;; Both sides (buy and sell) are tracked simultaneously.

(struct paper-entry
  [composed-thought : Vector]
  [entry-price : f64]
  [entry-atr : f64]
  [distances : Distances]
  [buy-extreme : f64]
  [buy-trail-stop : f64]
  [sell-extreme : f64]
  [sell-trail-stop : f64]
  [buy-resolved : bool]
  [sell-resolved : bool])

(define (make-paper-entry [composed-thought : Vector]
                          [entry-price : f64]
                          [entry-atr : f64]
                          [distances : Distances])
  : PaperEntry
  (let ((trail-dist (:trail distances))
        (buy-stop (* entry-price (- 1.0 trail-dist)))
        (sell-stop (* entry-price (+ 1.0 trail-dist))))
    (paper-entry
      composed-thought entry-price entry-atr distances
      entry-price buy-stop    ; buy-extreme = entry, buy-trail-stop below
      entry-price sell-stop   ; sell-extreme = entry, sell-trail-stop above
      false false)))

;; ── tick-paper — advance paper by one price ────────────────────────
;; Returns true if both sides are now resolved.

(define (tick-paper [paper : PaperEntry] [price : f64])
  : bool
  ;; Buy side: track highest price, trail stop below
  (when (not (:buy-resolved paper))
    (when (> price (:buy-extreme paper))
      (set! paper :buy-extreme price)
      (set! paper :buy-trail-stop
        (* price (- 1.0 (:trail (:distances paper))))))
    (when (<= price (:buy-trail-stop paper))
      (set! paper :buy-resolved true)))

  ;; Sell side: track lowest price, trail stop above
  (when (not (:sell-resolved paper))
    (when (< price (:sell-extreme paper))
      (set! paper :sell-extreme price)
      (set! paper :sell-trail-stop
        (* price (+ 1.0 (:trail (:distances paper))))))
    (when (>= price (:sell-trail-stop paper))
      (set! paper :sell-resolved true)))

  (and (:buy-resolved paper) (:sell-resolved paper)))

;; ── paper-optimal-distances — derive from tracked extremes ─────────
;; MFE/MAE approximation — simpler than full replay

(define (paper-optimal-buy-distances [paper : PaperEntry])
  : Distances
  (let ((entry (:entry-price paper))
        (mfe (/ (- (:buy-extreme paper) entry) entry))
        (mae (/ (- entry (:sell-extreme paper)) entry))
        (opt-trail (max (* mfe 0.3) 0.002))
        (opt-stop (max (* mae 1.5) 0.005))
        (opt-tp (max (* mfe 0.8) 0.005))
        (opt-runner (max (* mfe 0.5) 0.005)))
    (make-distances opt-trail opt-stop opt-tp opt-runner)))

(define (paper-optimal-sell-distances [paper : PaperEntry])
  : Distances
  (let ((entry (:entry-price paper))
        (mfe (/ (- entry (:sell-extreme paper)) entry))
        (mae (/ (- (:buy-extreme paper) entry) entry))
        (opt-trail (max (* mfe 0.3) 0.002))
        (opt-stop (max (* mae 1.5) 0.005))
        (opt-tp (max (* mfe 0.8) 0.005))
        (opt-runner (max (* mfe 0.5) 0.005)))
    (make-distances opt-trail opt-stop opt-tp opt-runner)))
