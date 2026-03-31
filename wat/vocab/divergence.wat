;; ── vocab/divergence.wat — structural divergence detection ──────
;;
;; Uses PELT changepoints to find structural peaks and troughs,
;; then detects when price and RSI disagree at turning points.
;;
;; Bearish divergence: price makes higher high, RSI makes lower high.
;; Bullish divergence: price makes lower low, RSI makes higher low.
;;
;; Expert profile: momentum

(require vocab/mod)
(require thought/pelt)

;; ── Atoms introduced ───────────────────────────────────────────

;; None. Divergence returns a custom struct, not Fact data.
;; The encoder handles Divergence objects with custom bind patterns.

;; ── Divergence struct ──────────────────────────────────────────

(struct divergence
  kind                   ; "bearish" or "bullish"
  indicator              ; "rsi" (currently the only indicator checked)
  price-dir              ; "up" or "down" — price direction at the divergence
  indicator-dir          ; "up" or "down" — indicator direction at the divergence
  candles-ago)           ; usize — how many candles ago from window end

;; ── Algorithm ──────────────────────────────────────────────────

(define (eval-divergence candles)
  "Detect price-RSI divergences via PELT structural analysis.
   Returns Vec<Divergence>. Empty if window < 10."

  ;; 1. Run PELT on ln(close) to find structural segments.
  ;;    BIC penalty adapts to the data's own variance.
  ;; 2. Classify each segment as up (+1), down (-1), or flat (0)
  ;;    by comparing segment endpoints.
  ;; 3. Find peaks (up→down boundaries) and troughs (down→up boundaries).
  ;; 4. Compare consecutive peaks/troughs:
  ;;    - Bearish: close[curr] > close[prev] AND rsi[curr] < rsi[prev]
  ;;    - Bullish: close[curr] < close[prev] AND rsi[curr] > rsi[prev]

  ;; No thresholds on the divergence detection itself.
  ;; PELT determines the structural segments objectively.
  ;; The divergence is either there or it isn't.

  ;; candles-ago is measured from the window end, not from now.
  ;; The encoder uses this for temporal binding.

  (let ((close-ln (map ln (map close candles)))
        (cps (pelt-changepoints close-ln (bic-penalty close-ln)))
        (boundaries (append [0] cps [(len close-ln)]))
        (seg-dirs (map segment-direction boundaries))
        (peaks (find-peaks seg-dirs boundaries))
        (troughs (find-troughs seg-dirs boundaries)))

    ;; Check consecutive peak pairs for bearish divergence
    ;; Check consecutive trough pairs for bullish divergence
    (append
      (check-bearish-pairs peaks candles)
      (check-bullish-pairs troughs candles))))

;; ── Minimum window: 10 candles ─────────────────────────────────
;; Needs at least 3 segments to find a peak pair.
;; 10 candles is the floor, but realistic divergences need more.

;; ── Currently only RSI ─────────────────────────────────────────
;; Foundation for multi-indicator divergence framework.
;; MACD divergence, OBV divergence, etc. would follow the same pattern:
;; structural peaks/troughs in price vs structural peaks/troughs in indicator.

;; ── What divergence does NOT do ────────────────────────────────
;; - Does NOT encode (returns Divergence structs, not vectors)
;; - Does NOT score divergence strength (it's binary: detected or not)
;; - Does NOT check MACD, OBV, or other indicators (RSI only, for now)
;; - Does NOT import holon or create vectors
;; - Pure function. Candles in, divergences out.
