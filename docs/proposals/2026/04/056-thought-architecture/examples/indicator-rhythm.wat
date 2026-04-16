;; indicator-rhythm.wat — the generic function. Same for every indicator.
;; Same for every observer. The atom name and the extractor are the only
;; parameters. Returns one rhythm vector.
;;
;; One function. Three callers: market observer, position observer Core,
;; position observer Full. Different indicators. Same algorithm.

(define (indicator-rhythm window atom-name extract-fn dims)

  ;; Step 1: each candle → value + delta from previous candle
  ;; First candle has no delta — just the value.
  (let facts
    (map-indexed (lambda (i candle)
      (let value (extract-fn candle))
      (if (= i 0)
        ;; first: value only
        (bind (atom atom-name) (linear value 1.0))
        ;; rest: value + delta
        (let prev (extract-fn (nth window (- i 1))))
        (bundle
          (bind (atom atom-name)
                (linear value 1.0))
          (bind (atom (str atom-name "-delta"))
                (linear (- value prev) 1.0)))))
    window))

  ;; Step 2: trigrams — 3 consecutive candle facts, internally ordered
  ;; "candle t-2 state → candle t-1 state → candle t state"
  (let tris
    (windows 3 facts (lambda (a b c)
      (bind (bind a (permute b 1)) (permute c 2)))))

  ;; Step 3: bigram-pairs — "this pattern then that pattern"
  (let pairs
    (windows 2 tris (lambda (a b)
      (bind a b))))

  ;; Step 4: trim to capacity, bundle → one vector
  ;; sqrt(D) pairs max. Overlapping windows mean N pairs cover N+2 candles.
  ;; 100 pairs → 103 candles at D=10,000.
  (let budget (floor (sqrt dims)))
  (bundle (take-right budget pairs)))

;; ═══ Example: RSI over 7 candles ════════════════════════════════════
;; Showing the full expansion of indicator-rhythm for one indicator.

;; The window: RSI values [0.45, 0.48, 0.55, 0.62, 0.68, 0.66, 0.63]
;;                          ↑ rising ──────────────────→ ↑ stalling → falling

;; Step 1: facts with deltas
(define rsi-0 (bind (atom "rsi") (linear 0.45 1.0)))

(define rsi-1 (bundle
  (bind (atom "rsi")       (linear 0.48 1.0))
  (bind (atom "rsi-delta") (linear 0.03 1.0))))       ;; +0.03

(define rsi-2 (bundle
  (bind (atom "rsi")       (linear 0.55 1.0))
  (bind (atom "rsi-delta") (linear 0.07 1.0))))       ;; +0.07 accelerating

(define rsi-3 (bundle
  (bind (atom "rsi")       (linear 0.62 1.0))
  (bind (atom "rsi-delta") (linear 0.07 1.0))))       ;; +0.07 same rate

(define rsi-4 (bundle
  (bind (atom "rsi")       (linear 0.68 1.0))
  (bind (atom "rsi-delta") (linear 0.06 1.0))))       ;; +0.06 decelerating

(define rsi-5 (bundle
  (bind (atom "rsi")       (linear 0.66 1.0))
  (bind (atom "rsi-delta") (linear -0.02 1.0))))      ;; -0.02 REVERSAL

(define rsi-6 (bundle
  (bind (atom "rsi")       (linear 0.63 1.0))
  (bind (atom "rsi-delta") (linear -0.03 1.0))))      ;; -0.03 falling faster

;; Step 2: trigrams (5 from 7 candles)
(define tri-0 (bind (bind rsi-0 (permute rsi-1 1)) (permute rsi-2 2)))  ;; rising + accelerating
(define tri-1 (bind (bind rsi-1 (permute rsi-2 1)) (permute rsi-3 2)))  ;; accelerating + steady
(define tri-2 (bind (bind rsi-2 (permute rsi-3 1)) (permute rsi-4 2)))  ;; steady + decelerating
(define tri-3 (bind (bind rsi-3 (permute rsi-4 1)) (permute rsi-5 2)))  ;; decel + REVERSAL
(define tri-4 (bind (bind rsi-4 (permute rsi-5 1)) (permute rsi-6 2)))  ;; reversal + falling

;; Step 3: bigram-pairs (4 from 5 trigrams)
(define pair-0 (bind tri-0 tri-1))  ;; acceleration phase
(define pair-1 (bind tri-1 tri-2))  ;; momentum fading
(define pair-2 (bind tri-2 tri-3))  ;; the turn
(define pair-3 (bind tri-3 tri-4))  ;; reversal confirmed

;; Step 4: rhythm — one vector
(define rsi-rhythm (bundle pair-0 pair-1 pair-2 pair-3))

;; The reckoner sees: "RSI accelerated, then decelerated, then reversed."
;; The deltas carry the causality: +0.07 → +0.07 → +0.06 → -0.02 → -0.03.
;; The trigrams capture the local shape. The pairs capture the transitions.
;; The bundle holds the full movie. The cosine reads the gestalt.
