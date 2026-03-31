;; ── manager.wat ─────────────────────────────────────────────────────
;;
;; The manager thinks in expert opinions, not candle data.
;; Its vocabulary = its experts + panel shape + market context + time.
;; Its label = raw price direction (Buy if price up, Sell if price down).
;; Its discriminant learns which SHAPES of signed opinion precede
;; up-moves vs down-moves. The flip emerges geometrically.
;;
;; The manager does NOT encode candles. It does NOT see indicators.
;; It reads expert predictions passed by the fold. The fold decides
;; which experts to include (proof gates filter upstream).

(require std/statistics)

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
;; The encoding is signed: BUY lean binds (atom "buy") with magnitude.
;; SELL lean binds (atom "sell") with magnitude. Separate action atoms
;; make BUY@0.25 orthogonal to SELL@0.25 in the hyperspace.

;; Guard: below 3σ noise floor (3/sqrt(dims)), the expert has no opinion.
;; Silence, not forced direction. The noise floor is a property of the
;; hyperspace geometry, not a tuned parameter.

(define (encode-expert expert-atom raw-cos gate-status dims)
  (let ((noise-floor (/ 3.0 (sqrt dims))))
    (if (< (abs raw-cos) noise-floor)
        nothing                                   ; silence — no opinion
        (let ((magnitude (encode-linear (abs raw-cos) 1.0))
              (action    (if (>= raw-cos 0.0) (atom "buy") (atom "sell"))))
          ;; Two facts. Composed, not complected.
          ;; Fact 1: the opinion (direction + magnitude)
          ;; Fact 2: the credibility (proven | tentative)
          ;; The discriminant sees both and learns what each means independently.
          (list
            (bind expert-atom (bind action magnitude))   ; opinion
            (bind expert-atom gate-status))))))           ; credibility

;; Example: proven momentum says BUY at magnitude 0.25
;; → (bind momentum (bind buy (encode-linear 0.25 1.0)))   ; opinion
;; → (bind momentum proven)                                  ; credibility
;;
;; Example: tentative volume at magnitude 0.08
;; → (bind volume (bind buy (encode-linear 0.08 1.0)))      ; opinion
;; → (bind volume tentative)                                  ; credibility
;;
;; The opinion's magnitude is NOT affected by credibility.
;; The discriminant learns: "tentative volume buy at 0.08" may mean
;; nothing, or it may be a signal about to prove itself. The data decides.
;;
;; Additional per-expert facts:
;; → (bind (bind expert reliability) (encode-linear (- accuracy 0.4) 1.0))
;; → (bind (bind expert tenure) (encode-log resolved-count))

;; ── Panel shape ─────────────────────────────────────────────────────
;;
;; Emergent properties of the expert collective. These tell the
;; manager about the PATTERN of agreement, not just who said what.

; rune:gaze(phantom) — mean-pairwise-cosine is not in the wat language
(define (panel-shape proven-experts)
  (let* ((buys    (count (lambda (e) (> (cos e) 0)) proven-experts))
         (total   (length proven-experts))
         (agree   (/ (max buys (- total buys)) total))   ; 0.5=split, 1.0=unanimous
         (energy  (mean (map conviction proven-experts)))
         (spread  (stddev (map conviction proven-experts)))
         (coherence (mean-pairwise-cosine (map thought-vec proven-experts))))
    (bundle
      (bind panel-agreement (encode-linear agree 1.0))       ; [0,1] fraction
      (bind panel-energy (encode-linear energy 1.0))         ; [0,1] fraction
      (bind panel-divergence (encode-linear spread 1.0))     ; [0,1] fraction
      (bind panel-coherence (encode-linear coherence 1.0))))) ; [0,1] fraction

;; ── Context ─────────────────────────────────────────────────────────

(define (market-context candle generalist-journal)
  (bundle
    (bind market-volatility (encode-log (atr candle)))            ; orders of magnitude — log correct
    (bind disc-strength (encode-log (disc-strength generalist)))  ; orders of magnitude — log correct
    (bind hour-of-day (encode-circular hour 24.0))               ; hour 23 near hour 0
    (bind day-of-week (encode-circular day-of-week 7.0))))       ; sunday near monday

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

;; ── Labels ──────────────────────────────────────────────────────────

(define manager-journal (journal "manager" dims refit-interval))
(define buy  (register manager-journal "Buy"))
(define sell (register manager-journal "Sell"))

;; ── Learning ────────────────────────────────────────────────────────
;;
;; Label = raw price direction at horizon.
;; Buy = price went up. Sell = price went down.
;; The manager maps signed expert configurations → actual direction.
;; The flip emerges: the Sell prototype accumulates configurations
;; where experts said BUY but the price went DOWN.
;;
;; (observe manager-journal manager-thought
;;   (if (> price-at-horizon entry-price) buy sell)
;;   1.0)
;;
;; Guard: manager skips learning when the expert panel is tied
;; (buys == sells). Nothing to learn from a directionless panel.
;;
;; Manager tracks (conviction, correct?) pairs in mgr_resolved.
;; No coalgebra resolve/curve — proof is via sigma-band scan.

;; ── Gate ─────────────────────────────────────────────────────────────
;;
;; The manager's proof: sigma-band scan over resolved predictions.
;; Scan conviction bands [k*σ, (k+4)*σ] for k in 3..18, where σ = 1/sqrt(dims).
;; Find the band with accuracy > 0.51 and at least 200 samples.
;; The treasury deploys only in the proven band.
;;
;; rune:scry(evolved) — code requires mgr_resolved.len() >= 500 before scanning bands
;; (spec only mentions per-band minimum of 200). The 500 total is an outer gate ensuring
;; enough statistical mass before any band search begins. Spec needs update.
;;
;; (let ((best-band best-acc) (scan-sigma-bands mgr-resolved dims))
;;   (if (> best-acc 0.51) (gate proven-band) silence))
;; → The manager acts only when conviction falls inside its proven band.

;; ── What the manager does NOT do ────────────────────────────────────
;;
;; - Does NOT encode candles
;; - Does NOT see indicators directly
;; - Does NOT flip predictions (the flip emerges from the geometry)
;; - Does NOT average expert opinions (the shape matters, not the mean)
;; - Does NOT know about costs (that's the treasury's domain)

;; ── Derived thresholds (application-level, not stdlib) ──────────────
;;
;; These interpret the geometry for trading. The formula k/sqrt(dims)
;; is trivial — the application chooses k.

(define (noise-floor dims)
  (/ 3.0 (sqrt dims)))    ;; 3σ — below this, cosine is random noise

(define (sweet-spot dims)
  (/ 5.0 (sqrt dims)))    ;; 5σ — conviction level where signal emerges
