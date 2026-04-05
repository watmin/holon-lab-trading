;; ── candle.wat — indicator fold library ──────────────────────────────
;;
;; Each indicator is a state struct + pure step function.
;; (state, input) → (state, output). No closures. No hidden mutation.
;; State is data. Computation is function. They are separate.
;;
;; The enterprise creates an indicator-bank at startup.
;; Each candle ticks all indicators via tick-indicators.
;; Vocab modules read from the bank, not from a 52-field struct.
;;
;; See proposal 005 (streaming indicator folds) for the design.
;;
;; Live. The Rust IndicatorBank::tick() implements this fold exactly.
;; Each desk steps its own indicator bank from raw OHLCV per candle.

(require core/structural)

;; ── Raw input ──────────────────────────────────────────────────────

(struct raw-candle ts open high low close volume)

;; ── Computed candle ───────────────────────────────────────────────
;;
;; The output of tick-indicators: raw OHLCV + all derived indicators.
;; Built by IndicatorBank::tick() from a single raw-candle.
;; Vocab modules read fields from this struct.

(struct candle
  ;; Raw OHLCV
  ts open high low close volume
  ;; Moving averages
  sma20 sma50 sma200
  ;; Bollinger Bands (20-period, 2σ)
  bb-upper bb-lower bb-width
  ;; RSI (14-period Wilder)
  rsi
  ;; MACD (12, 26, 9)
  macd-line macd-signal macd-hist
  ;; DMI / ADX (14-period)
  dmi-plus dmi-minus adx
  ;; ATR (14-period)
  atr
  atr-r                          ; ATR as ratio to close (atr / close)
  ;; Stochastic (14-period)
  stoch-k stoch-d
  ;; Williams %R (14-period)
  williams-r
  ;; CCI (20-period)
  cci
  ;; MFI (14-period)
  mfi
  ;; Rate of change (1, 3, 6, 12 period)
  roc-1 roc-3 roc-6 roc-12
  ;; OBV slope (12-period)
  obv-slope-12
  ;; Volume SMA (20-period)
  volume-sma-20
  ;; Multi-timeframe (1h=12 candles, 4h=48 candles)
  tf-1h-close tf-1h-high tf-1h-low tf-1h-ret tf-1h-body
  tf-4h-close tf-4h-high tf-4h-low tf-4h-ret tf-4h-body
  ;; Ichimoku Cloud (9/26/52-period midpoint system)
  tenkan-sen                     ; (highest-high + lowest-low) / 2 over 9 periods
  kijun-sen                      ; (highest-high + lowest-low) / 2 over 26 periods
  senkou-span-a                  ; (tenkan + kijun) / 2
  senkou-span-b                  ; (highest-high + lowest-low) / 2 over 52 periods
  cloud-top                      ; max(span-a, span-b)
  cloud-bottom                   ; min(span-a, span-b)
  ;; Derived
  bb-pos                         ; position within Bollinger Bands [0, 1]
  kelt-upper kelt-lower kelt-pos ; Keltner channel (20-period, 1.5× ATR)
  squeeze                        ; bool — BB inside Keltner
  range-pos-12 range-pos-24 range-pos-48  ; position within N-candle range
  trend-consistency-6 trend-consistency-12 trend-consistency-24
  atr-roc-6 atr-roc-12          ; ATR rate of change
  vol-accel                      ; volume acceleration
  ;; Time (f64 — feeds encode-circular)
  hour day-of-week)

;; ── Indicator implementations ─────────────────────────────────────
;;
;; Concrete indicators that satisfy the protocols above.
;;
;; scalar-indicator implementations:
;;   SMA      (periods: 20, 50, 200)
;;   EMA      (periods: 12, 20, 26 for MACD)
;;   Wilder   (RSI gains/losses, ATR, DMI+/-, ADX)
;;   Stddev   (20-period rolling, for Bollinger Bands)
;;
;; candle-indicator implementations:
;;   RSI      (14-period Wilder smoothing)
;;   MACD     (12, 26, 9 — two EMAs + signal line)
;;   DMI/ADX  (14-period Wilder, two-phase warmup)
;;   ATR      (14-period Wilder)
;;   Stochastic (14-period %K, 3-period SMA %D)
;;   CCI      (20-period — mean deviation)
;;   MFI      (14-period — windowed ring buffers)
;;   OBV      (cumulative, 12-period slope via linreg)
;;   ROC      (1, 3, 6, 12 period — ring buffers)
;;
;; Derived (computed from other indicators, no own state):
;;   Bollinger position, Keltner channel, squeeze detection,
;;   range position, trend consistency, ATR ROC, volume acceleration,
;;   multi-timeframe aggregation (1h=12, 4h=48)
;;
;; Ichimoku Cloud (streaming, per-candle):
;;   Tenkan-sen   (9-period rolling high/low midpoint)
;;   Kijun-sen    (26-period rolling high/low midpoint)
;;   Senkou Span A (average of tenkan + kijun)
;;   Senkou Span B (52-period rolling high/low midpoint)
;;   Cloud top/bottom (max/min of span A, span B)
;;   Note: no future displacement — values are at present position.
;;   Chikou span not computed (requires backward projection).
;;
;; Rolling computed (from candle window, not per-candle):
;;   rsi-sma  — 14-period SMA of RSI values, computed by ThoughtEncoder
;;   Fibonacci — swing detection from window
;;   Hurst/DFA/entropy — statistical properties of window returns

;; ── The indicator protocol ─────────────────────────────────────────
;;
;; Every indicator satisfies this contract:
;;   step  — advance state by one input, return (new-state, output)
;;   new   — create initial state from parameters

(defprotocol scalar-indicator
  "A scalar stream processor. State in, state out."
  (step [state input] "Advance by one input. Returns (state, output).")
  (new [params] "Create initial state."))

(defprotocol candle-indicator
  "An indicator that reads from a raw candle. Destructures what it needs."
  (step [state candle] "Advance by one raw-candle. Returns (state, output).")
  (new [params] "Create initial state."))

