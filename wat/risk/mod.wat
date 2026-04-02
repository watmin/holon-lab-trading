;; ── risk.wat — the risk branch ──────────────────────────────────────
;;
;; Template 2 (REACTION): OnlineSubspace learns the manifold of healthy
;; portfolio states. Residual = distance from healthy. Modulates sizing.
;; Sees everything. Filter is (always). This is policy.

(require core/primitives)
(require core/structural)
(require std/memory)
(require std/statistics)

;; ── Named constants ────────────────────────────────────────────────
(define VOLATILITY_WINDOW       50)     ; rolling window for volatility/correlation outcomes
(define CORRELATION_MIN_LEN     20)     ; minimum trades before correlation branch activates
(define LOSS_DENSITY_WINDOW     20)     ; window for recent loss fraction
(define DD_VELOCITY_LOOKBACK     5)     ; trades back for drawdown velocity
(define RECOVERY_THRESHOLD   0.005)     ; drawdown below this counts as recovered
(define HIST_WORST_THRESHOLD 0.001)     ; ignore historical worst below this
(define TRADES_SCALE         100.0)     ; normalise trades-since-bottom
(define STREAK_SCALE          10.0)     ; normalise consecutive-loss / streak length
(define DENSITY_SCALE       1000.0)     ; normalise lifetime trade count
(define FREQUENCY_SCALE       30.0)     ; normalise sqrt(trades) frequency term

;; ── Five specialists ────────────────────────────────────────────────
;;
;; Each is an OnlineSubspace. They measure ANOMALY not DIRECTION.
;; Gated updates: only learn from healthy states.

(define (drawdown portfolio)
  "Current drawdown: (peak - equity) / peak. 0 when at or above peak."
  (if (> (:peak-equity portfolio) 0.0)
      (/ (- (:peak-equity portfolio) (:equity portfolio))
         (:peak-equity portfolio))
      0.0))

(define (win-rate-last-n portfolio n)
  "Win rate over the last N trades from the rolling deque."
  (let ((recent (take-last n (:rolling portfolio))))
    (if (empty? recent) 0.5
        (/ (count true recent) (len recent)))))

(define (recent-return-mean portfolio n)
  "Mean return over the last N trades."
  (let ((returns (take-last n (:trade-returns portfolio))))
    (if (empty? returns) 0.0
        (/ (fold + 0.0 returns) (len returns)))))

(define (healthy? portfolio)
  "Gates subspace updates. All four conditions must hold."
  (and (< (drawdown portfolio) 0.02)
       (> (win-rate-last-n portfolio VOLATILITY_WINDOW) 0.55)
       (> (recent-return-mean portfolio VOLATILITY_WINDOW) 0.0)
       (>= (:trades-taken portfolio) 20)))

;; ── Drawdown ────────────────────────────────────────────────────────

(define drawdown-branch (online-subspace dims 8))

(define (drawdown-velocity portfolio)
  "Rate of drawdown change: current dd minus dd 5 trades ago."
  (let ((dd (drawdown portfolio))
        (eq5 (if (>= (len (:equity-at-trade portfolio)) DD_VELOCITY_LOOKBACK)
                 (nth (:equity-at-trade portfolio)
                       (- (len (:equity-at-trade portfolio)) DD_VELOCITY_LOOKBACK))
                 (:equity portfolio))))
    (- dd (if (> (:peak-equity portfolio) 0.0)
              (/ (- (:peak-equity portfolio) eq5) (:peak-equity portfolio))
              0.0))))

(define (recovery-progress portfolio)
  "How far equity has recovered from drawdown bottom toward peak. [0, 1].
   1.0 when at peak or drawdown < 0.5%."
  (let ((dd (drawdown portfolio)))
    (if (or (<= (:peak-equity portfolio) (:dd-bottom-equity portfolio))
            (< dd RECOVERY_THRESHOLD))
        1.0
        (clamp (/ (- (:equity portfolio) (:dd-bottom-equity portfolio))
                  (- (:peak-equity portfolio) (:dd-bottom-equity portfolio)))
               0.0 1.0))))

(define (historical-worst-drawdown portfolio)
  "Deepest completed drawdown from the rolling history."
  (fold max 0.0 (:completed-drawdowns portfolio)))

