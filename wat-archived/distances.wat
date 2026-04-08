;; distances.wat — two representations of exit thresholds
;;
;; Depends on: nothing
;;
;; Distances are percentages (from the exit observer — scale-free).
;; Levels are absolute prices (from the post — computed from distance × price).
;; Observers think in Distances. Trades execute at Levels. Different types
;; because they are different concepts with the same four fields.

(require primitives)

;; ── Distances — percentages from the exit observer ───────────────────
(struct distances
  [trail : f64]                ; trailing stop distance (percentage of price)
  [stop : f64]                 ; safety stop distance
  [tp : f64]                   ; take-profit distance
  [runner-trail : f64])        ; runner trailing stop distance (wider than trail,
                               ; because the cost of stopping out a runner is zero)

;; ── Levels — absolute prices computed by the post ────────────────────
;; distance × current price → level
;; Trade stores Levels. Proposal carries Distances.
(struct levels
  [trail-stop : f64]           ; absolute price level for trailing stop
  [safety-stop : f64]          ; absolute price level for safety stop
  [take-profit : f64]          ; absolute price level for take-profit
  [runner-trail-stop : f64])   ; absolute price level for runner trailing stop