;; ── Primitive state machines ───────────────────────────────────────

;; SMA: sliding window average. O(period) memory.
(struct sma-state buffer period)

(define (new-sma period)
  (sma-state :buffer (deque) :period period))

(define (sma-step state value)
  "Feed one value. Returns (new-state, sma-value).
   Returns 0.0 when fewer than period values have been seen.
   Matches build_candles::sma() exactly."
  (let ((buf (push-back (:buffer state) value)))
    (let ((buf (if (> (len buf) (:period state)) (pop-front buf) buf)))
      (list (update state :buffer buf)
            (if (< (len buf) (:period state))
                0.0
                (/ (fold + 0.0 buf) (:period state)))))))

;; EMA: exponential moving average with SMA seed (ta-lib canonical).
;; First `period` values averaged as SMA seed, then EMA recursive.
(struct ema-state alpha prev period count accum)

(define (new-ema period)
  (ema-state :alpha (/ 2.0 (+ period 1)) :prev 0.0
             :period period :count 0 :accum 0.0))

(define (ema-step state value)
  "Feed one value. Returns (new-state, ema-value).
   Warmup: accumulate period values, seed with SMA. Then EMA recursive."
  (let ((count (+ (:count state) 1)))
    (if (<= count (:period state))
        (let ((accum (+ (:accum state) value)))
          (if (= count (:period state))
              ;; Warmup complete: SMA seed
              (let ((avg (/ accum (:period state))))
                (list (update state :count count :accum accum :prev avg) avg))
              ;; Still warming up
              (list (update state :count count :accum accum) 0.0)))
        ;; After warmup: EMA recursive
        (let ((new (+ (* (:alpha state) value)
                       (* (- 1.0 (:alpha state)) (:prev state)))))
          (list (update state :count count :prev new) new)))))

;; Wilder: smoothed average. O(1) after warmup.
;; First `period` values averaged, then smooth_t = (prev*(p-1) + value) / p.
(struct wilder-state count accum prev period)

(define (new-wilder period)
  (wilder-state :count 0 :accum 0.0 :prev 0.0 :period period))

(define (wilder-step state value)
  "Feed one value. Returns (new-state, smoothed-value).
   During warmup (count < period): accumulate, return 0.0 (no signal).
   At count == period: compute initial average, return it.
   After: Wilder smooth. Matches Python ta-lib behavior."
  (let ((count (+ (:count state) 1))
        (period (:period state)))
    (if (<= count period)
        (let ((accum (+ (:accum state) value)))
          (if (= count period)
              ;; Warmup complete: initial average
              (let ((avg (/ accum period)))
                (list (update state :count count :accum accum :prev avg) avg))
              ;; Still warming up: accumulate, no output
              (list (update state :count count :accum accum) 0.0)))
        (let ((new (/ (+ (* (:prev state) (- period 1)) value) period)))
          (list (update state :count count :prev new) new)))))

;; Stddev: rolling standard deviation. O(period) memory.
;; Maintains a ring buffer + running SMA for the mean.
(struct stddev-state sma-state buffer period)

(define (new-stddev period)
  (stddev-state :sma-state (new-sma period) :buffer (deque) :period period))

(define (stddev-step state value)
  "Feed one value. Returns (new-state, stddev-value)."
  (let* ((sma-result (sma-step (:sma-state state) value))
         (sma-state  (first sma-result))
         (mean       (second sma-result))
         (buf        (push-back (:buffer state) value))
         (buf        (if (> (len buf) (:period state)) (pop-front buf) buf))
         (variance   (/ (fold + 0.0
                          (map (lambda (x) (* (- x mean) (- x mean))) buf))
                        (len buf))))
    (list (update state :sma-state sma-state :buffer buf)
          (sqrt variance))))

;; Ring buffer: fixed-size sliding window. O(period) memory.
;; Used by ROC, CCI, OBV slope, multi-timeframe, range position,
;; trend consistency, ATR ROC.
(struct ring-state buffer period)

(define (new-ring period)
  (ring-state :buffer (deque) :period period))

(define (ring-push state value)
  "Push one value. Returns new ring-state."
  (let ((buf (push-back (:buffer state) value)))
    (let ((buf (if (> (len buf) (:period state)) (pop-front buf) buf)))
      (update state :buffer buf))))

(define (ring-full? state)
  (= (len (:buffer state)) (:period state)))

(define (ring-oldest state)
  (first (:buffer state)))

;; Linear regression slope over a ring buffer's contents.
(define (linreg-slope buf)
  "Compute OLS slope of values in buf indexed by position."
  (let* ((n   (len buf))
         (nf  (* 1.0 n))
         (sx  (/ (* nf (- nf 1.0)) 2.0))             ; sum of 0..n-1
         (sxx (/ (* nf (- nf 1.0) (- (* 2.0 nf) 1.0)) 6.0)) ; sum of i^2
         (sy  (fold + 0.0 buf))
         (indices (range n))
         (sxy (fold + 0.0
                (map (lambda (j v) (* (* 1.0 j) v)) indices buf)))
         (denom (- (* nf sxx) (* sx sx))))
    (if (< (abs denom) 1e-10) 0.0
        (/ (- (* nf sxy) (* sx sy)) denom))))

;; ── Composed indicators ────────────────────────────────────────────

;; RSI: Wilder-smoothed gain/loss ratio. O(1).
(struct rsi-state gain-wilder loss-wilder prev-close started)

(define (new-rsi period)
  (rsi-state :gain-wilder (new-wilder period)
             :loss-wilder (new-wilder period)
             :prev-close 0.0 :started false))

(define (rsi-step state close)
  "Feed close price. Returns (new-state, rsi-value)."
  (if (not (:started state))
      (list (update state :started true :prev-close close) 50.0)
      (let* ((change (- close (:prev-close state)))
             (g (wilder-step (:gain-wilder state) (max 0.0 change)))
             (l (wilder-step (:loss-wilder state) (max 0.0 (- change))))
             (avg-gain (second g))
             (avg-loss (second l)))
        (list (update state
                :gain-wilder (first g)
                :loss-wilder (first l)
                :prev-close close)
              (- 100.0 (/ 100.0 (+ 1.0 (/ avg-gain (max avg-loss 1e-10)))))))))