(define (encode-drawdown portfolio)
  (let ((dd      (drawdown portfolio))
        (dd-vel  (drawdown-velocity portfolio))
        (recover (recovery-progress portfolio))
        (dur     (/ (:trades-since-bottom portfolio) TRADES_SCALE))
        (hist    (if (> (historical-worst-drawdown portfolio) HIST_WORST_THRESHOLD)
                     (/ dd (historical-worst-drawdown portfolio))
                     0.0)))
    (bundle
      (bind (atom "drawdown")          (encode-linear dd 1.0))
      (bind (atom "drawdown-velocity") (encode-linear dd-vel 0.2))
      (bind (atom "recovery-progress") (encode-linear recover 2.0))
      (bind (atom "drawdown-duration") (encode-linear dur 2.0))
      (bind (atom "dd-historical") (encode-linear hist 2.0)))))

;; ── Accuracy ────────────────────────────────────────────────────────

(define accuracy-branch (online-subspace dims 8))

(define (encode-accuracy portfolio)
  ;; rune:temper(clarity) — three win-rate-last-n calls traverse rolling deque
  ;; separately. The Rust should fuse into one pass over take-last(200).
  ;; The wat keeps three calls because "accuracy at 10, 50, 200" reads clearly.
  (let ((wr10  (win-rate-last-n portfolio 10))
        (wr50  (win-rate-last-n portfolio 50))
        (wr200 (win-rate-last-n portfolio 200)))
    (bundle
      (bind (atom "accuracy-10")         (encode-linear wr10 2.0))
      (bind (atom "accuracy-50")         (encode-linear wr50 2.0))
      (bind (atom "accuracy-200")        (encode-linear wr200 2.0))
      (bind (atom "accuracy-trajectory") (encode-linear (- wr10 wr50) 0.5))
      (bind (atom "acc-divergence") (encode-linear (- wr10 wr200) 0.5)))))

;; ── Volatility ──────────────────────────────────────────────────────

(define volatility-branch (online-subspace dims 8))

(define (last-n-returns portfolio n)
  "Last N trade returns from the rolling deque."
  (take-last n (:trade-returns portfolio)))

(define (encode-volatility portfolio)
  (let ((returns (last-n-returns portfolio VOLATILITY_WINDOW)))
    (if (< (length returns) 5)
        (zeros dims)
        (let ((vol    (stddev returns))
              (mean   (mean returns))
              (sharpe (if (> vol 0.0) (/ mean vol) 0.0))
              (worst  (min returns))
              (skew   (skewness returns)))
          (bundle
            (bind (atom "pnl-vol")      (encode-linear vol 0.1))
            (bind (atom "trade-sharpe") (encode-linear sharpe 4.0))
            (bind (atom "worst-trade")  (encode-linear worst 0.1))
            (bind (atom "return-skew")  (encode-linear skew 4.0))
            (bind (atom "vol-best-trade") (encode-linear (max returns) 0.1)))))))

;; ── Correlation ─────────────────────────────────────────────────────

(define correlation-branch (online-subspace dims 8))

(define (last-n-outcomes portfolio n)
  "Last N trade outcomes as +1.0 (win) / -1.0 (loss) from the rolling deque."
  (map (lambda (won) (if won 1.0 -1.0))
       (take-last n (:rolling portfolio))))

(define (autocorrelation seq)
  "Lag-1 autocorrelation of a numeric sequence.
   cov(x_t, x_{t+1}) / var(x). Returns 0 if variance < 1e-10."
  (let* ((mean (/ (fold + 0.0 seq) (len seq)))
         (var  (/ (fold + 0.0 (map (lambda (x) (* (- x mean) (- x mean))) seq))
                  (len seq))))
    (if (< var 1e-10) 0.0
        (/ (fold + 0.0
             (map (lambda (i) (* (- (nth seq i) mean) (- (nth seq (+ i 1)) mean)))
                  (range 0 (- (len seq) 1))))
           (* (- (len seq) 1) var)))))

(define (count-losses outcomes)
  "Count -1.0 entries in an outcome sequence."
  (count (lambda (x) (< x 0.0)) outcomes))

(define (consecutive-losses portfolio)
  "Length of the current losing streak from the end of the rolling deque."
  (let loop ((seq (reverse (:rolling portfolio))) (n 0))
    (if (or (empty? seq) (first seq)) n
        (loop (rest seq) (+ n 1)))))

