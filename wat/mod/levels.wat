;; ── mod/levels — support, resistance, and retracement ───────────────
;; Used by: structure expert
;;
;; Currently: fibonacci (from eval_fibonacci)
;;
;; Not yet implemented:
;; - Pivot points (daily/weekly calculated from OHLC)
;; - Round number levels ($3000, $3500, etc.)
;; - Previous high/low as support/resistance
;; - Volume profile POC (point of control)

(atom "pivot") (atom "pivot-r1") (atom "pivot-r2") (atom "pivot-s1") (atom "pivot-s2")
(atom "above-pivot") (atom "below-pivot")
(atom "round-number")        ; close near a round number (psychological level)
(atom "prev-high") (atom "prev-low")
(atom "at-prev-high") (atom "at-prev-low")