;; ATR: Wilder-smoothed true range. O(1).
(struct atr-state wilder prev-close started)

(define (new-atr period)
  (atr-state :wilder (new-wilder period) :prev-close 0.0 :started false))

(define (atr-step state candle)
  "Feed a candle. Returns (new-state, atr-value)."
  (let ((high (:high candle)) (low (:low candle)) (close (:close candle)))
    (if (not (:started state))
        (let ((result (wilder-step (:wilder state) (- high low))))
          (list (update state :wilder (first result) :started true :prev-close close)
                (second result)))
        (let ((tr (max (- high low)
                       (abs (- high (:prev-close state)))
                       (abs (- low (:prev-close state))))))
          (let ((result (wilder-step (:wilder state) tr)))
            (list (update state :wilder (first result) :prev-close close)
                  (second result)))))))

;; MACD: two EMAs + signal EMA. O(1).
(struct macd-state ema12 ema26 signal)

(define (new-macd)
  (macd-state :ema12 (new-ema 12) :ema26 (new-ema 26) :signal (new-ema 9)))

(define (macd-step state close)
  "Feed close. Returns (new-state, (macd-line, macd-signal, macd-hist))."
  (let* ((e12     (ema-step (:ema12 state) close))
         (e26     (ema-step (:ema26 state) close))
         (line    (- (second e12) (second e26)))
         (sig     (ema-step (:signal state) line)))
    (list (update state :ema12 (first e12) :ema26 (first e26) :signal (first sig))
          (list line (second sig) (- line (second sig))))))

;; DMI/ADX: Wilder-smoothed directional movement. O(1).
;; ADX uses two-phase accumulation matching build_candles:
;;   Phase 1 (count <= period): DM/ATR Wilders accumulate. ADX not fed.
;;   Phase 2 (count > period):  DI values valid. DX fed to ADX Wilder.
;; This ensures ADX only sees DX from converged DI values.
(struct dmi-state plus-wilder minus-wilder atr-wilder adx-wilder
        prev-high prev-low prev-close started count period)

(define (new-dmi period)
  (dmi-state :plus-wilder (new-wilder period) :minus-wilder (new-wilder period)
             :atr-wilder (new-wilder period) :adx-wilder (new-wilder period)
             :prev-high 0.0 :prev-low 0.0 :prev-close 0.0
             :started false :count 0 :period period))

(define (dmi-step state candle)
  "Feed a candle. Returns (new-state, (dmi-plus, dmi-minus, adx)).
   ADX only begins accumulating after DM/ATR Wilders have completed warmup."
  (let ((high (:high candle)) (low (:low candle)) (close (:close candle)))
    (if (not (:started state))
        (list (update state :started true :prev-high high :prev-low low :prev-close close
                      :count 1)
              (list 0.0 0.0 0.0))
        (let* ((count     (+ (:count state) 1))
               (up-move   (- high (:prev-high state)))
               (down-move (- (:prev-low state) low))
               (plus-dm   (if (and (> up-move down-move) (> up-move 0.0)) up-move 0.0))
               (minus-dm  (if (and (> down-move up-move) (> down-move 0.0)) down-move 0.0))
               (tr        (max (- high low)
                               (abs (- high (:prev-close state)))
                               (abs (- low (:prev-close state)))))
               (p-result  (wilder-step (:plus-wilder state) plus-dm))
               (m-result  (wilder-step (:minus-wilder state) minus-dm))
               (a-result  (wilder-step (:atr-wilder state) tr))
               (atr-val   (max (second a-result) 1e-10))
               (dmi-plus  (/ (* (second p-result) 100.0) atr-val))
               (dmi-minus (/ (* (second m-result) 100.0) atr-val))
               (dx        (/ (* (abs (- dmi-plus dmi-minus)) 100.0)
                             (max (+ dmi-plus dmi-minus) 1e-10)))
               ;; Only feed DX to ADX after DM/ATR warmup (count > period)
               (adx-result (if (>= count (:period state))
                               (wilder-step (:adx-wilder state) dx)
                               (list (:adx-wilder state) 0.0))))
          (list (update state
                  :plus-wilder (first p-result) :minus-wilder (first m-result)
                  :atr-wilder (first a-result) :adx-wilder (first adx-result)
                  :prev-high high :prev-low low :prev-close close
                  :count count)
                (list dmi-plus dmi-minus (second adx-result)))))))

;; Stochastic %K: sliding window min/max. O(period).
(struct stoch-state high-buf low-buf period)

(define (new-stoch period)
  (stoch-state :high-buf (deque) :low-buf (deque) :period period))

(define (stoch-step state candle)
  "Feed a candle. Returns (new-state, stoch-k)."
  (let ((high (:high candle)) (low (:low candle)) (close (:close candle)))
    (let ((hbuf (push-back (:high-buf state) high))
          (lbuf (push-back (:low-buf state) low)))
      (let ((hbuf (if (> (len hbuf) (:period state)) (pop-front hbuf) hbuf))
            (lbuf (if (> (len lbuf) (:period state)) (pop-front lbuf) lbuf))
            (hi   (fold max (first hbuf) (rest hbuf)))
            (lo   (fold min (first lbuf) (rest lbuf))))
        (list (update state :high-buf hbuf :low-buf lbuf)
              (* (/ (- close lo) (max (- hi lo) 1e-10)) 100.0))))))

;; ROC (Rate of Change): ring buffer of N closes.
;; roc = (current - oldest) / oldest.
(struct roc-state ring)

(define (new-roc period)
  ;; Period+1 because we need the value N steps ago plus the current.
  (roc-state :ring (new-ring (+ period 1))))

