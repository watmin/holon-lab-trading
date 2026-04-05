;; ── vocab/harmonics.wat — harmonic price patterns ────────────────
;;
;; Gartley, Bat, Butterfly, Crab — named XABCD patterns defined by
;; Fibonacci ratio constraints between swing points.
;;
;; Each pattern is a template: five swing points (X, A, B, C, D) with
;; specific ratio ranges between legs. The current close acts as the
;; prospective D point.
;;
;; Lens: structure
;;
;; Pure function. Candles in, facts out.

(require facts)

;; ── Swing point detection ─────────────────────────────────────────
;;
;; Local swing highs/lows: indices where the value is strictly greater
;; (or less) than all values within `radius` bars on each side.
;; Returns (index, value) pairs, oldest first.
;;
;; These are the building blocks for XABCD patterns. The harmonic
;; detector needs at least 4 alternating swing points to form a
;; pattern, plus the current close as the prospective completion.

(define (swing-highs values radius)
  "Local maxima with clearance of radius bars on each side."
  (filter (lambda (i)
    (let ((v (nth values i)))
      (and (every? (lambda (j) (< (nth values j) v))
                   (range (- i radius) i))
           (every? (lambda (j) (< (nth values j) v))
                   (range (+ i 1) (+ i radius 1))))))
    (range radius (- (len values) radius))))

(define (swing-lows values radius)
  "Local minima with clearance of radius bars on each side."
  (filter (lambda (i)
    (let ((v (nth values i)))
      (and (every? (lambda (j) (> (nth values j) v))
                   (range (- i radius) i))
           (every? (lambda (j) (> (nth values j) v))
                   (range (+ i 1) (+ i radius 1))))))
    (range radius (- (len values) radius))))

;; ── Zigzag: alternating swing sequence ────────────────────────────
;;
;; Merge swing highs and lows into a single alternating sequence.
;; Each entry: (index, value, :high or :low). Consecutive same-type
;; swings are resolved by keeping the most extreme.

;; ── Harmonic templates ────────────────────────────────────────────
;;
;; Each template: (name, AB/XA range, BC/AB range, CD/AB range, D/XA range)
;; CD measured as extension of AB (not BC). D/XA: retrace < 1.0, extension > 1.0.
;; Bullish: X is low, A is high, D completes low (buy signal)
;; Bearish: X is high, A is low, D completes high (sell signal)
;;
;; Sources: NAGA Academy, IG International, Pro Trading School, AvaTrade
;;
;; Gartley:    AB/XA = ~0.618       BC/AB = 0.382-0.886  CD/AB = 1.130-1.618  D/XA = 0.786 retrace
;; Bat:        AB/XA = 0.382-0.500  BC/AB = 0.382-0.886  CD/AB = 1.618-2.618  D/XA = 0.886 retrace
;; Butterfly:  AB/XA = ~0.786       BC/AB = 0.382-0.886  CD/AB = 1.618-2.240  D/XA = 1.27-1.618 ext
;; Crab:       AB/XA = 0.382-0.618  BC/AB = 0.382-0.886  CD/AB = 2.618-3.618  D/XA = 1.618 ext
;; Deep Crab:  AB/XA = ~0.886       BC/AB = 0.382-0.886  CD/AB = 2.240-3.618  D/XA = 1.618 ext
;; Cypher:     AB/XA = 0.382-0.618  BC/AB = 1.130-1.414  CD/AB = 1.272-2.000  D/XA = 0.786 retrace

;; ── Pattern evaluation ────────────────────────────────────────────

(define RECENT_WINDOWS 3)

(define (zigzag highs lows)
  "Merge swing highs and lows into alternating sequence.
   Consecutive same-type swings resolved by keeping the most extreme."
  (let ((all (sort-by :idx (append
               (map (lambda (h) {:idx (first h) :price (second h) :high? true}) highs)
               (map (lambda (l) {:idx (first l) :price (second l) :high? false}) lows)))))
    (fold (lambda (result s)
      (if (and (not (empty? result)) (= (:high? (last result)) (:high? s)))
          ;; Same type — keep more extreme
          (if (or (and (:high? s) (> (:price s) (:price (last result))))
                  (and (not (:high? s)) (< (:price s) (:price (last result)))))
              (append (butlast result) (list s))
              result)
          (append result (list s))))
      (list) all)))

(define (match-pattern x a b c d x-is-low templates)
  "Match XABCD swing points against harmonic templates.
   Returns list of (name, bullish?, quality) for matching patterns."
  (let ((xa (abs (- a x)))
        (ab (abs (- b a)))
        (bc (abs (- c b)))
        (cd (abs (- d c))))
    (when (and (> xa 1e-10) (> ab 1e-10) (> bc 1e-10))
      (let ((ab-xa (/ ab xa))
            (bc-ab (/ bc ab))
            (cd-ab (/ cd ab))
            (d-xa  (/ (abs (- a d)) xa)))
        (filter some?
          (map (lambda (t)
            (when (and (in-range? ab-xa (:ab-xa t))
                       (in-range? bc-ab (:bc-ab t))
                       (in-range? cd-ab (:cd-ab t))
                       (in-range? d-xa  (:d-xa t)))
              (list (:name t) x-is-low
                    (/ (+ (match-quality ab-xa (:ab-xa t))
                          (match-quality bc-ab (:bc-ab t))
                          (match-quality cd-ab (:cd-ab t))
                          (match-quality d-xa  (:d-xa t))) 4.0))))
            templates))))))

(define (eval-harmonics candles)
  "Detect harmonic XABCD patterns from candle window.
   Returns zone facts for detected patterns + scalar for completion quality."
  (when (>= (len candles) 30)
    (let ((highs (swing-highs (map :high candles) 5))
          (lows  (swing-lows  (map :low candles) 5))
          (close (:close (last candles))))
      (let ((zz (zigzag highs lows)))
        (when (>= (len zz) 4)
          (fold-left (lambda (facts start)
            (when (< (+ start 3) (len zz))
              (let ((x (nth zz start))
                    (a (nth zz (+ start 1)))
                    (b (nth zz (+ start 2)))
                    (c (nth zz (+ start 3))))
                ;; Validate alternation
                (when (and (!= (:high? x) (:high? a))
                           (!= (:high? a) (:high? b))
                           (!= (:high? b) (:high? c)))
                  (let ((matches (match-pattern
                                   (:price x) (:price a) (:price b) (:price c) close
                                   (not (:high? x)) templates)))
                    (append facts
                      (fold-left (lambda (fs m)
                        (let ((zone (format "{}-{}" (first m) (if (second m) "bullish" "bearish"))))
                          (append fs
                            (list (fact/zone "harmonic" zone)
                                  (fact/scalar "harmonic-quality" (nth m 2) 1.0)))))
                        (list) (take 1 matches))))))))
            (list)
            ;; Check the most recent pattern windows
            (take RECENT_WINDOWS (reverse (range 0 (- (len zz) 3))))))))))

;; ── What harmonics does NOT do ────────────────────────────────────
;; - Does NOT predict direction (the pattern implies it — the journal learns it)
;; - Does NOT filter by volume (that's the volume observer's job)
;; - Does NOT combine with other indicators (bundling handles that)
;; - Pure function. Candles in, facts out.
