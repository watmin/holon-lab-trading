;; ── volume expert ──────────────────────────────────────────────────
;;
;; Thinks about: participation and conviction behind price moves.
;; Window: sampled from [12, 2016] per candle.
;;
;; (require stdlib)             ; comparisons, zones
;; (require mod/flow)           ; OBV, VWAP, A/D, MFI, CMF, buying/selling pressure
;; (require mod/participation)  ; volume confirmation, spikes, candle patterns
;;
;; The volume expert judges whether price moves have backing.
;; A rally on low volume is suspect. A breakout on high volume
;; is confirmed. Volume is the market's conviction about its own moves.

;; ── Eval methods ────────────────────────────────────────────────────
;; eval_volume_confirmation — current volume vs window average, direction match
;; eval_volume_analysis     — OBV direction, volume SMA, spike/drought zones
;; eval_price_action        — inside bar, outside bar, gaps, consecutive candles

;; ── Example thoughts ────────────────────────────────────────────────
;;
;; (bundle
;;   (bind at (bind volume volume-spike))    ; volume is 2x+ above average
;;   (bind at (bind close inside-bar))        ; price compressed (inside bar)
;;   (bind at (bind close gap-up))            ; gap up from previous close
;;   (bind at (bind close consecutive-up))    ; 3+ consecutive green candles
;;   ...)

;; ── DISCOVERY ───────────────────────────────────────────────────────
;; Volume is the THINNEST expert vocabulary. Only 3 eval methods.
;; The other experts have 5-7 each. Volume rarely proves its gate
;; (appeared in proven list only once in the 100k run, at 50k).
;;
;; Questions:
;; 1. Is volume inherently less predictive, or is the vocabulary too thin?
;; 2. Should volume get OBV divergence detection (OBV trending opposite to price)?
;; 3. Should volume get VWAP (volume-weighted average price) as a comparison target?
;; 4. Should volume see money flow (buying vs selling volume)?
;; 5. Should price action (inside bar, gaps) stay with volume or move to structure?
;;    Inside bars are geometric (structure) but validated by volume (volume).

;; ── What volume does NOT see ────────────────────────────────────────
;; - Comparisons (momentum, structure)
;; - PELT segments (narrative, structure)
;; - Temporal crosses (narrative, momentum)
;; - Oscillators (momentum)
;; - Cloud/fib/keltner (structure)
;; - Calendar (narrative)
;; - Advanced regime indicators (regime, momentum, structure)
