;; indicator-rhythm.wat — the generic function. Same for every indicator.
;; Same for every observer. The atom name, extractor, and encoding mode
;; are parameters. Returns one rhythm vector.
;;
;; Two variants:
;;   indicator-rhythm    — for continuous values (thermometer + delta)
;;   circular-rhythm     — for periodic values (circular, no delta)
;;
;; The atom binds the WHOLE rhythm, not each candle's fact.
;; Beckman: factor the constant out of the per-candle encoding.

;; ═══ Continuous indicators (thermometer + delta) ════════════════════

(define (indicator-rhythm window atom-name extract-fn value-min value-max delta-range dims)

  ;; Step 1: each candle → value + delta from previous candle
  ;; No atom binding here — the atom wraps the final rhythm.
  (let facts
    (map-indexed (lambda (i candle)
      (let value (extract-fn candle))
      (if (= i 0)
        ;; first: value only
        (thermometer value value-min value-max)
        ;; rest: value + delta
        (let prev (extract-fn (nth window (- i 1))))
        (bundle
          (thermometer value value-min value-max)
          (bind (atom "delta")
                (thermometer (- value prev) (- 0 delta-range) delta-range)))))
    window))

  ;; Step 2: trigrams
  (let tris (windows 3 facts (lambda (a b c)
    (bind (bind a (permute b 1)) (permute c 2)))))

  ;; Step 3: bigram-pairs
  (let pairs (windows 2 tris (lambda (a b) (bind a b))))

  ;; Step 4: trim + bundle → raw rhythm
  (let budget (floor (sqrt dims)))
  (let raw (bundle (take-right budget pairs)))

  ;; Step 5: bind the atom to the whole rhythm — one bind, not N
  (bind (atom atom-name) raw))

;; ═══ Periodic indicators (circular, no delta) ═══════════════════════

(define (circular-rhythm window atom-name extract-fn period dims)

  ;; Each candle → circular encoding of the value. No delta.
  ;; The wrap from 23→0 is handled by circular similarity.
  ;; The progression is captured by the trigram positions.
  (let facts
    (map (lambda (candle)
      (circular (extract-fn candle) period))
    window))

  ;; Trigrams, pairs, trim — same as indicator-rhythm
  (let tris (windows 3 facts (lambda (a b c)
    (bind (bind a (permute b 1)) (permute c 2)))))
  (let pairs (windows 2 tris (lambda (a b) (bind a b))))
  (let budget (floor (sqrt dims)))
  (let raw (bundle (take-right budget pairs)))

  (bind (atom atom-name) raw))

;; ═══ Example: RSI over 7 candles (thermometer) ═════════════════════
;; Values: [0.45, 0.48, 0.55, 0.62, 0.68, 0.66, 0.63]
;;          ↑ rising ──────────────────→ ↑ stalling → falling

;; Step 1: facts — NO atom binding per candle
(define rsi-0 (thermometer 0.45 0.0 100.0))

(define rsi-1 (bundle
  (thermometer 0.48 0.0 100.0)
  (bind (atom "delta") (thermometer 0.03 -10.0 10.0))))

(define rsi-2 (bundle
  (thermometer 0.55 0.0 100.0)
  (bind (atom "delta") (thermometer 0.07 -10.0 10.0))))   ;; accelerating

(define rsi-3 (bundle
  (thermometer 0.62 0.0 100.0)
  (bind (atom "delta") (thermometer 0.07 -10.0 10.0))))   ;; same rate

(define rsi-4 (bundle
  (thermometer 0.68 0.0 100.0)
  (bind (atom "delta") (thermometer 0.06 -10.0 10.0))))   ;; decelerating

(define rsi-5 (bundle
  (thermometer 0.66 0.0 100.0)
  (bind (atom "delta") (thermometer -0.02 -10.0 10.0))))  ;; REVERSAL

(define rsi-6 (bundle
  (thermometer 0.63 0.0 100.0)
  (bind (atom "delta") (thermometer -0.03 -10.0 10.0))))  ;; falling faster

;; Step 2: trigrams
(define tri-0 (bind (bind rsi-0 (permute rsi-1 1)) (permute rsi-2 2)))
(define tri-1 (bind (bind rsi-1 (permute rsi-2 1)) (permute rsi-3 2)))
(define tri-2 (bind (bind rsi-2 (permute rsi-3 1)) (permute rsi-4 2)))
(define tri-3 (bind (bind rsi-3 (permute rsi-4 1)) (permute rsi-5 2)))
(define tri-4 (bind (bind rsi-4 (permute rsi-5 1)) (permute rsi-6 2)))

;; Step 3: bigram-pairs
(define pair-0 (bind tri-0 tri-1))
(define pair-1 (bind tri-1 tri-2))
(define pair-2 (bind tri-2 tri-3))
(define pair-3 (bind tri-3 tri-4))

;; Step 4: raw rhythm
(define raw-rhythm (bundle pair-0 pair-1 pair-2 pair-3))

;; Step 5: bind atom to the WHOLE rhythm — one bind
(define rsi-rhythm (bind (atom "rsi") raw-rhythm))

;; The atom "rsi" appears ONCE. Not 7 times.
;; The raw rhythm captures the progression. The atom identifies it.
;; Two different indicators with the same value progression produce
;; orthogonal rhythm vectors because the atom is different.

;; ═══ Example: hour over 5 candles (circular) ════════════════════════
;; Values: [22, 23, 0, 1, 2] — wraps at midnight

(define hour-0 (circular 22.0 24.0))
(define hour-1 (circular 23.0 24.0))
(define hour-2 (circular 0.0 24.0))    ;; midnight — circular: near 23, not -23
(define hour-3 (circular 1.0 24.0))
(define hour-4 (circular 2.0 24.0))

;; Trigrams — hour 23 and hour 0 are nearby in circular space
(define h-tri-0 (bind (bind hour-0 (permute hour-1 1)) (permute hour-2 2)))
(define h-tri-1 (bind (bind hour-1 (permute hour-2 1)) (permute hour-3 2)))
(define h-tri-2 (bind (bind hour-2 (permute hour-3 1)) (permute hour-4 2)))

(define h-pair-0 (bind h-tri-0 h-tri-1))
(define h-pair-1 (bind h-tri-1 h-tri-2))

(define hour-rhythm (bind (atom "hour") (bundle h-pair-0 h-pair-1)))

;; No delta. No wrap problem. The circular encoding handles proximity.
;; The trigram handles progression. The atom identifies it.