(define (roc-step state close)
  "Feed close. Returns (new-state, roc-value)."
  (let ((ring (ring-push (:ring state) close)))
    (if (not (ring-full? ring))
        (list (update state :ring ring) 0.0)
        (let ((oldest (ring-oldest ring)))
          (list (update state :ring ring)
                (if (< (abs oldest) 1e-10) 0.0
                    (/ (- close oldest) oldest)))))))

;; CCI (Commodity Channel Index): typical price SMA + mean deviation.
;; CCI = (TP - SMA(TP, 20)) / (0.015 * mean_dev).
(struct cci-state tp-sma tp-ring period)

(define (new-cci period)
  (cci-state :tp-sma (new-sma period) :tp-ring (new-ring period) :period period))

(define (cci-step state candle)
  "Feed a candle. Returns (new-state, cci-value)."
  (let* ((tp       (/ (+ (:high candle) (:low candle) (:close candle)) 3.0))
         (sma-r    (sma-step (:tp-sma state) tp))
         (tp-mean  (second sma-r))
         (ring     (ring-push (:tp-ring state) tp))
         (buf      (:buffer ring))
         (md       (/ (fold + 0.0 (map (lambda (x) (abs (- x tp-mean))) buf))
                      (len buf))))
    (list (update state :tp-sma (first sma-r) :tp-ring ring)
          (if (< md 1e-10) 0.0
              (/ (- tp tp-mean) (* 0.015 md))))))

;; MFI (Money Flow Index): like RSI but on money flow (TP * volume).
;; Accumulates positive/negative flow over a sliding window.
(struct mfi-state flow-ring tp-ring prev-tp period started)

(define (new-mfi period)
  (mfi-state :flow-ring (new-ring period) :tp-ring (new-ring period)
             :prev-tp 0.0 :period period :started false))

(define (mfi-step state candle)
  "Feed a candle. Returns (new-state, mfi-value)."
  (let ((tp (/ (+ (:high candle) (:low candle) (:close candle)) 3.0))
        (vol (:volume candle)))
    (if (not (:started state))
        (list (update state :started true :prev-tp tp) 50.0)
        (let* ((mf (* tp vol))
               ;; positive flow is +mf when TP rises, negative flow is +mf when TP falls
               (signed-mf (if (> tp (:prev-tp state)) mf (- mf)))
               (ring (ring-push (:flow-ring state) signed-mf))
               (buf  (:buffer ring))
               (pos-flow (fold + 0.0 (map (lambda (x) (if (> x 0.0) x 0.0)) buf)))
               (neg-flow (fold + 0.0 (map (lambda (x) (if (< x 0.0) (- x) 0.0)) buf))))
          (list (update state :flow-ring ring :prev-tp tp)
                (if (< neg-flow 1e-10) 100.0
                    (- 100.0 (/ 100.0 (+ 1.0 (/ pos-flow neg-flow))))))))))

;; Williams %R: reuses the stochastic high/low window.
;; %R = -100 * (highest - close) / (highest - lowest).
;; Shares the stoch-state struct — step reads the same buffers.
(define (williams-step state candle)
  "Feed a candle to a stoch-state. Returns (new-state, williams-%R)."
  (let ((high (:high candle)) (low (:low candle)) (close (:close candle)))
    (let ((hbuf (push-back (:high-buf state) high))
          (lbuf (push-back (:low-buf state) low)))
      (let ((hbuf (if (> (len hbuf) (:period state)) (pop-front hbuf) hbuf))
            (lbuf (if (> (len lbuf) (:period state)) (pop-front lbuf) lbuf))
            (hi   (fold max (first hbuf) (rest hbuf)))
            (lo   (fold min (first lbuf) (rest lbuf))))
        (list (update state :high-buf hbuf :low-buf lbuf)
              (let ((range (- hi lo)))
                (if (< range 1e-10) -50.0
                    (* -100.0 (/ (- hi close) range)))))))))

;; OBV Slope: cumulative OBV + ring buffer of 12 values + linear regression.
(struct obv-state obv-accum ring prev-close started)

(define (new-obv-slope period)
  (obv-state :obv-accum 0.0 :ring (new-ring period)
             :prev-close 0.0 :started false))

(define (obv-step state candle)
  "Feed a candle. Returns (new-state, obv-slope)."
  (let ((close (:close candle)) (vol (:volume candle)))
    (if (not (:started state))
        (list (update state :started true :prev-close close) 0.0)
        (let* ((delta (cond ((> close (:prev-close state)) vol)
                            ((< close (:prev-close state)) (- vol))
                            (else 0.0)))
               (new-obv (+ (:obv-accum state) delta))
               (ring    (ring-push (:ring state) new-obv)))
          (list (update state :obv-accum new-obv :ring ring :prev-close close)
                (if (ring-full? ring)
                    (linreg-slope (:buffer ring))
                    0.0))))))

;; Multi-timeframe aggregation: ring buffer of N candles.
;; Outputs: close, period high, period low, return, body ratio.
(struct mtf-state candle-ring period)

(define (new-mtf period)
  (mtf-state :candle-ring (new-ring period) :period period))

(define (mtf-step state candle)
  "Feed a candle. Returns (new-state, (close, high, low, return, body))."
  (let* ((ring (ring-push (:candle-ring state) candle))
         (buf  (:buffer ring))
         (close (:close candle)))
    (if (not (ring-full? ring))
        (list (update state :candle-ring ring)
              (list close (:high candle) (:low candle) 0.0 0.0))
        (let* ((hi  (fold max (:high (first buf))
                      (map (lambda (c) (:high c)) (rest buf))))
               (lo  (fold min (:low (first buf))
                      (map (lambda (c) (:low c)) (rest buf))))
               (open-first (:open (first buf)))
               (ret (if (< (abs open-first) 1e-10) 0.0
                        (/ (- close open-first) open-first)))
               (range (- hi lo))
               (body (if (< range 1e-10) 0.0
                         (/ (abs (- close open-first)) range))))
          (list (update state :candle-ring ring)
                (list close hi lo ret body))))))

;; Range Position: (close - period_low) / (period_high - period_low).
(struct rangepos-state high-ring low-ring period)

