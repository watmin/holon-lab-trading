;; ── mod/divergence — indicator vs price disagreement ────────────────
;;
;; Used by: momentum expert (and optionally volume)
;; Produces: divergence facts — when indicators disagree with price
;;
;; Divergence = the most reliable reversal signal in technical analysis.
;; Price makes new high, indicator makes lower high = bearish divergence.
;; Price makes new low, indicator makes higher low = bullish divergence.

;; ── Currently implemented ───────────────────────────────────────────

;; RSI Divergence (via PELT peak detection in eval_divergence)
;; Detects structural peaks in both price and RSI, compares slopes.
;; Already produces facts but only for RSI.

;; ── NOT YET IMPLEMENTED ─────────────────────────────────────────────

;; Generic divergence framework:
;; For ANY oscillator, detect peaks/troughs and compare with price peaks/troughs.
;; This produces divergence facts for: RSI, stochastic, CCI, OBV, MFI, MACD.

(atom "bull-divergence")      ; price lower low + indicator higher low
(atom "bear-divergence")      ; price higher high + indicator lower high
(atom "hidden-bull-div")      ; price higher low + indicator lower low (trend continuation)
(atom "hidden-bear-div")      ; price lower high + indicator higher high

;; Per-indicator divergence atoms:
(atom "rsi-bull-div") (atom "rsi-bear-div")
(atom "stoch-bull-div") (atom "stoch-bear-div")
(atom "cci-bull-div") (atom "cci-bear-div")
(atom "obv-bull-div") (atom "obv-bear-div")
(atom "mfi-bull-div") (atom "mfi-bear-div")
(atom "macd-bull-div") (atom "macd-bear-div")

;; Multi-indicator divergence: how many indicators diverge simultaneously?
(atom "divergence-count")     ; encode-linear (count / total_indicators) 1.0
(atom "broad-divergence")     ; 3+ indicators diverging = strong signal
(atom "narrow-divergence")    ; only 1 indicator diverging = weak signal

;; ── Encoding ────────────────────────────────────────────────────────
;;
;; (bind rsi-bull-div (encode-linear strength 1.0))
;; where strength = how far the divergence slopes differ
;;
;; (bind divergence-count (encode-linear (/ count total) 1.0))
;; where count = number of indicators currently diverging
;;
;; Divergence facts are binary (present/absent) but strength is continuous.
;; The bundle captures both: which indicators diverge AND how strongly.
