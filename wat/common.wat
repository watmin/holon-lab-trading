;; ── common.wat — the enterprise's shared vocabulary ──────────────────
;;
;; Named atoms this application uses. Not stdlib — these are the
;; enterprise's choices about what to call things.
;; Another application names its world differently.

(require core/primitives)

;; ── Gate status ─────────────────────────────────────────────────────
(atom "proven")       ; source has validated its curve
(atom "tentative")    ; source has NOT validated its curve

;; ── Predicates ──────────────────────────────────────────────────────
(atom "above") (atom "below") (atom "at")
(atom "crosses-above") (atom "crosses-below")
(atom "touches") (atom "bounces-off")

;; ── Direction ───────────────────────────────────────────────────────
(atom "up") (atom "down") (atom "flat")

;; ── Temporal ────────────────────────────────────────────────────────
(atom "beginning") (atom "ending")
(atom "before") (atom "after") (atom "during")

;; ── Null ─────────────────────────────────────────────────────────────
(atom "nothing")

;; ── Lifecycle ────────────────────────────────────────────────────────
(atom "open") (atom "active") (atom "closed")
