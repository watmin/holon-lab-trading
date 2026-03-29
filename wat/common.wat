;; ── common vocabulary (stdlib) ──────────────────────────────────────
;;
;; Shared atoms used across the enterprise. Every role that references
;; these concepts uses the same atom → same vector → same geometry.
;;
;; See also:
;;   primitives.wat  — corelib (atom, bind, bundle, cosine, journal, curve)
;;   channels.wat    — communication contract (publish, subscribe, filter)
;;   mod/            — domain vocabulary modules

;; ── Actions ─────────────────────────────────────────────────────────
;; Named action atoms: (bind expert (bind buy magnitude))
;; Buy and sell are atoms. Named composition, not permutation tricks.
(atom "buy")
(atom "sell")

;; ── Gate status ─────────────────────────────────────────────────────
;; Annotations on messages, not architecture constraints.
;; Consumers filter on these. Channels don't.
(atom "proven")       ; expert has validated curve
(atom "tentative")    ; expert has NOT validated curve
;; Usage: (bind expert (bind proven (bind action magnitude)))
;;    or: (bind expert (bind tentative (bind action magnitude)))

;; ── Direction ───────────────────────────────────────────────────────
;; Market direction atoms used in labels and predictions.

;; ── Time (from THOUGHT_VOCAB.md) ────────────────────────────────────
;;
;; 4-hour blocks — aligns with crypto funding rate cycles
(atom "h00")  ; 00:00-03:59 UTC
(atom "h04")  ; 04:00-07:59 UTC
(atom "h08")  ; 08:00-11:59 UTC
(atom "h12")  ; 12:00-15:59 UTC
(atom "h16")  ; 16:00-19:59 UTC
(atom "h20")  ; 20:00-23:59 UTC

;; Trading sessions
(atom "asian-session")     ; 00:00-08:00 UTC
(atom "european-session")  ; 08:00-14:00 UTC
(atom "us-session")        ; 14:00-21:00 UTC
(atom "off-hours")         ; 21:00-00:00 UTC

;; Days of week
(atom "monday") (atom "tuesday") (atom "wednesday")
(atom "thursday") (atom "friday") (atom "saturday") (atom "sunday")

;; ── Predicates (used by experts) ────────────────────────────────────
(atom "above") (atom "below")
(atom "crosses-above") (atom "crosses-below")
(atom "touches") (atom "bounces-off")
(atom "at") (atom "at-day") (atom "at-hour") (atom "at-session")

;; ── Directions (used by segment narrative) ──────────────────────────
(atom "up") (atom "down") (atom "flat") (atom "null")

;; ── Segment narrative ───────────────────────────────────────────────
(atom "beginning") (atom "ending")

;; ── Zone atoms (shared across indicators) ───────────────────────────
;; RSI zones
(atom "rsi-oversold") (atom "rsi-overbought") (atom "rsi-neutral")
;; Stochastic
(atom "stoch-overbought") (atom "stoch-oversold")
;; Cloud
(atom "above-cloud") (atom "below-cloud") (atom "in-cloud")
;; Volume
(atom "volume-spike") (atom "volume-drought")
;; CCI
(atom "cci-overbought") (atom "cci-oversold")
;; Price action
(atom "inside-bar") (atom "outside-bar") (atom "gap-up") (atom "gap-down")
(atom "consecutive-up") (atom "consecutive-down")

;; ── Indicator atoms ─────────────────────────────────────────────────
(atom "close") (atom "open") (atom "high") (atom "low") (atom "volume")
(atom "rsi") (atom "rsi-sma") (atom "macd-line") (atom "macd-signal")
(atom "sma20") (atom "sma50") (atom "sma200")
(atom "bb-upper") (atom "bb-lower")
(atom "dmi-plus") (atom "dmi-minus") (atom "adx")
(atom "atr") (atom "range-pos")

;; ── Advanced indicator atoms ────────────────────────────────────────
(atom "kama-er") (atom "chop") (atom "dfa-alpha") (atom "variance-ratio")
(atom "td-count") (atom "aroon-up") (atom "fractal-dim")
(atom "gr-bvalue") (atom "entropy-rate") (atom "spectral-slope")
