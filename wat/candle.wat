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

(require core/structural)

;; ── Raw input ──────────────────────────────────────────────────────

(struct raw-candle ts open high low close volume)

;; ── Primitive state machines ───────────────────────────────────────

;; SMA: sliding window average. O(period) memory.
(struct sma-state buffer period)

(define (new-sma period)
  (sma-state :buffer (deque) :period period))

(define (sma-step state value)
  "Feed one value. Returns (new-state, sma-value)."
  (let ((buf (push-back (:buffer state) value)))
    (let ((buf (if (> (len buf) (:period state)) (pop-front buf) buf)))
      (list (update state :buffer buf)
            (/ (fold + 0.0 buf) (len buf))))))

;; EMA: exponential moving average. O(1) memory.
(struct ema-state alpha prev started)

(define (new-ema period)
  (ema-state :alpha (/ 2.0 (+ period 1)) :prev 0.0 :started false))

(define (ema-step state value)
  "Feed one value. Returns (new-state, ema-value)."
  (if (not (:started state))
      (list (update state :started true :prev value) value)
      (let ((new (+ (* (:alpha state) value)
                     (* (- 1.0 (:alpha state)) (:prev state)))))
        (list (update state :prev new) new))))

;; Wilder: smoothed average. O(1) after warmup.
;; First `period` values averaged, then smooth_t = (prev*(p-1) + value) / p.
(struct wilder-state count accum prev period)

(define (new-wilder period)
  (wilder-state :count 0 :accum 0.0 :prev 0.0 :period period))

