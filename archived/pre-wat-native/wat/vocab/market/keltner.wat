;; ── vocab/market/keltner.wat ─────────────────────────────────────
;;
;; Channel positions and squeeze. Pure function: candle in, ASTs out.
;; atoms: bb-pos, bb-width, kelt-pos, squeeze, kelt-upper-dist, kelt-lower-dist
;; Depends on: candle.

(require candle)

(define (encode-keltner-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Bollinger position: [-1, 1] — where within the bands.
    ;; -1 = lower band, 0 = middle, +1 = upper band.
    '(Linear "bb-pos" (:bb-pos c) 1.0)

    ;; Bollinger width: unbounded positive. Log-encoded.
    ;; Wider bands = higher volatility.
    '(Log "bb-width" (max 0.001 (:bb-width c)))

    ;; Keltner position: [-1, 1] — where within the Keltner channel.
    '(Linear "kelt-pos" (:kelt-pos c) 1.0)

    ;; Squeeze: [0, 1] — Bollinger inside Keltner = compression.
    ;; 1.0 = full squeeze, 0.0 = no squeeze.
    '(Linear "squeeze" (:squeeze c) 1.0)

    ;; Keltner upper distance: signed distance from upper channel.
    ;; Positive = above, negative = below. Percentage of price.
    '(Linear "kelt-upper-dist"
             (/ (- (:close c) (:kelt-upper c)) (:close c))
             0.1)

    ;; Keltner lower distance: signed distance from lower channel.
    ;; Positive = above, negative = below. Percentage of price.
    '(Linear "kelt-lower-dist"
             (/ (- (:close c) (:kelt-lower c)) (:close c))
             0.1)))
