;; ── manager.wat ─────────────────────────────────────────────────────
;;
;; The manager thinks in observer opinions, not candle data.
;; Its vocabulary = its observers + panel shape + market context + time.
;; Its label = raw price direction (Buy if price up, Sell if price down).
;; Its discriminant learns which SHAPES of signed opinion precede
;; up-moves vs down-moves. The flip emerges geometrically.
;;
;; The manager does NOT encode candles. It does NOT see indicators.
;; It reads observer predictions passed by the fold. The fold decides
;; which observers to include (proof gates filter upstream).

(require core/primitives)
(require core/structural)
(require std/statistics)

;; ── Manager atoms ──────────────────────────────────────────────────

(struct manager-atoms
  buy sell                      ; direction atoms
  proven tentative              ; credibility atoms
  reliability tenure            ; per-observer quality atoms
  agreement energy divergence coherence  ; panel shape atoms
  volatility disc-strength      ; market context atoms
  hour day                      ; time atoms
  delta)                        ; motion atom

(define (new-manager-atoms vm)
  (manager-atoms
    :buy (atom "buy") :sell (atom "sell")
    :proven (atom "proven") :tentative (atom "tentative")
    :reliability (atom "expert-reliability") :tenure (atom "expert-tenure")
    :agreement (atom "panel-agreement") :energy (atom "panel-energy")
    :divergence (atom "panel-divergence") :coherence (atom "panel-coherence")
    :volatility (atom "market-volatility") :disc-strength (atom "disc-strength")
    :hour (atom "hour-of-day") :day (atom "day-of-week")
    :delta (atom "panel-delta")))

;; ── Manager context ────────────────────────────────────────────────
;;
;; Everything the manager needs to encode one candle's thought.
;; Passed by the fold — the manager doesn't reach into global state.

(struct manager-context
  observer-preds               ; (list Prediction) — one per observer
  observer-atoms               ; (list Vector) — identity atom per observer
  observer-curve-valid         ; (list bool) — proof gate per observer
  observer-resolved-lens       ; (list usize) — how many resolved per observer
  observer-resolved-accs       ; (list f64) — rolling accuracy per observer
  observer-vecs                ; (list Vector) — thought vectors for coherence
  generalist-pred              ; Prediction
  generalist-atom              ; Vector
  generalist-curve-valid       ; bool
  candle-atr                   ; f64
  candle-hour                  ; f64
  candle-day                   ; f64
  disc-strength)               ; f64

;; ── Per-observer encoding ──────────────────────────────────────────
;;
;; Each observer contributes facts to the manager's thought.
;; GATED: only observers above the noise floor are included.
;; Proven observers also get reliability + tenure facts.

(define (noise-floor dims)
  "3σ — below this, cosine is random noise in the hyperspace."
  (/ 3.0 (sqrt dims)))

(define (encode-observer-opinion atoms observer-atom pred curve-valid
                                  resolved-len resolved-acc min-opinion)
  "Encode one observer's contribution to the manager's thought.
   Returns a list of facts (may be empty if below noise floor)."
  (let ((raw-cos (:raw-cosine pred)))
    (if (< (abs raw-cos) min-opinion)
        (list)  ;; silence — no opinion
        (let ((magnitude (encode-linear (abs raw-cos) 1.0))
              (action    (if (>= raw-cos 0.0) (:buy atoms) (:sell atoms)))
              (status    (if curve-valid (:proven atoms) (:tentative atoms))))
          (append
            ;; Fact 1: opinion — direction + magnitude
            (list (bind observer-atom (bind action magnitude)))
            ;; Fact 2: credibility — proven or tentative
            (list (bind observer-atom status))
            ;; Fact 3: reliability — accuracy above baseline (if enough data)
            (if (>= resolved-len 20)
                (list (bind (bind observer-atom (:reliability atoms))
                            (encode-linear (max 0.0 (- resolved-acc 0.4)) 1.0)))
                (list))
            ;; Fact 4: tenure — how long has this observer been resolving?
            (if (>= resolved-len 50)
                (list (bind (bind observer-atom (:tenure atoms))
                            (encode-log resolved-len)))
                (list)))))))

;; ── Panel shape ────────────────────────────────────────────────────
;;
;; Emergent properties of the proven observer collective.
;; These tell the manager about the PATTERN of agreement,
;; not just who said what. Needs 2+ proven observers.

