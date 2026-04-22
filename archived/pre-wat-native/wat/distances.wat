;; ── distances.wat ───────────────────────────────────────────────────
;;
;; Two representations of exit thresholds and the conversion between them.
;; Distances are percentages (from the exit observer — scale-free).
;; Levels are absolute prices (computed by the post from distance × price).
;; Observers think in Distances. Trades execute at Levels.
;; Depends on: nothing (Side is used by distances-to-levels but is a
;; keyword match, not a struct dependency).

(require enums)

;; Distances: percentage of price. Appears on PaperEntry, Proposal, Resolution.
(struct distances
  [trail : f64]                ; trailing stop distance (percentage of price)
  [stop : f64])                ; safety stop distance

;; Levels: absolute price levels. Stored on Trade, updated by step 3c.
(struct levels
  [trail-stop : f64]           ; absolute price level for trailing stop
  [safety-stop : f64])         ; absolute price level for safety stop

;; Convert percentage distances to absolute price levels.
;; Side-dependent: buy stops are below price, sell stops are above.
;; One place to get the signs right.
(define (distances-to-levels [d : Distances] [price : f64] [side : Side])
  : Levels
  (match side
    :buy  (make-levels
            (- price (* price (:trail d)))    ; trail-stop below for buys
            (- price (* price (:stop d))))    ; safety-stop below for buys
    :sell (make-levels
            (+ price (* price (:trail d)))    ; trail-stop above for sells
            (+ price (* price (:stop d))))))  ; safety-stop above for sells
