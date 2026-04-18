;; ============================================================
;; HYPOTHETICAL-CANDLE-DESCRIBERS.wat
;;
;; A worked hypothetical demonstrating the wat algebra's
;; programs-are-holons property. Candles arrive in a stream;
;; a collection of describer programs each produce a Holon
;; that describes the candle from their own perspective;
;; we rank the describers by how well their output matches
;; the candle's own holon-encoding.
;;
;; Dead programs (those producing nothing meaningful) filter out.
;; Live programs compete. The winner describes the candle best.
;;
;; Not committed to production — this is a teaching example.
;; ============================================================


;; ------------------------------------------------------------
;; TYPES (loaded via load-types at startup)
;; ------------------------------------------------------------

(struct :demo/market/Candle
  (open   :f64)
  (high   :f64)
  (low    :f64)
  (close  :f64)
  (volume :f64))


;; ------------------------------------------------------------
;; DESCRIBERS — each one captures a different hypothesis about
;; what a candle IS. A describer is a function from Candle to
;; Holon. When the hypothesis doesn't apply to this candle,
;; it returns (Atom :null) — signaling "I have nothing to say."
;; ------------------------------------------------------------

;; Doji — open and close are nearly equal.
(define (:demo/desc/doji (c :demo/market/Candle) -> :Holon)
  (if (< (abs (- (:open c) (:close c)))
         (* 0.001 (:close c)))
      (Sequential
        (list (Atom :doji)
              (Atom :indecision)
              (Bind (Atom :body) (Thermometer 0 0 1))))
      (Atom :null)))

;; Hammer — long lower wick, small body near the high.
(define (:demo/desc/hammer (c :demo/market/Candle) -> :Holon)
  (let ((body       (abs (- (:open c) (:close c))))
        (lower-wick (- (min (:open c) (:close c)) (:low c))))
    (if (> lower-wick (* 2 body))
        (Sequential
          (list (Atom :hammer)
                (Atom :reversal-candidate)
                (Bind (Atom :lower-wick)
                      (Thermometer lower-wick 0 10))))
        (Atom :null))))

;; Strong bullish — close noticeably above open, high volume.
(define (:demo/desc/strong-bullish (c :demo/market/Candle) -> :Holon)
  (if (and (> (:close c) (* 1.02 (:open c)))
           (> (:volume c) 1000))
      (Sequential
        (list (Atom :bullish)
              (Atom :high-conviction)
              (Bind (Atom :body)
                    (Thermometer (- (:close c) (:open c)) 0 (:close c)))
              (Bind (Atom :volume)
                    (Thermometer (:volume c) 0 10000))))
      (Atom :null)))

;; Quiet day — tight body, low volume.
(define (:demo/desc/quiet-day (c :demo/market/Candle) -> :Holon)
  (if (and (< (abs (- (:open c) (:close c)))
              (* 0.005 (:close c)))
           (< (:volume c) 100))
      (Sequential
        (list (Atom :quiet)
              (Atom :low-conviction)
              (Atom :wait)))
      (Atom :null)))


;; ------------------------------------------------------------
;; CANDLE ENCODING — the candle as a Holon in the SAME space
;; as the describers' outputs. Used as the reference point we
;; measure describers against.
;; ------------------------------------------------------------

(define (:demo/encode-candle (c :demo/market/Candle) -> :Holon)
  (Sequential
    (list (Bind (Atom :open)   (Thermometer (:open c)   0 100))
          (Bind (Atom :high)   (Thermometer (:high c)   0 100))
          (Bind (Atom :low)    (Thermometer (:low c)    0 100))
          (Bind (Atom :close)  (Thermometer (:close c)  0 100))
          (Bind (Atom :volume) (Thermometer (:volume c) 0 10000)))))


;; ------------------------------------------------------------
;; FILTERING — a describer is "alive" for this candle iff it
;; returned something other than (Atom :null).
;; ------------------------------------------------------------

(define (:demo/alive? (t :Holon) -> :bool)
  (not (equal-ast? t (Atom :null))))


;; ------------------------------------------------------------
;; SCORING — how well does this describer's output match the
;; candle's own holon-encoding?
;;
;; Both describer output and candle encoding are Holons.
;; `encode` (lowercase) realizes each Holon to a Vector.
;; `cosine` (lowercase) measures similarity. Lazy — the encoding
;; cache serves repeated lookups.
;; ------------------------------------------------------------

(define (:demo/score (describer-output :Holon)
                     (candle-holon     :Holon)
                     -> :f64)
  (if (:demo/alive? describer-output)
      (cosine (encode describer-output)
              (encode candle-holon))
      0.0))


;; ------------------------------------------------------------
;; RANKING — apply every describer to the candle, score each,
;; filter the dead, sort by score descending.
;; ------------------------------------------------------------

