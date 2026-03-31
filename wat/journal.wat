;; ── journal.wat — the learning primitive ─────────────────────────
;;
;; Thin bridge to holon::Journal. The enterprise doesn't define
;; learning — it uses the substrate's Journal and registers its
;; own labels.
;;
;; Direction is for position management. Labels are for journals.
;; They are not the same thing.

(require core/primitives)

;; ── Re-exports from holon::memory ──────────────────────────────

;; Journal: the substrate's learning primitive.
;; Label:   cheap integer handle to a registered symbol.
;; Prediction: a journal's output — (label, conviction) pairs.
;;
;; The enterprise wraps none of this. It uses them directly.
;; Re-export from holon substrate. Journal, Label, and Prediction are
;; substrate types used directly — the enterprise wraps none of them.
;; In Rust: `use holon::memory::{Journal, Label, Prediction};`
; rune:gaze(phantom) — use is not in the wat language
(use holon/memory [Journal Label Prediction])

;; ── Direction ──────────────────────────────────────────────────

;; Which way a position is facing. Trade accounting, not prediction.
;; Long displays as "Buy", Short as "Sell".
;; NOT a journal label. Positions have direction. Journals have labels.

;; Direction: a two-variant sum type. Long = facing up, Short = facing down.
;; In Rust: `pub enum Direction { Long, Short }`
; rune:gaze(phantom) — variants is not in the wat language
(define Direction (variants Long Short))

(define (display direction)
  (match direction
    Long  "Buy"
    Short "Sell"))

;; ── Enterprise label sets ──────────────────────────────────────

;; Each journal registers the labels that match its question.
;; Labels are symbols — created once, used as cheap integer handles.
;;
;; Different levels ask different questions:
;;   Observer + Manager:  "Which direction?" → Buy / Sell
;;   Exit expert:         "Hold or exit?"    → Hold / Exit
;;   Risk health (future): "Healthy?"        → Healthy / Unhealthy
;;   Treasury (future):    "Allocate?"       → Allocate / Withhold

(define (register-direction journal)
  "Register Buy/Sell labels. Returns (buy, sell) handles."
  (let ((buy  (register journal "Buy"))
        (sell (register journal "Sell")))
    (buy sell)))

(define (register-exit journal)
  "Register Hold/Exit labels. Returns (hold, exit) handles."
  (let ((hold (register journal "Hold"))
        (exit (register journal "Exit")))
    (hold exit)))

;; ── What journal.wat does NOT do ───────────────────────────────
;; - Does NOT define Journal internals (that's holon::memory)
;; - Does NOT define encoding (that's thought or market)
;; - Does NOT decide trades (that's the observer → manager → treasury chain)
;; - Does NOT learn anything itself (it provides the tools for learning)
;; - Thin bridge. Label registration. Direction enum. That's all.