(define (wilder-step state value)
  "Feed one value. Returns (new-state, smoothed-value)."
  (let ((count (+ (:count state) 1))
        (period (:period state)))
    (if (<= count period)
        (let ((accum (+ (:accum state) value))
              (avg   (/ accum count)))
          (list (update state :count count :accum accum
                  :prev (if (= count period) avg (:prev state)))
                avg))
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

(define (atr-step state high low close)
  "Feed H, L, C. Returns (new-state, atr-value)."
  (if (not (:started state))
      (let ((result (wilder-step (:wilder state) (- high low))))
        (list (update state :wilder (first result) :started true :prev-close close)
              (second result)))
      (let ((tr (max (- high low)
                     (abs (- high (:prev-close state)))
                     (abs (- low (:prev-close state))))))
        (let ((result (wilder-step (:wilder state) tr)))
          (list (update state :wilder (first result) :prev-close close)
                (second result))))))

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
(struct dmi-state plus-wilder minus-wilder atr-wilder adx-wilder prev-high prev-low prev-close started)

(define (new-dmi period)
  (dmi-state :plus-wilder (new-wilder period) :minus-wilder (new-wilder period)
             :atr-wilder (new-wilder period) :adx-wilder (new-wilder period)
             :prev-high 0.0 :prev-low 0.0 :prev-close 0.0 :started false))

(define (dmi-step state high low close)
  "Feed H, L, C. Returns (new-state, (dmi-plus, dmi-minus, adx))."
  (if (not (:started state))
      (list (update state :started true :prev-high high :prev-low low :prev-close close)
            (list 0.0 0.0 0.0))
      (let* ((up-move   (- high (:prev-high state)))
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
             (adx-result (wilder-step (:adx-wilder state) dx)))
        (list (update state
                :plus-wilder (first p-result) :minus-wilder (first m-result)
                :atr-wilder (first a-result) :adx-wilder (first adx-result)
                :prev-high high :prev-low low :prev-close close)
              (list dmi-plus dmi-minus (second adx-result))))))

;; Stochastic %K: sliding window min/max. O(period).
(struct stoch-state high-buf low-buf period)

(define (new-stoch period)
  (stoch-state :high-buf (deque) :low-buf (deque) :period period))

(define (stoch-step state high low close)
  "Feed H, L, C. Returns (new-state, stoch-k)."
  (let ((hbuf (push-back (:high-buf state) high))
        (lbuf (push-back (:low-buf state) low)))
    (let ((hbuf (if (> (len hbuf) (:period state)) (pop-front hbuf) hbuf))
          (lbuf (if (> (len lbuf) (:period state)) (pop-front lbuf) lbuf))
          (hi   (fold max (first hbuf) (rest hbuf)))
          (lo   (fold min (first lbuf) (rest lbuf))))
      (list (update state :high-buf hbuf :low-buf lbuf)
            (* (/ (- close lo) (max (- hi lo) 1e-10)) 100.0)))))

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
  williams-buf                 ; reuses stoch window
  volume-sma20

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
  cci?                         ; computed from raw candle, not a fold
  mfi?
  volume-sma20-val?

  ;; Previous values for cross-detection
  rsi-prev? stoch-k-prev? stoch-d-prev?
  macd-line-prev? macd-signal-prev?
  sma50-prev? sma200-prev?

  ;; Pre-computed from raw (no fold state needed)
  close prev-close?)

;; ── tick-indicators ────────────────────────────────────────────────
;;
;; The fold step. Advances all indicators with one candle.
;; Pure: bank in, bank out. No mutation. No side effects.

(define (tick-indicators bank candle)
  "Step all indicators with one candle. Returns new bank."
  (let* ((close  (:close candle))
         (high   (:high candle))
         (low    (:low candle))
         (volume (:volume candle))
         ;; Step each state machine
         (sma20-r  (sma-step (:sma20 bank) close))
         (sma50-r  (sma-step (:sma50 bank) close))
         (sma200-r (sma-step (:sma200 bank) close))
         (bb-r     (stddev-step (:bb-stddev bank) close))
         (ema20-r  (ema-step (:ema20 bank) close))
         (rsi-r    (rsi-step (:rsi bank) close))
         (macd-r   (macd-step (:macd bank) close))
         (dmi-r    (dmi-step (:dmi bank) high low close))
         (atr-r    (atr-step (:atr bank) high low close))
         (stoch-r  (stoch-step (:stoch bank) high low close))
         (stoch-d-r (sma-step (:stoch-d-sma bank) (second stoch-r)))
         (vol-r    (sma-step (:volume-sma20 bank) volume))
         ;; Extract values
         (sma20-v  (second sma20-r))
         (bb-std   (second bb-r))
         (bb-up    (+ sma20-v (* 2.0 bb-std)))
         (bb-lo    (- sma20-v (* 2.0 bb-std)))
         (ema20-v  (second ema20-r))
         (atr-v    (second atr-r))
         (kelt-up  (+ ema20-v (* 1.5 atr-v)))
         (kelt-lo  (- ema20-v (* 1.5 atr-v))))
    (update bank
      ;; Updated states
      :sma20 (first sma20-r) :sma50 (first sma50-r) :sma200 (first sma200-r)
      :bb-stddev (first bb-r) :ema20 (first ema20-r)
      :rsi (first rsi-r) :macd (first macd-r)
      :dmi (first dmi-r) :atr (first atr-r)
      :stoch (first stoch-r) :stoch-d-sma (first stoch-d-r)
      :volume-sma20 (first vol-r)
      ;; Shift current → prev
      :rsi-prev? (:rsi-val? bank)
      :stoch-k-prev? (:stoch-k? bank)
      :stoch-d-prev? (:stoch-d? bank)
      :macd-line-prev? (:macd-line? bank)
      :macd-signal-prev? (:macd-signal? bank)
      :sma50-prev? (:sma50-val? bank)
      :sma200-prev? (:sma200-val? bank)
      :prev-close? (:close bank)
      ;; New current values
      :close close
      :sma20-val? sma20-v
      :sma50-val? (second sma50-r)
      :sma200-val? (second sma200-r)
      :bb-upper? bb-up :bb-lower? bb-lo
      :bb-width? (if (> sma20-v 1e-10) (/ (- bb-up bb-lo) sma20-v) 0.0)
      :rsi-val? (second rsi-r)
      :macd-line? (first (second macd-r))
      :macd-signal? (second (second macd-r))
      :macd-hist? (nth (second macd-r) 2)
      :dmi-plus? (first (second dmi-r))
      :dmi-minus? (second (second dmi-r))
      :adx? (nth (second dmi-r) 2)
      :atr-val? atr-v
      :atr-r? (if (> close 1e-10) (/ atr-v close) 0.0)
      :stoch-k? (second stoch-r)
      :stoch-d? (second stoch-d-r)
      :volume-sma20-val? (second vol-r))))

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