(define (encode-correlation portfolio)
  (let ((seq (last-n-outcomes portfolio VOLATILITY_WINDOW)))
    (if (< (length seq) CORRELATION_MIN_LEN)
        (zeros dims)
        (let ((autocorr       (autocorrelation seq))
              (loss-frac      (/ (count-losses (last-n-outcomes portfolio LOSS_DENSITY_WINDOW)) (exact->inexact LOSS_DENSITY_WINDOW)))
              (consec         (consecutive-losses portfolio))
              (trade-density  (/ (:trades-taken portfolio) DENSITY_SCALE)))
          (bundle
            (bind (atom "loss-pattern")  (encode-linear autocorr 2.0))
            (bind (atom "loss-density")  (encode-linear loss-frac 2.0))
            (bind (atom "consec-loss")   (encode-linear (/ consec STREAK_SCALE) 2.0))
            (bind (atom "corr-trade-density") (encode-linear trade-density 2.0))
            (bind (atom "corr-autocorr-sign") (encode-linear (signum autocorr) 2.0)))))))

;; ── Panel ───────────────────────────────────────────────────────────

(define panel-branch (online-subspace dims 8))

(define (streak-value portfolio)
  "Signed streak length: +N for consecutive wins, -N for consecutive losses."
  (if (empty? (:rolling portfolio)) 0.0
      (let ((last-outcome (last (:rolling portfolio))))
        (let loop ((seq (reverse (:rolling portfolio))) (n 0.0))
          (if (or (empty? seq) (not (= (first seq) last-outcome))) n
              (loop (rest seq) (+ n (if last-outcome 1.0 -1.0))))))))

(define (win-rate portfolio)
  "Lifetime win rate as a fraction [0, 1]."
  (if (= (:trades-taken portfolio) 0) 0.5
      (/ (:trades-won portfolio) (:trades-taken portfolio))))

(define (encode-panel portfolio)
  (let ((equity-pct (/ (- (:equity portfolio) (:initial-equity portfolio))
                       (:initial-equity portfolio)))
        (streak-val (streak-value portfolio))
        (wr-all     (win-rate portfolio))
        (density    (/ (:trades-taken portfolio) DENSITY_SCALE))
        (frequency  (/ (sqrt (:trades-taken portfolio)) FREQUENCY_SCALE)))
    (bundle
      (bind (atom "panel-equity-pct")    (encode-linear equity-pct 2.0))
      (bind (atom "panel-streak")        (encode-linear (/ streak-val STREAK_SCALE) 2.0))
      (bind (atom "recent-accuracy")     (encode-linear wr-all 2.0))
      (bind (atom "panel-trade-density") (encode-linear density 2.0))
      (bind (atom "trade-frequency") (encode-linear frequency 2.0)))))

;; ── Risk multiplier ─────────────────────────────────────────────────

(define branches (list drawdown-branch accuracy-branch volatility-branch
                      correlation-branch panel-branch))

(define (risk-multiplier portfolio)
  "Update branches when healthy, compute MIN ratio. Single pass over branches."
  (let* ((states (list (encode-drawdown portfolio) (encode-accuracy portfolio)
                       (encode-volatility portfolio) (encode-correlation portfolio)
                       (encode-panel portfolio)))
         (is-healthy (healthy? portfolio))
         ;; Single pass: update (if healthy) then score each branch
         (worst-ratio
           (fold-left
             (lambda (acc branch features)
               ;; Update branch when healthy
               (when is-healthy (update branch features))
               ;; Score: branches with < 10 observations are untrained — skip
               (if (< (n branch) 10) acc
                 (let* ((res (residual branch features))
                        (thr (threshold branch))
                        (ratio (if (< res thr) 1.0
                                   (max 0.1 (/ thr res)))))
                   (min acc ratio))))
             1.0
             branches states)))
    worst-ratio))

;; ── Aspirational ────────────────────────────────────────────────────
;;
;; rune:scry(aspirational) — risk MANAGER with Journal discriminant,
;; Healthy/Unhealthy labels, conviction-based rejection.
;;
;; rune:scry(aspirational) — risk GENERALIST seeing all dimensions.
;;
;; rune:scry(aspirational) — risk-alpha-journal with Profitable/Unprofitable
;; labels. Requires treasury alpha tracking.

;; ── What risk does NOT do ───────────────────────────────────────────
;; - Does NOT predict market direction (that's the market branch)
;; - Does NOT decide sizing amount (that's the Kelly formula)
;; - Does NOT execute swaps (that's the treasury)
;; - It MODULATES. It GATES. It does not DECIDE.
