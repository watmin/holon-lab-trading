;; paper-entry.wat — PaperEntry struct
;; Depends on: distances (Distances)
;; A paper trade is a "what if." Every candle, every pair gets one.
;; Both sides (buy and sell) tracked simultaneously.

(require primitives)
(require distances)

(struct paper-entry
  [composed-thought : Vector]  ; the thought at entry
  [entry-price : f64]          ; price when the paper was created
  [entry-atr : f64]            ; volatility at entry
  [distances : Distances]      ; from the exit observer at entry
  [buy-extreme : f64]          ; best price in buy direction so far
  [buy-trail-stop : f64]       ; trailing stop level (from distances.trail)
  [sell-extreme : f64]         ; best price in sell direction so far
  [sell-trail-stop : f64]      ; trailing stop level (from distances.trail)
  [buy-resolved : bool]        ; buy side's stop fired
  [sell-resolved : bool])      ; sell side's stop fired

;; Construct a paper entry at the current price.
;; All four distances matter. trail drives the paper's trailing stops.
;; stop, tp, runner-trail stored for the learning signal at resolution.
(define (make-paper-entry [composed : Vector] [price : f64] [atr-val : f64]
                          [dist : Distances])
  : PaperEntry
  (paper-entry
    composed
    price
    atr-val
    dist
    price                                ; buy-extreme starts at entry
    (* price (- 1.0 (:trail dist)))     ; buy-trail-stop below
    price                                ; sell-extreme starts at entry
    (* price (+ 1.0 (:trail dist)))     ; sell-trail-stop above
    false                                ; buy not yet resolved
    false))                              ; sell not yet resolved

;; Tick a paper entry with the current price.
;; Updates extremes and trail stops. Resolves sides whose stops fire.
(define (tick-paper [pe : PaperEntry] [current-price : f64])
  ;; Buy side: track upward extreme, trail below
  (when (not (:buy-resolved pe))
    (when (> current-price (:buy-extreme pe))
      (set! (:buy-extreme pe) current-price)
      (set! (:buy-trail-stop pe) (* current-price (- 1.0 (:trail (:distances pe))))))
    (when (<= current-price (:buy-trail-stop pe))
      (set! (:buy-resolved pe) true)))

  ;; Sell side: track downward extreme, trail above
  (when (not (:sell-resolved pe))
    (when (< current-price (:sell-extreme pe))
      (set! (:sell-extreme pe) current-price)
      (set! (:sell-trail-stop pe) (* current-price (+ 1.0 (:trail (:distances pe))))))
    (when (>= current-price (:sell-trail-stop pe))
      (set! (:sell-resolved pe) true))))

;; Is this paper fully resolved? (both sides done)
(define (paper-resolved? [pe : PaperEntry])
  : bool
  (and (:buy-resolved pe) (:sell-resolved pe)))

;; Derive optimal distances from tracked extremes (MFE/MAE approximation).
;; Papers don't carry price-history — they use buy-extreme and sell-extreme.
(define (paper-optimal-distances [pe : PaperEntry])
  : Distances
  (let ((entry (:entry-price pe))
        ;; Buy side: how far did price run up? That's the optimal take-profit.
        (buy-mfe (if (= entry 0.0) 0.0 (/ (- (:buy-extreme pe) entry) entry)))
        ;; Sell side: how far did price run down?
        (sell-mfe (if (= entry 0.0) 0.0 (/ (- entry (:sell-extreme pe)) entry)))
        ;; Optimal trail: the distance that would have captured the most residue.
        ;; Approximation: half of the maximum favorable excursion.
        (opt-trail (/ (max buy-mfe sell-mfe) 2.0))
        ;; Optimal stop: distance that would have limited the worst drawdown.
        (opt-stop (max 0.005 (* opt-trail 2.0)))
        ;; Optimal take-profit: the full excursion.
        (opt-tp (max 0.005 (max buy-mfe sell-mfe)))
        ;; Optimal runner-trail: wider than trail.
        (opt-runner (max 0.005 (* opt-trail 2.0))))
    (make-distances
      (max 0.005 opt-trail)
      (max 0.005 opt-stop)
      (max 0.005 opt-tp)
      (max 0.005 opt-runner))))
