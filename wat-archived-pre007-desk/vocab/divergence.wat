;; ── vocab/divergence.wat — structural divergence detection ──────
;;
;; Uses PELT changepoints to find structural peaks and troughs,
;; then detects when price and RSI disagree at turning points.
;;
;; Bearish divergence: price makes higher high, RSI makes lower high.
;; Bullish divergence: price makes lower low, RSI makes higher low.
;;
;; Lens: momentum

(require thought/pelt)

(define (pairs xs)
  "Sliding pairs: [a,b,c] → [(a,b), (b,c)]."
  (map (lambda (i) (list (nth xs i) (nth xs (+ i 1))))
       (range 0 (- (len xs) 1))))

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

  (define (segment-direction boundaries i close-ln)
    "Direction of segment i: +1 (up), -1 (down), 0 (flat).
     Compares value at segment end to segment start."
    (let ((change (- (nth close-ln (- (nth boundaries (+ i 1)) 1))
                     (nth close-ln (nth boundaries i)))))
      (cond ((> change 1e-10)  1)
            ((< change -1e-10) -1)
            (else              0))))

  (define (find-peaks seg-dirs boundaries)
    "Indices where an up-segment meets a down-segment (structural highs)."
    (filter-map (lambda (i) (when (and (= (nth seg-dirs i) 1)
                                       (= (nth seg-dirs (+ i 1)) -1))
                              (- (nth boundaries (+ i 1)) 1)))
                (range 0 (- (len seg-dirs) 1))))

  (define (find-troughs seg-dirs boundaries)
    "Indices where a down-segment meets an up-segment (structural lows)."
    (filter-map (lambda (i) (when (and (= (nth seg-dirs i) -1)
                                       (= (nth seg-dirs (+ i 1)) 1))
                              (- (nth boundaries (+ i 1)) 1)))
                (range 0 (- (len seg-dirs) 1))))

  (define (check-bearish-pairs peaks candles n)
    "Consecutive peaks where price makes higher high but RSI makes lower high."
    (filter-map (lambda (pair)
      (let ((prev (first pair)) (curr (second pair)))
        (when (and (> (:close (nth candles curr)) (:close (nth candles prev)))
                   (< (:rsi (nth candles curr)) (:rsi (nth candles prev))))
          (divergence :kind "bearish" :indicator "rsi"
                      :price-dir "up" :indicator-dir "down"
                      :candles-ago (- n 1 curr)))))
      (pairs peaks)))

  (define (check-bullish-pairs troughs candles n)
    "Consecutive troughs where price makes lower low but RSI makes higher low."
    (filter-map (lambda (pair)
      (let ((prev (first pair)) (curr (second pair)))
        (when (and (< (:close (nth candles curr)) (:close (nth candles prev)))
                   (> (:rsi (nth candles curr)) (:rsi (nth candles prev))))
          (divergence :kind "bullish" :indicator "rsi"
                      :price-dir "down" :indicator-dir "up"
                      :candles-ago (- n 1 curr)))))
      (pairs troughs)))

  (let ((close-ln (map (lambda (c) (ln (:close c))) candles))
        (n        (len candles))
        (cps      (pelt-changepoints close-ln (bic-penalty close-ln)))
        (boundaries (append [0] cps [(len close-ln)]))
        (seg-dirs (map (lambda (i) (segment-direction boundaries i close-ln))
                       (range 0 (- (len boundaries) 1))))
        (peaks    (find-peaks seg-dirs boundaries))
        (troughs  (find-troughs seg-dirs boundaries)))

    (append
      (check-bearish-pairs peaks candles n)
      (check-bullish-pairs troughs candles n))))

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
;; - Requires thought/pelt for PELT changepoint detection
;; - Pure function. Candles in, divergences out.
