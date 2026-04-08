; paper-entry.wat — a hypothetical trade inside a broker.
;
; Depends on: distances, enums (Direction).
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
(require enums)

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

;; ── Constructor ─────────────────────────────────────────────────────────
;;
;; At entry: both extremes start at entry-price. Trail stops are
;; computed from the trail distance as a percentage of entry price.
;; Buy side: stop below. Sell side: stop above.

(define (make-paper-entry [composed-thought : Vector]
                          [entry-price : f64]
                          [entry-atr : f64]
                          [distances : Distances])
  : PaperEntry
  (let* ((trail-pct  (:trail distances))
         ;; Buy trail stop: price drops trail-pct from entry → triggered
         (buy-stop   (* entry-price (- 1.0 trail-pct)))
         ;; Sell trail stop: price rises trail-pct from entry → triggered
         (sell-stop  (* entry-price (+ 1.0 trail-pct))))
    (paper-entry
      composed-thought
      entry-price
      entry-atr
      distances
      entry-price          ; buy-extreme starts at entry
      buy-stop             ; buy trail stop
      entry-price          ; sell-extreme starts at entry
      sell-stop            ; sell trail stop
      false                ; buy not resolved
      false)))             ; sell not resolved

;; ── tick-paper — advance the paper by one candle ────────────────────────
;;
;; Updates extremes and trail stops. Checks if either side triggered.
;; Returns the updated paper. Functional — the broker replaces in deque.
;;
;; The trailing stop ratchets: it only moves in the favorable direction.
;; Buy side: extreme is the highest price seen. Stop trails below it.
;; Sell side: extreme is the lowest price seen. Stop trails above it.

(define (tick-paper [paper : PaperEntry]
                    [current-price : f64])
  : PaperEntry
  (let* ((trail-pct (:trail (:distances paper)))

         ;; ── Buy side ──
         ;; New extreme: highest price seen (favorable for buy)
         (new-buy-extreme
           (if (:buy-resolved paper)
               (:buy-extreme paper)
               (max (:buy-extreme paper) current-price)))

         ;; Trail stop ratchets up with the extreme
         (new-buy-stop
           (if (:buy-resolved paper)
               (:buy-trail-stop paper)
               (max (:buy-trail-stop paper)
                    (* new-buy-extreme (- 1.0 trail-pct)))))

         ;; Buy side resolves when price drops through the trailing stop
         (new-buy-resolved
           (or (:buy-resolved paper)
               (<= current-price new-buy-stop)))

         ;; ── Sell side ──
         ;; New extreme: lowest price seen (favorable for sell)
         (new-sell-extreme
           (if (:sell-resolved paper)
               (:sell-extreme paper)
               (min (:sell-extreme paper) current-price)))

         ;; Trail stop ratchets down with the extreme
         (new-sell-stop
           (if (:sell-resolved paper)
               (:sell-trail-stop paper)
               (min (:sell-trail-stop paper)
                    (* new-sell-extreme (+ 1.0 trail-pct)))))

         ;; Sell side resolves when price rises through the trailing stop
         (new-sell-resolved
           (or (:sell-resolved paper)
               (>= current-price new-sell-stop))))

    (update paper
      :buy-extreme     new-buy-extreme
      :buy-trail-stop  new-buy-stop
      :buy-resolved    new-buy-resolved
      :sell-extreme    new-sell-extreme
      :sell-trail-stop new-sell-stop
      :sell-resolved   new-sell-resolved)))

;; ── fully-resolved? — both sides done ───────────────────────────────────

(define (fully-resolved? [paper : PaperEntry])
  : bool
  (and (:buy-resolved paper) (:sell-resolved paper)))

;; ── paper-pnl — compute the outcome for one side ────────────────────────
;;
;; direction: which side we're evaluating.
;; Returns: f64 — positive for grace, negative for violence.

(define (paper-pnl [paper : PaperEntry]
                   [direction : Direction])
  : f64
  (match direction
    ;; Buy side: profit = (extreme - entry) / entry
    (:up   (/ (- (:buy-extreme paper) (:entry-price paper))
              (:entry-price paper)))
    ;; Sell side: profit = (entry - extreme) / entry
    (:down (/ (- (:entry-price paper) (:sell-extreme paper))
              (:entry-price paper)))))
