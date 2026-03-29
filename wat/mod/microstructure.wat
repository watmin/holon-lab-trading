;; ── mod/microstructure — market regime micro-indicators ──────────────
;; Used by: regime expert
;;
;; Currently: choppiness, aroon, DeMark, KAMA-ER (from eval_advanced)
;;
;; Not yet implemented:
;; - Ease of Movement (EMV) — how easily price moves with volume
;; - Force Index — price change × volume = force behind move
;; - Mass Index — volatility expansion detection
;; - Vortex Indicator — trend direction from true range
;; - Elder Ray — bull/bear power from distance to EMA

(atom "emv") (atom "emv-easy") (atom "emv-difficult")
(atom "force-index") (atom "force-bull") (atom "force-bear")
(atom "mass-index") (atom "mass-bulge")  ; bulge > 27 = reversal setup
(atom "vortex-plus") (atom "vortex-minus") (atom "vortex-cross")
(atom "elder-bull-power") (atom "elder-bear-power")
