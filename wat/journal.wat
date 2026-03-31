;; ── journal.wat — the learning primitive ─────────────────────────
;;
;; Thin bridge to holon's Journal. The enterprise doesn't define
;; learning — it uses the substrate's journal and registers its
;; own labels.
;;
;; Direction is for position management. Labels are for journals.
;; They are not the same thing.

(require core/primitives)
(require core/structural)

;; ── Substrate types ──────────────────────────────────────────────
;;
;; Journal, Label, and Prediction come from core/primitives.
;; The enterprise uses them directly — no wrappers.
;; In Rust: `use holon::memory::{Journal, Label, Prediction};`

;; ── Direction ────────────────────────────────────────────────────

;; Which way a position is facing. Trade accounting, not prediction.
;; NOT a journal label. Positions have direction. Journals have labels.
(enum direction :long :short)

(define (direction-display dir)
  (match dir
    :long  "Buy"
    :short "Sell"))

;; ── Enterprise label sets ────────────────────────────────────────
;;
;; Each journal registers the labels that match its question.
;; Labels are symbols — created once, used as cheap integer handles.
;;
;; Different levels ask different questions:
;;   Observer + Manager:  "Which direction?" → Buy / Sell
;;   Exit expert:         "Hold or exit?"    → Hold / Exit
;;   Risk health (future): "Healthy?"        → Healthy / Unhealthy

(define (register-direction journal)
  "Register Buy/Sell labels. Returns (buy, sell) handles."
  (let ((buy  (register journal "Buy"))
        (sell (register journal "Sell")))
    (list buy sell)))

(define (register-exit journal)
  "Register Hold/Exit labels. Returns (hold, exit) handles."
  (let ((hold (register journal "Hold"))
        (exit (register journal "Exit")))
    (list hold exit)))

;; ── What journal.wat does NOT do ─────────────────────────────────
;; - Does NOT define Journal internals (that's the holon substrate)
;; - Does NOT define encoding (that's thought or market)
;; - Does NOT decide trades (that's the observer → manager → treasury chain)
;; - Thin bridge. Label registration. Direction enum. That's all.
