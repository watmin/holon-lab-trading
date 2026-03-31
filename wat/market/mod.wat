;; ── market/mod.wat — shared market primitives ────────────────────
;;
;; Time encoding helpers and module re-exports.
;; The market module's root. Minimal — just the shared bits.

;; ── Re-exports ─────────────────────────────────────────────────

;; Submodule declarations. In Rust: `pub mod desk; pub mod manager; pub mod observer;`
; rune:gaze(phantom) — declare-module is not in the wat language
(declare-module desk)        ; trading pair's expert panel
(declare-module manager)     ; manager encoding
(declare-module observer)    ; Observer struct

;; ── Time parsing ───────────────────────────────────────────────
;;
;; Candle timestamps are strings: "YYYY-MM-DD HH:MM:SS".
;; The enterprise encodes time circularly (hour-of-day, day-of-week).
;; These parse the numeric values from the timestamp string.

;; parse-f64: parse a string slice as f64. Returns the number or #f on failure.
;; In Rust: str::parse::<f64>().ok()
(define (parse-f64 s) (string->number s))

(define (parse-candle-hour ts)
  "Extract hour-of-day from candle timestamp. Returns f64 in [0, 23].
   Falls back to 12.0 on parse failure."
  ;; ts[11..13] -> parse as integer -> f64
  (or (parse-f64 (substring ts 11 13)) 12.0))

(define (parse-candle-day ts)
  "Day-of-week from candle timestamp. 0=Sunday..6=Saturday.
   Zeller-like formula from year/month/day."
  ;; Lookup table: [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
  ;; Adjust year if month < 3.
  ;; (y + y/4 - y/100 + y/400 + t[m-1] + d) mod 7
  ;; parse-i32: parse a string slice as i32. Returns the number or #f on failure.
  ;; In Rust: str::parse::<i32>().ok()
  (define (parse-i32 s) (string->integer s))

  (let ((y (or (parse-i32 (substring ts 0 4)) 2019))
        (m (or (parse-i32 (substring ts 5 7)) 1))
        (d (or (parse-i32 (substring ts 8 10)) 1))
        (t [0 3 2 5 0 3 5 1 4 6 2 4])
        (y2 (if (< m 3) (- y 1) y)))
    (mod (+ y2 (/ y2 4) (- (/ y2 100)) (/ y2 400) (nth t (- m 1)) d) 7)))

;; ── What market/mod does NOT do ────────────────────────────────
;; - Does NOT encode (that's manager.rs and thought/mod.rs)
;; - Does NOT hold state (pure functions)
;; - Does NOT know about observers or positions (those are submodules)
;; - Timestamp parsing. Module re-exports. That's all.
