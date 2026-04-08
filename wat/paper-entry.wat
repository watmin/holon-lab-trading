; paper-entry.wat — a hypothetical trade inside a broker.
;
; Depends on: Distances.
;
; A paper trade is a "what if." Every candle, every broker gets one.
; Both sides (buy and sell) are tracked simultaneously. When both sides
; resolve (their trailing stops fire), the paper teaches the system:
; what distance would have been optimal?
;
; distances.trail drives the paper's trailing stops (buy-trail-stop,
; sell-trail-stop). The other three (stop, tp, runner-trail) are stored
; for the learning signal — when the paper resolves, the Resolution
; carries optimal-distances (what hindsight says was best). The predicted
; distances at entry vs the optimal distances at resolution IS the
; teaching: "you predicted trail=0.015 but optimal was 0.022."

(require primitives)
(require distances)

;; ── Struct ──────────────────────────────────────────────────────────────

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