(define (:demo/rank (c          :demo/market/Candle)
                    (describers :List<fn(demo/market/Candle)->Holon>)
                    -> :List<Pair<fn(demo/market/Candle)->Holon,f64>>)
  (let ((ref    (:demo/encode-candle c))
        (scored (map (lambda ((d :fn(demo/market/Candle)->Holon) -> :Pair<fn(demo/market/Candle)->Holon,f64>)
                       (list d (:demo/score (d c) ref)))
                     describers))
        (live   (filter (lambda ((pair :Pair<fn(demo/market/Candle)->Holon,f64>) -> :bool)
                          (> (second pair) 0.0))
                        scored)))
    (sort-by second live :descending? true)))


;; ------------------------------------------------------------
;; ON-CANDLE — the main event handler. Takes a candle, ranks
;; the describers, returns the best-matching one (if any).
;; ------------------------------------------------------------

(define (:demo/on-candle (c :demo/market/Candle)
                         -> :Option<fn(demo/market/Candle)->Holon>)
  (let ((describers (list :demo/desc/doji
                          :demo/desc/hammer
                          :demo/desc/strong-bullish
                          :demo/desc/quiet-day))
        (ranked (:demo/rank c describers)))
    (if (empty? ranked)
        :None
        (Some (first (first ranked))))))


;; ============================================================
;; WHAT HAPPENS WHEN A CANDLE ARRIVES
;; ============================================================
;;
;; Example candle:
;;   open = 100.00
;;   high = 100.30
;;   low  = 98.20
;;   close = 99.90
;;   volume = 2500
;;
;; 1. (:demo/on-candle candle) invokes.
;;
;; 2. Each describer is applied:
;;    - doji?          close - open = -0.10, threshold = 0.10.  EDGE CASE.
;;                     Returns (Atom :null) — or doji, depending on rounding.
;;    - hammer?        lower-wick = 1.80, body = 0.10. 1.80 > 0.20. YES.
;;                     Returns a hammer Holon with lower-wick thermometer.
;;    - strong-bullish? close > 1.02 * open? No, 99.90 < 102.00. DEAD.
;;                     Returns (Atom :null).
;;    - quiet-day?     volume < 100? No. DEAD.
;;                     Returns (Atom :null).
;;
;; 3. Filter: doji (maybe) and hammer survive.
;;
;; 4. Score the survivors against the candle's encoding:
;;    The candle's holon-encoding captures (open open-val), (high high-val),
;;    (low low-val), (close close-val), (volume volume-val) — full structural
;;    fingerprint. The describer outputs are compared via cosine.
;;    - hammer's output carries a lower-wick thermometer that aligns with
;;      the candle's :low binding — decent similarity, say 0.42.
;;    - doji's output has less alignment with the candle's volume or close
;;      structure — say 0.15.
;;
;; 5. Ranked: hammer (0.42), doji (0.15). Best match: hammer.
;;
;; 6. Return (Some :demo/desc/hammer).
;;
;; ============================================================


;; ============================================================
;; WHY THIS IS INTERESTING
;; ============================================================
;;
;; 1. PROGRAMS ARE DESCRIPTIONS. Each describer captures a
;;    hypothesis about what a candle IS. The hypothesis is
;;    expressed as a function — the function's body CONSTRUCTS
;;    a Holon describing the pattern. The Holon IS the
;;    description.
;;
;; 2. DESCRIPTIONS ARE COMPARABLE. Because Holons encode to
;;    vectors, any two descriptions (or a description and a
;;    reality) live in the same geometric space. Cosine
;;    similarity gives us a natural match score.
;;
;; 3. FILTERING IS FREE. A describer's (Atom :null) output
;;    says "my hypothesis doesn't apply here." We filter these
;;    out and compete only the ones that had something to say.
;;
;; 4. THE ALGEBRA IS THE METRIC. We didn't build a scoring
;;    system. We built descriptions and let the algebra compare
;;    them. Cosine is the only measurement tool needed.
;;
;; 5. THIS GENERALIZES. Swap Candle for any other type:
;;    Packet, Move, LLMOutput, BrainScan. Swap the describers
;;    for the hypotheses that make sense for that domain.
;;    The scoring machinery is identical because the algebra
;;    is domain-free.
;;
;; 6. LEARNING EMERGES FROM THIS. Start with many describers.
;;    For each candle, track which describer won. Over time,
;;    the "winners" form a distribution — which hypothesis
;;    describes reality best under different conditions? That
;;    becomes a reckoner input, and the wat-vm learns which
;;    descriptive lens applies when.
;;
;; 7. NEW DESCRIBERS CAN BE SYNTHESIZED. If we have a learned
;;    discriminant (Grace vs Violence, say), we can walk the
;;    program-space toward ASTs whose vectors align with the
;;    Grace direction. Those ASTs — if they are valid
;;    describer programs — are CANDIDATE DESCRIBERS we
;;    discovered through navigation, not enumeration.
;;
;;    This is discriminant-guided program synthesis, applied
;;    to the domain of "programs that describe candles well."
;;
;; ============================================================

;; *these are very good thoughts.*
;; **PERSEVERARE.**