(define (new-rangepos period)
  (rangepos-state :high-ring (new-ring period) :low-ring (new-ring period) :period period))

(define (rangepos-step state candle)
  "Feed a candle. Returns (new-state, range-position)."
  (let ((hring (ring-push (:high-ring state) (:high candle)))
        (lring (ring-push (:low-ring state) (:low candle))))
    (let ((close (:close candle)))
      (if (not (ring-full? hring))
          (list (update state :high-ring hring :low-ring lring) 0.5)
          (let* ((hi (fold max (first (:buffer hring)) (rest (:buffer hring))))
                 (lo (fold min (first (:buffer lring)) (rest (:buffer lring))))
                 (range (- hi lo)))
            (list (update state :high-ring hring :low-ring lring)
                  (if (< range 1e-10) 0.5
                      (/ (- close lo) range))))))))

;; Trend Consistency: fraction of up-moves in a window.
(struct trendcons-state ring period prev-close started)

(define (new-trendcons period)
  (trendcons-state :ring (new-ring period) :period period
                   :prev-close 0.0 :started false))

(define (trendcons-step state close)
  "Feed close. Returns (new-state, trend-consistency)."
  (if (not (:started state))
      (list (update state :started true :prev-close close) 0.5)
      (let* ((up? (if (> close (:prev-close state)) 1.0 0.0))
             (ring (ring-push (:ring state) up?))
             (buf  (:buffer ring))
             (ups  (fold + 0.0 buf))
             (n    (len buf)))
        (list (update state :ring ring :prev-close close)
              (/ ups (* 1.0 n))))))

;; ATR ROC: ROC applied to ATR values (not closes).
;; Reuses roc-state. Just feed ATR values instead of closes.
;; No new struct needed — use (new-roc period) and (roc-step state atr-val).

;; ── Protocol satisfaction ───────────────────────────────────────────
;;
;; Each indicator proves it satisfies the contract.
;; The mapping IS the specification. Explicit, exhaustive.

;; Scalar indicators: (state, f64) → (state, f64)
(satisfies sma-state scalar-indicator
  :step sma-step
  :new  new-sma)

(satisfies ema-state scalar-indicator
  :step ema-step
  :new  new-ema)

(satisfies wilder-state scalar-indicator
  :step wilder-step
  :new  new-wilder)

(satisfies stddev-state scalar-indicator
  :step stddev-step
  :new  new-stddev)

(satisfies rsi-state scalar-indicator
  :step rsi-step
  :new  new-rsi)

(satisfies macd-state scalar-indicator
  :step macd-step
  :new  new-macd)

;; Candle indicators: (state, high, low, close) → (state, output)
(satisfies atr-state candle-indicator
  :step atr-step
  :new  new-atr)

(satisfies dmi-state candle-indicator
  :step dmi-step
  :new  new-dmi)

(satisfies stoch-state candle-indicator
  :step stoch-step
  :new  new-stoch)

;; ROC: scalar — (state, close) → (state, roc)
(satisfies roc-state scalar-indicator
  :step roc-step
  :new  new-roc)

;; CCI: candle — (state, candle) → (state, cci)
(satisfies cci-state candle-indicator
  :step cci-step
  :new  new-cci)

;; MFI: candle — (state, candle) → (state, mfi)
(satisfies mfi-state candle-indicator
  :step mfi-step
  :new  new-mfi)

;; OBV slope: candle — (state, candle) → (state, slope)
(satisfies obv-state candle-indicator
  :step obv-step
  :new  new-obv-slope)

;; Multi-timeframe: candle — (state, candle) → (state, (close, hi, lo, ret, body))
(satisfies mtf-state candle-indicator
  :step mtf-step
  :new  new-mtf)

;; Range position: candle — (state, candle) → (state, position)
(satisfies rangepos-state candle-indicator
  :step rangepos-step
  :new  new-rangepos)

;; Trend consistency: scalar — (state, close) → (state, fraction)
(satisfies trendcons-state scalar-indicator
  :step trendcons-step
  :new  new-trendcons)

;; ── The indicator bank ─────────────────────────────────────────────
;;
;; A product of states. Named fields. Serializable, checkpointable.
;; Current + prev for cross-detection modules.

(struct indicator-bank
  ;; Scalar stream processor states
  sma20 sma50 sma200
  bb-stddev                    ; stddev for Bollinger
  ema20                        ; for Keltner
  rsi
  macd
  dmi                          ; DMI + ADX
  atr
  stoch                        ; Stochastic %K
  stoch-d-sma                  ; %D = SMA(3) of %K
  williams-buf                 ; reuses stoch window (stoch-state)
  volume-sma20

  ;; ROC states (one per period)
  roc-1 roc-3 roc-6 roc-12

  ;; CCI state (20-period)
  cci-state

  ;; MFI state (14-period)
  mfi-state

  ;; OBV slope state (12-period)
  obv-slope-state

  ;; Multi-timeframe states
  mtf-1h                       ; 12-candle (1 hour)
  mtf-4h                       ; 48-candle (4 hours)

  ;; Range position states
  rangepos-12 rangepos-24 rangepos-48

  ;; Trend consistency states
  trendcons-6 trendcons-12 trendcons-24

  ;; ATR ROC states (roc-state fed ATR values)
  atr-roc-6 atr-roc-12

  ;; Current indicator values (updated each tick)
  ;; Optional — absent during warmup
  sma20-val? sma50-val? sma200-val?
  bb-upper? bb-lower? bb-width?
  rsi-val?
  macd-line? macd-signal? macd-hist?
  dmi-plus? dmi-minus? adx?
  atr-val? atr-r?
  stoch-k? stoch-d?
  williams-r?
  cci?
  mfi?
  volume-sma20-val?
  roc-1? roc-3? roc-6? roc-12?
  obv-slope-12?

  ;; Multi-timeframe values
  tf-1h-close? tf-1h-high? tf-1h-low? tf-1h-ret? tf-1h-body?
  tf-4h-close? tf-4h-high? tf-4h-low? tf-4h-ret? tf-4h-body?

  ;; Range position values
  range-pos-12? range-pos-24? range-pos-48?

  ;; Trend consistency values
  trend-consistency-6? trend-consistency-12? trend-consistency-24?

  ;; ATR ROC values
  atr-roc-6? atr-roc-12?

  ;; Derived (no fold state — computed inline from other bank values)
  vol-accel?                   ; volume / volume-sma20
  bb-pos?                      ; (close - bb-lower) / (bb-upper - bb-lower)
  kelt-upper? kelt-lower?
  kelt-pos?                    ; (close - kelt-lower) / (kelt-upper - kelt-lower)
  squeeze?                     ; bb inside keltner

  ;; Previous values for cross-detection
  rsi-prev? stoch-k-prev? stoch-d-prev?
  macd-line-prev? macd-signal-prev?
  sma50-prev? sma200-prev?

  ;; Pre-computed from raw (no fold state needed)
  close prev-close?)