(define (panel-shape atoms ctx dims)
  "Panel-level facts from proven observer predictions."
  (let ((proven-indices (filter (lambda (i) (nth (:observer-curve-valid ctx) i))
                                (range 0 (len (:observer-preds ctx))))))
    (if (< (len proven-indices) 2)
        (list)
        (let ((proven-preds (map (lambda (i) (nth (:observer-preds ctx) i)) proven-indices))
              (proven-vecs  (map (lambda (i) (nth (:observer-vecs ctx) i)) proven-indices))
              (total        (len proven-preds))
              (buys         (count (lambda (p) (> (:raw-cosine p) 0.0)) proven-preds)))
          (let ((agreement (/ (max buys (- total buys)) total))
                (convictions (map :conviction proven-preds))
                (mean-conv  (mean convictions))
                (spread     (stddev convictions)))
            (append
              (list (bind (:agreement atoms) (encode-linear agreement 1.0))
                    (bind (:energy atoms)    (encode-linear mean-conv 1.0))
                    (bind (:divergence atoms) (encode-linear spread 1.0)))
              ;; Coherence: mean pairwise cosine between proven thought vectors
              (if (>= (len proven-vecs) 2)
                  (let ((pair-sims
                          (fold-left (lambda (acc i)
                            (append acc
                              (map (lambda (j) (cosine (nth proven-vecs i) (nth proven-vecs j)))
                                   (range (+ i 1) (len proven-vecs)))))
                            (list)
                            (range 0 (- (len proven-vecs) 1)))))
                    (list (bind (:coherence atoms)
                                (encode-linear (abs (/ (fold + 0.0 pair-sims)
                                                       (len pair-sims)))
                                               1.0))))
                  (list))))))))

;; ── Context ────────────────────────────────────────────────────────

(define (market-context atoms ctx)
  "Market-level context facts: volatility, discriminant quality, time."
  (list
    (bind (:volatility atoms)    (encode-log (max 1e-10 (:candle-atr ctx))))
    (bind (:disc-strength atoms) (encode-log (max 1e-10 (:disc-strength ctx))))
    (bind (:hour atoms)          (encode-circular (:candle-hour ctx) 24.0))
    (bind (:day atoms)           (encode-circular (:candle-day ctx) 7.0))))

;; ── Motion ─────────────────────────────────────────────────────────
;;
;; The manager sees not just where the panel IS, but where it MOVED.
;; difference(prev, current) encodes structural change.

(define (motion atoms current-thought prev-thought)
  (if prev-thought
      (list (bind (:delta atoms) (difference prev-thought current-thought)))
      (list)))

;; ── Complete manager thought ───────────────────────────────────────

(define (encode-manager-thought atoms ctx dims prev-thought)
  "Encode the manager's thought from observer opinions.
   Returns a list of fact vectors ready for bundling."
  (let ((min-opinion (noise-floor dims))
        (observer-facts
          (fold-left (lambda (facts i)
            (append facts
              (encode-observer-opinion atoms
                (nth (:observer-atoms ctx) i)
                (nth (:observer-preds ctx) i)
                (nth (:observer-curve-valid ctx) i)
                (nth (:observer-resolved-lens ctx) i)
                (nth (:observer-resolved-accs ctx) i)
                min-opinion)))
            (list)
            (range 0 (len (:observer-preds ctx)))))
        ;; Generalist — same encoding, just from generalist fields
        (generalist-facts
          (encode-observer-opinion atoms
            (:generalist-atom ctx)
            (:generalist-pred ctx)
            (:generalist-curve-valid ctx)
            0 0.0  ;; generalist doesn't track per-observer reliability/tenure
            min-opinion))
        (shape   (panel-shape atoms ctx dims))
        (context (market-context atoms ctx))
        (current (bundle (append observer-facts generalist-facts shape context))))
    (append observer-facts generalist-facts shape context
            (motion atoms current prev-thought))))

;; ── Journal + labels ───────────────────────────────────────────────

(define manager-journal (journal "manager" dims refit-interval))
(define buy-label  (register manager-journal "Buy"))
(define sell-label (register manager-journal "Sell"))

;; ── Learning ───────────────────────────────────────────────────────
;;
;; Label = raw price direction at horizon.
;; Buy = price went up. Sell = price went down.
;; The manager maps signed observer configurations → actual direction.
;; The flip emerges: the Sell prototype accumulates configurations
;; where observers said BUY but the price went DOWN.
;;
;; Guard: manager skips learning when the observer panel is tied
;; (buys == sells). Nothing to learn from a directionless panel.

;; ── Gate ───────────────────────────────────────────────────────────
;;
;; The manager's proof: sigma-band scan over resolved predictions.
;; rune:assay(prose) — the band scan is an imperative search over
;; conviction ranges. The algorithm: partition resolved predictions
;; into bands [k*σ, (k+4)*σ] for k in 3..18. Find the band with
;; accuracy > 0.51 and at least 200 samples. The treasury deploys
;; only in the proven band.

;; ── Derived thresholds ─────────────────────────────────────────────

(define (sweet-spot dims)
  "5σ — conviction level where signal typically emerges."
  (/ 5.0 (sqrt dims)))

;; ── What the manager does NOT do ───────────────────────────────────
;;
;; - Does NOT encode candles
;; - Does NOT see indicators directly
;; - Does NOT flip predictions (the flip emerges from the geometry)
;; - Does NOT average observer opinions (the shape matters, not the mean)
;; - Does NOT know about costs (that's the treasury's domain)
