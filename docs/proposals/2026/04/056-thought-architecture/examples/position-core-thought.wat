;; position-core-thought.wat — Core lens position observer thought.
;;
;; The position observer is middleware. It receives market rhythms
;; from the market observer and adds its own regime rhythms.
;;
;; Core lens: regime character over time. "Is the market trending
;; or chaotic? How is that changing?" No phase awareness.
;;
;; Same indicator-rhythm function. Different indicators.

(define (position-core-thought window market-rhythms dims)
  (bundle
    ;; ── Market rhythms (passed through from market observer) ─────
    ;; These are pre-computed rhythm vectors. One per market indicator.
    ;; The position observer receives them, doesn't rebuild them.
    ;; Anomaly filtering selects which rhythms pass through.
    market-rhythms  ;; ~10-15 rhythm vectors

    ;; ── Regime streams — the character of the market over time ───
    (indicator-rhythm window "kama-er"        (lambda (c) c.kama-er)        dims)
    (indicator-rhythm window "choppiness"     (lambda (c) c.choppiness)     dims)
    (indicator-rhythm window "dfa-alpha"      (lambda (c) c.dfa-alpha)      dims)
    (indicator-rhythm window "variance-ratio" (lambda (c) c.variance-ratio) dims)
    (indicator-rhythm window "entropy-rate"   (lambda (c) c.entropy-rate)   dims)
    (indicator-rhythm window "fractal-dim"    (lambda (c) c.fractal-dim)    dims)

    ;; Directional regime — who's been winning, and how is that shifting?
    (indicator-rhythm window "aroon-up"       (lambda (c) c.aroon-up)       dims)
    (indicator-rhythm window "aroon-down"     (lambda (c) c.aroon-down)     dims)

    ;; Time — parts and composition
    (indicator-rhythm window "hour"           (lambda (c) c.hour)           dims)
    (indicator-rhythm window "day-of-week"    (lambda (c) c.day-of-week)    dims)))

;; 10 regime rhythm vectors + ~10-15 market rhythms = ~20-25 items.
;; Budget at D=10,000: 100. Comfortable.
;;
;; What the position observer adds that the market observer doesn't:
;;
;; "kama-er rhythm falling while entropy rising"
;;   → efficiency dropping, disorder increasing → regime shift happening.
;;
;; "choppiness rhythm rising + dfa-alpha rhythm falling below 0.5"
;;   → market becoming mean-reverting. The trend is dying.
;;
;; "aroon-up rhythm was high, now falling + aroon-down rising"
;;   → bulls losing dominance over time. Not a single reading — a progression.
;;
;; The market observer thinks about WHAT the indicators are doing.
;; The position observer thinks about HOW the market is behaving.
;; Different questions. Same encoding.