;; ── Constructor ────────────────────────────────────────────────────

(define (new-indicator-bank)
  "Create an indicator bank with all state machines initialized.
   All output value fields start absent/false."
  (indicator-bank
    ;; Scalar stream processor states
    :sma20 (new-sma 20) :sma50 (new-sma 50) :sma200 (new-sma 200)
    :bb-stddev (new-stddev 20)
    :ema20 (new-ema 20)
    :rsi (new-rsi 14)
    :macd (new-macd)
    :dmi (new-dmi 14)
    :atr (new-atr 14)
    :stoch (new-stoch 14)
    :stoch-d-sma (new-sma 3)
    :williams-buf (new-stoch 14)
    :volume-sma20 (new-sma 20)

    ;; ROC states
    :roc-1 (new-roc 1) :roc-3 (new-roc 3)
    :roc-6 (new-roc 6) :roc-12 (new-roc 12)

    ;; CCI, MFI, OBV
    :cci-state (new-cci 20)
    :mfi-state (new-mfi 14)
    :obv-slope-state (new-obv-slope 12)

    ;; Multi-timeframe
    :mtf-1h (new-mtf 12) :mtf-4h (new-mtf 48)

    ;; Range position
    :rangepos-12 (new-rangepos 12) :rangepos-24 (new-rangepos 24)
    :rangepos-48 (new-rangepos 48)

    ;; Trend consistency
    :trendcons-6 (new-trendcons 6) :trendcons-12 (new-trendcons 12)
    :trendcons-24 (new-trendcons 24)

    ;; ATR ROC
    :atr-roc-6 (new-roc 6) :atr-roc-12 (new-roc 12)

    ;; All output values absent/false during warmup
    :sma20-val? false :sma50-val? false :sma200-val? false
    :bb-upper? false :bb-lower? false :bb-width? false
    :rsi-val? false
    :macd-line? false :macd-signal? false :macd-hist? false
    :dmi-plus? false :dmi-minus? false :adx? false
    :atr-val? false :atr-r? false
    :stoch-k? false :stoch-d? false
    :williams-r? false
    :cci? false :mfi? false
    :volume-sma20-val? false
    :roc-1? false :roc-3? false :roc-6? false :roc-12? false
    :obv-slope-12? false
    :tf-1h-close? false :tf-1h-high? false :tf-1h-low? false
    :tf-1h-ret? false :tf-1h-body? false
    :tf-4h-close? false :tf-4h-high? false :tf-4h-low? false
    :tf-4h-ret? false :tf-4h-body? false
    :range-pos-12? false :range-pos-24? false :range-pos-48? false
    :trend-consistency-6? false :trend-consistency-12? false
    :trend-consistency-24? false
    :atr-roc-6? false :atr-roc-12? false
    :vol-accel? false
    :bb-pos? false
    :kelt-upper? false :kelt-lower? false :kelt-pos? false
    :squeeze? false
    :rsi-prev? false :stoch-k-prev? false :stoch-d-prev? false
    :macd-line-prev? false :macd-signal-prev? false
    :sma50-prev? false :sma200-prev? false
    :close false :prev-close? false))

;; ── Computed candle ─────────────────────────────────────────────────
;;
;; The output of tick-indicators: all indicator values the Candle struct needs.
;; Enterprise.wat expects (list updated-bank computed-candle) from tick-indicators.

(struct computed-candle
  ts open high low close volume
  hour day-of-week
  sma20 sma50 sma200
  bb-upper bb-lower bb-width
  rsi
  macd-line macd-signal macd-hist
  dmi-plus dmi-minus adx
  atr atr-r
  stoch-k stoch-d
  williams-r
  cci mfi
  volume-sma20
  roc-1 roc-3 roc-6 roc-12
  obv-slope-12
  tf-1h-close tf-1h-high tf-1h-low tf-1h-ret tf-1h-body
  tf-4h-close tf-4h-high tf-4h-low tf-4h-ret tf-4h-body
  range-pos-12 range-pos-24 range-pos-48
  trend-consistency-6 trend-consistency-12 trend-consistency-24
  atr-roc-6 atr-roc-12
  vol-accel bb-pos
  kelt-upper kelt-lower kelt-pos
  squeeze)

;; ── tick-indicators ────────────────────────────────────────────────
;;
;; The fold step. Advances all indicators with one candle.
;; Pure: bank in, (bank, computed-candle) out. No mutation. No side effects.

