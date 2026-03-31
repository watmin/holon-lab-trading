;; ── risk.wat — the risk branch ──────────────────────────────────────
;;
;; Template 2 (REACTION): OnlineSubspace learns the manifold of healthy
;; portfolio states. Residual = distance from healthy. Modulates sizing.
;; Sees everything. Filter is (always). This is policy.

(require core/primitives)
(require core/structural)
(require std/memory)
(require std/statistics)

;; ── Five specialists ────────────────────────────────────────────────
;;
;; Each is an OnlineSubspace. They measure ANOMALY not DIRECTION.
;; Gated updates: only learn from healthy states.

; rune:gaze(phantom) — drawdown is not in the wat language
; rune:gaze(phantom) — win-rate-last-n is not in the wat language
; rune:gaze(phantom) — recent-return-mean is not in the wat language
(define (healthy? portfolio)
  "Gates subspace updates. All four conditions must hold."
  (and (< (drawdown portfolio) 0.02)
       (> (win-rate-last-n portfolio 50) 0.55)
       (> (recent-return-mean portfolio 50) 0.0)
       (>= (:trades-taken portfolio) 20)))

;; ── Drawdown ────────────────────────────────────────────────────────

(define drawdown-branch (online-subspace dims 8))

; rune:gaze(phantom) — drawdown-velocity is not in the wat language
; rune:gaze(phantom) — recovery-progress is not in the wat language
; rune:gaze(phantom) — historical-worst-drawdown is not in the wat language
(define (encode-drawdown portfolio)
  (let ((dd      (drawdown portfolio))
        (dd-vel  (drawdown-velocity portfolio))
        (recover (recovery-progress portfolio))
        (dur     (/ (:trades-since-bottom portfolio) 100.0))
        (hist    (if (> (historical-worst-drawdown portfolio) 0.001)
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

; rune:gaze(phantom) — last-n-returns is not in the wat language
; rune:gaze(phantom) — length is not in the wat language
(define (encode-volatility portfolio)
  (let ((returns (last-n-returns portfolio 50)))
    (if (< (length returns) 5)
        (zero-vector dims)
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
            (bind (atom "equity-curve") (encode-linear (max returns) 0.1)))))))

;; ── Correlation ─────────────────────────────────────────────────────

(define correlation-branch (online-subspace dims 8))

; rune:gaze(phantom) — last-n-outcomes is not in the wat language
; rune:gaze(phantom) — autocorrelation is not in the wat language
; rune:gaze(phantom) — count-losses is not in the wat language
; rune:gaze(phantom) — consecutive-losses is not in the wat language
(define (encode-correlation portfolio)
  (let ((seq (last-n-outcomes portfolio 50)))
    (if (< (length seq) 20)
        (zero-vector dims)
        (let ((autocorr       (autocorrelation seq))
              (loss-frac      (/ (count-losses (last-n-outcomes portfolio 20)) 20.0))
              (consec         (consecutive-losses portfolio))
              (trade-density  (/ (:trades-taken portfolio) 1000.0)))
          (bundle
            (bind (atom "loss-pattern")  (encode-linear autocorr 2.0))
            (bind (atom "loss-density")  (encode-linear loss-frac 2.0))
            (bind (atom "consec-loss")   (encode-linear (/ consec 10.0) 2.0))
            (bind (atom "trade-density") (encode-linear trade-density 2.0))
            (bind (atom "streak")        (encode-linear (signum autocorr) 2.0)))))))

;; ── Panel ───────────────────────────────────────────────────────────

(define panel-branch (online-subspace dims 8))

; rune:gaze(phantom) — streak-value is not in the wat language
; rune:gaze(phantom) — win-rate is not in the wat language
(define (encode-panel portfolio)
  (let ((equity-pct (/ (- (:equity portfolio) (:initial-equity portfolio))
                       (:initial-equity portfolio)))
        (streak-val (streak-value portfolio))
        (wr-all     (win-rate portfolio))
        (density    (/ (:trades-taken portfolio) 1000.0))
        (frequency  (/ (sqrt (:trades-taken portfolio)) 30.0)))
    (bundle
      (bind (atom "equity-curve")    (encode-linear equity-pct 2.0))
      (bind (atom "streak")          (encode-linear (/ streak-val 10.0) 2.0))
      (bind (atom "recent-accuracy") (encode-linear wr-all 2.0))
      (bind (atom "trade-density")   (encode-linear density 2.0))
      (bind (atom "trade-frequency") (encode-linear frequency 2.0)))))

;; ── Risk multiplier ─────────────────────────────────────────────────

(define branches (list drawdown-branch accuracy-branch volatility-branch
                      correlation-branch panel-branch))

(define (risk-multiplier portfolio)
  "Update branches when healthy, then take the MIN per-branch ratio."
  (let* ((states (list (encode-drawdown portfolio) (encode-accuracy portfolio)
                       (encode-volatility portfolio) (encode-correlation portfolio)
                       (encode-panel portfolio)))
         (_      (when (healthy? portfolio)
                   (for-each update branches states)))
         ; rune:gaze(phantom) — fold-left is not in the wat language
         ; rune:gaze(phantom) — n is not in the wat language
         (worst-ratio
           (fold-left
             (lambda (acc branch features)
               (if (< (n branch) 10) acc
                 (let* ((residual  (residual branch features))
                        (threshold (threshold branch))
                        (ratio     (if (< residual threshold) 1.0
                                       (max 0.1 (/ threshold residual)))))
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
