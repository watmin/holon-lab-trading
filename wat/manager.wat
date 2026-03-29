;; ── manager.wat ─────────────────────────────────────────────────────
;;
;; The manager thinks in expert opinions, not candle data.
;; Its vocabulary = its experts + panel shape + market context + time.
;; Its label = raw price direction (Buy if price up, Sell if price down).
;; Its discriminant learns which SHAPES of signed opinion precede
;; up-moves vs down-moves. The flip emerges geometrically.
;;
;; The manager does NOT encode candles. It does NOT see indicators.
;; It reads the enterprise and decides.

;; ── Manager's atoms ─────────────────────────────────────────────────

;; Expert identity atoms (one per expert)
(atom "momentum")
(atom "structure")
(atom "volume")
(atom "narrative")
(atom "regime")
(atom "generalist")

;; Panel-level atoms (emergent properties of the collective)
(atom "panel-agreement")    ; fraction of proven experts aligned on direction
(atom "panel-energy")       ; mean conviction magnitude across proven experts
(atom "panel-divergence")   ; spread of conviction magnitudes
(atom "panel-coherence")    ; geometric similarity between expert thought vectors
(atom "panel-delta")        ; what changed since last candle (via difference)

;; Context atoms
(atom "market-volatility")  ; ATR right now
(atom "disc-strength")      ; generalist's discriminant quality
(atom "hour-of-day")        ; which 4-hour block (h00..h20)
(atom "day-of-week")        ; which trading session

;; ── Per-expert encoding ─────────────────────────────────────────────
;;
;; Each proven expert contributes one fact to the manager's thought.
;; GATED: only proven experts are included. Silence, not noise.
;;
;; The encoding is signed: BUY lean uses the expert atom as-is.
;; SELL lean uses (permute expert-atom 1). This makes BUY@0.25
;; orthogonal to SELL@0.25 in the hyperspace.

(define (encode-expert expert-atom raw-cos)
  (let ((magnitude (encode-log (abs raw-cos)))
        (role (if (>= raw-cos 0.0)
                  expert-atom                    ; BUY lean
                  (permute expert-atom 1))))      ; SELL lean
    (bind role magnitude)))

;; Example: momentum says BUY at conviction 0.25
;; → (bind momentum-atom (encode-log 0.25))
;;
;; Example: structure says SELL at conviction 0.18
;; → (bind (permute structure-atom 1) (encode-log 0.18))

;; ── Panel shape ─────────────────────────────────────────────────────
;;
;; Emergent properties of the expert collective. These tell the
;; manager about the PATTERN of agreement, not just who said what.

(define (panel-shape proven-experts)
  (let* ((buys    (count (lambda (e) (> (cos e) 0)) proven-experts))
         (total   (length proven-experts))
         (agree   (/ (max buys (- total buys)) total))   ; 0.5=split, 1.0=unanimous
         (energy  (mean (map conviction proven-experts)))
         (spread  (stddev (map conviction proven-experts)))
         (coherence (mean-pairwise-cosine (map thought-vec proven-experts))))
    (bundle
      (bind panel-agreement (encode-log agree))
      (bind panel-energy (encode-log energy))
      (bind panel-divergence (encode-log spread))
      (bind panel-coherence (encode-log coherence)))))

;; ── Context ─────────────────────────────────────────────────────────

(define (market-context candle generalist-journal)
  (bundle
    (bind market-volatility (encode-log (atr candle)))
    (bind disc-strength (encode-log (disc-strength generalist-journal)))
    (bind hour-of-day (atom (hour-block candle)))       ; h00..h20
    (bind day-of-week (atom (session candle)))))         ; asian/european/us/off

;; ── Motion ──────────────────────────────────────────────────────────
;;
;; The manager sees not just where the panel IS, but where it MOVED.
;; difference(prev-thought, current-thought) encodes structural change.

(define (motion current-thought prev-thought)
  (if prev-thought
      (bind panel-delta (difference prev-thought current-thought))
      nothing))

;; ── Complete manager thought ────────────────────────────────────────

(define (manager-thought proven-experts candle generalist prev-thought)
  (let ((expert-facts  (map encode-expert (filter proven? experts)))
        (shape         (panel-shape proven-experts))
        (context       (market-context candle generalist))
        (delta         (motion (bundle expert-facts shape context) prev-thought)))
    (bundle expert-facts shape context delta)))

;; ── Learning ────────────────────────────────────────────────────────
;;
;; Label = raw price direction at horizon.
;; Buy = price went up. Sell = price went down.
;; The manager maps signed expert configurations → actual direction.
;; The flip emerges: the Sell prototype accumulates configurations
;; where experts said BUY but the price went DOWN.
;;
;; (observe manager-journal manager-thought
;;   (if (> price-at-horizon entry-price) Buy Sell)
;;   1.0)

;; ── Gate ─────────────────────────────────────────────────────────────
;;
;; The manager's own proof: does its conviction-accuracy curve validate?
;; The treasury deploys only when the manager has proven profitable
;; direction prediction from the intensity patterns.
;;
;; (gate manager-journal manager-curve 0.52)
;; → (if proven (emit direction conviction) silence)

;; ── What the manager does NOT do ────────────────────────────────────
;;
;; - Does NOT encode candles
;; - Does NOT see indicators directly
;; - Does NOT flip predictions (the flip emerges from the geometry)
;; - Does NOT average expert opinions (the shape matters, not the mean)
;; - Does NOT know about costs (that's the treasury's domain)