(define (tick-indicators bank candle)
  "Step all indicators with one candle. Returns (list updated-bank computed-candle)."
  (let* ((close  (:close candle))
         (high   (:high candle))
         (low    (:low candle))
         (volume (:volume candle))
         (hour       (timestamp-hour (:ts candle)))
         (day-of-week (timestamp-day-of-week (:ts candle)))

         ;; ── Scalar indicators — fed individual values ──────────
         (sma20-r  (sma-step (:sma20 bank) close))
         (sma50-r  (sma-step (:sma50 bank) close))
         (sma200-r (sma-step (:sma200 bank) close))
         (bb-r     (stddev-step (:bb-stddev bank) close))
         (ema20-r  (ema-step (:ema20 bank) close))
         (rsi-r    (rsi-step (:rsi bank) close))
         (macd-r   (macd-step (:macd bank) close))

         ;; ── Candle indicators — fed the whole candle ───────────
         (dmi-r    (dmi-step (:dmi bank) candle))
         (atr-r    (atr-step (:atr bank) candle))
         (stoch-r  (stoch-step (:stoch bank) candle))

         ;; ── Williams %R — reuses stoch-state, separate instance ──
         (will-r   (williams-step (:williams-buf bank) candle))

         ;; ── CCI ────────────────────────────────────────────────
         (cci-r    (cci-step (:cci-state bank) candle))

         ;; ── MFI ────────────────────────────────────────────────
         (mfi-r    (mfi-step (:mfi-state bank) candle))

         ;; ── ROC (four periods) ─────────────────────────────────
         (roc1-r   (roc-step (:roc-1 bank) close))
         (roc3-r   (roc-step (:roc-3 bank) close))
         (roc6-r   (roc-step (:roc-6 bank) close))
         (roc12-r  (roc-step (:roc-12 bank) close))

         ;; ── OBV slope ──────────────────────────────────────────
         (obv-r    (obv-step (:obv-slope-state bank) candle))

         ;; ── Multi-timeframe ────────────────────────────────────
         (mtf1h-r  (mtf-step (:mtf-1h bank) candle))
         (mtf4h-r  (mtf-step (:mtf-4h bank) candle))

         ;; ── Range position ─────────────────────────────────────
         (rp12-r   (rangepos-step (:rangepos-12 bank) candle))
         (rp24-r   (rangepos-step (:rangepos-24 bank) candle))
         (rp48-r   (rangepos-step (:rangepos-48 bank) candle))

         ;; ── Trend consistency ──────────────────────────────────
         (tc6-r    (trendcons-step (:trendcons-6 bank) close))
         (tc12-r   (trendcons-step (:trendcons-12 bank) close))
         (tc24-r   (trendcons-step (:trendcons-24 bank) close))

         ;; ── Derived scalars from existing indicators ───────────
         (stoch-d-r (sma-step (:stoch-d-sma bank) (second stoch-r)))
         (vol-r    (sma-step (:volume-sma20 bank) volume))

         ;; ── Extract values ─────────────────────────────────────
         (sma20-v  (second sma20-r))
         (bb-std   (second bb-r))
         (bb-up    (+ sma20-v (* 2.0 bb-std)))
         (bb-lo    (- sma20-v (* 2.0 bb-std)))
         (bb-w     (if (> sma20-v 1e-10) (/ (- bb-up bb-lo) sma20-v) 0.0))
         (ema20-v  (second ema20-r))
         (atr-v    (second atr-r))
         (kelt-up  (+ ema20-v (* 1.5 atr-v)))
         (kelt-lo  (- ema20-v (* 1.5 atr-v)))
         (vol-sma  (second vol-r))

         ;; ── ATR ROC — feed ATR value through ROC folds ─────────
         (atr-roc6-r  (roc-step (:atr-roc-6 bank) atr-v))
         (atr-roc12-r (roc-step (:atr-roc-12 bank) atr-v))

         ;; ── Derived: volume acceleration ───────────────────────
         (vol-accel (if (> vol-sma 1e-10) (/ volume vol-sma) 1.0))

         ;; ── Derived: Bollinger position ────────────────────────
         (bb-range (- bb-up bb-lo))
         (bb-pos   (if (> bb-range 1e-10)
                       (/ (- close bb-lo) bb-range)
                       0.5))

         ;; ── Derived: Keltner position ──────────────────────────
         (kelt-range (- kelt-up kelt-lo))
         (kelt-pos   (if (> kelt-range 1e-10)
                         (/ (- close kelt-lo) kelt-range)
                         0.5))

         ;; ── Derived: Squeeze (BB inside Keltner) ───────────────
         ;; Match batch: bb_width < kelt_width where kelt_width = 1.5*atr/ema20
         (kelt-w   (if (> ema20-v 1e-10) (/ (* atr-v 1.5) ema20-v) 0.0))
         (squeeze  (and (< bb-w kelt-w) (> kelt-w 0.0)))

         ;; ── Extract MTF tuples ─────────────────────────────────
         (mtf1h    (second mtf1h-r))
         (mtf4h    (second mtf4h-r)))

    (let ((atr-r-v (if (> close 1e-10) (/ atr-v close) 0.0))

           (updated-bank
             (update bank
               ;; ── Updated states ────────────────────────────────────────
               :sma20 (first sma20-r) :sma50 (first sma50-r) :sma200 (first sma200-r)
               :bb-stddev (first bb-r) :ema20 (first ema20-r)
               :rsi (first rsi-r) :macd (first macd-r)
               :dmi (first dmi-r) :atr (first atr-r)
               :stoch (first stoch-r) :stoch-d-sma (first stoch-d-r)
               :williams-buf (first will-r)
               :volume-sma20 (first vol-r)
               :roc-1 (first roc1-r) :roc-3 (first roc3-r)
               :roc-6 (first roc6-r) :roc-12 (first roc12-r)
               :cci-state (first cci-r)
               :mfi-state (first mfi-r)
               :obv-slope-state (first obv-r)
               :mtf-1h (first mtf1h-r) :mtf-4h (first mtf4h-r)
               :rangepos-12 (first rp12-r) :rangepos-24 (first rp24-r) :rangepos-48 (first rp48-r)
               :trendcons-6 (first tc6-r) :trendcons-12 (first tc12-r) :trendcons-24 (first tc24-r)
               :atr-roc-6 (first atr-roc6-r) :atr-roc-12 (first atr-roc12-r)

               ;; ── Shift current → prev ──────────────────────────────────
               :rsi-prev? (:rsi-val? bank)
               :stoch-k-prev? (:stoch-k? bank)
               :stoch-d-prev? (:stoch-d? bank)
               :macd-line-prev? (:macd-line? bank)
               :macd-signal-prev? (:macd-signal? bank)
               :sma50-prev? (:sma50-val? bank)
               :sma200-prev? (:sma200-val? bank)
               :prev-close? (:close bank)

               ;; ── New current values ────────────────────────────────────
               :close close
               :sma20-val? sma20-v
               :sma50-val? (second sma50-r)
               :sma200-val? (second sma200-r)
               :bb-upper? bb-up :bb-lower? bb-lo
               :bb-width? bb-w
               :rsi-val? (second rsi-r)
               :macd-line? (first (second macd-r))
               :macd-signal? (second (second macd-r))
               :macd-hist? (nth (second macd-r) 2)
               :dmi-plus? (first (second dmi-r))
               :dmi-minus? (second (second dmi-r))
               :adx? (nth (second dmi-r) 2)
               :atr-val? atr-v
               :atr-r? atr-r-v
               :stoch-k? (second stoch-r)
               :stoch-d? (second stoch-d-r)
               :williams-r? (second will-r)
               :cci? (second cci-r)
               :mfi? (second mfi-r)
               :volume-sma20-val? vol-sma
               :roc-1? (second roc1-r)
               :roc-3? (second roc3-r)
               :roc-6? (second roc6-r)
               :roc-12? (second roc12-r)
               :obv-slope-12? (second obv-r)

               ;; Multi-timeframe
               :tf-1h-close? (first mtf1h) :tf-1h-high? (second mtf1h)
               :tf-1h-low? (nth mtf1h 2) :tf-1h-ret? (nth mtf1h 3) :tf-1h-body? (nth mtf1h 4)
               :tf-4h-close? (first mtf4h) :tf-4h-high? (second mtf4h)
               :tf-4h-low? (nth mtf4h 2) :tf-4h-ret? (nth mtf4h 3) :tf-4h-body? (nth mtf4h 4)

               ;; Range position
               :range-pos-12? (second rp12-r)
               :range-pos-24? (second rp24-r)
               :range-pos-48? (second rp48-r)

               ;; Trend consistency
               :trend-consistency-6? (second tc6-r)
               :trend-consistency-12? (second tc12-r)
               :trend-consistency-24? (second tc24-r)

               ;; ATR ROC
               :atr-roc-6? (second atr-roc6-r)
               :atr-roc-12? (second atr-roc12-r)

               ;; Derived
               :vol-accel? vol-accel
               :bb-pos? bb-pos
               :kelt-upper? kelt-up :kelt-lower? kelt-lo
               :kelt-pos? kelt-pos
               :squeeze? squeeze)))

      (list updated-bank
            (computed-candle
              :ts (:ts candle) :open (:open candle)
              :high high :low low :close close :volume volume
              :hour hour :day-of-week day-of-week
              :sma20 sma20-v :sma50 (second sma50-r) :sma200 (second sma200-r)
              :bb-upper bb-up :bb-lower bb-lo :bb-width bb-w
              :rsi (second rsi-r)
              :macd-line (first (second macd-r))
              :macd-signal (second (second macd-r))
              :macd-hist (nth (second macd-r) 2)
              :dmi-plus (first (second dmi-r))
              :dmi-minus (second (second dmi-r))
              :adx (nth (second dmi-r) 2)
              :atr atr-v :atr-r atr-r-v
              :stoch-k (second stoch-r) :stoch-d (second stoch-d-r)
              :williams-r (second will-r)
              :cci (second cci-r) :mfi (second mfi-r)
              :volume-sma20 vol-sma
              :roc-1 (second roc1-r) :roc-3 (second roc3-r)
              :roc-6 (second roc6-r) :roc-12 (second roc12-r)
              :obv-slope-12 (second obv-r)
              :tf-1h-close (first mtf1h) :tf-1h-high (second mtf1h)
              :tf-1h-low (nth mtf1h 2) :tf-1h-ret (nth mtf1h 3) :tf-1h-body (nth mtf1h 4)
              :tf-4h-close (first mtf4h) :tf-4h-high (second mtf4h)
              :tf-4h-low (nth mtf4h 2) :tf-4h-ret (nth mtf4h 3) :tf-4h-body (nth mtf4h 4)
              :range-pos-12 (second rp12-r)
              :range-pos-24 (second rp24-r)
              :range-pos-48 (second rp48-r)
              :trend-consistency-6 (second tc6-r)
              :trend-consistency-12 (second tc12-r)
              :trend-consistency-24 (second tc24-r)
              :atr-roc-6 (second atr-roc6-r)
              :atr-roc-12 (second atr-roc12-r)
              :vol-accel vol-accel :bb-pos bb-pos
              :kelt-upper kelt-up :kelt-lower kelt-lo :kelt-pos kelt-pos
              :squeeze squeeze)))))

;; ── Spatial indicators (no fold state — computed from candle window) ──
;;
;; These are NOT in the bank. They're computed by vocab modules from
;; the raw candle window: Ichimoku, Fibonacci, PELT, divergence.
;; See thought.wat encode-thought dispatch.

;; ── Causality ──────────────────────────────────────────────────────
;;
;; The first law: every indicator at candle t uses only candles [0, t].
;; The fold enforces this: each step sees one candle, accumulates forward.
;; No indicator can see the future because no indicator receives future input.
;;
;; Labels (oracle) are separate — prophetic, not causal.
;; The test: removing all candles after t must produce the same value at t.

;; ── What we do NOT fold ────────────────────────────────────────────
;;
;; - PELT changepoints: window-dependent, computed per observer at their scale
;; - Ichimoku: tenkan/kijun/span computation depends on observation window
;; - Fibonacci: swing detection depends on the candle window
;; - Divergence: requires PELT structural peaks, window-dependent
;; - Hurst/DFA/entropy/fractal: computed from observation window, not per-candle
;;
;; These are spatial pattern recognizers, not scalar stream processors.
;; They read from the per-observer candle window, not the indicator bank.
