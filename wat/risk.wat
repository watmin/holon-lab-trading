;; ── risk.wat — the risk branch ──────────────────────────────────────
;;
;; Template 2 (REACTION): OnlineSubspace learns the manifold of healthy
;; portfolio states. Residual = distance from healthy. Modulates sizing.
;; Sees everything. Filter is (always). This is policy.

(require core/primitives)
(require core/structural)
(require std/common)
(require std/patterns)

;; ── Risk branches ───────────────────────────────────────────────────
;;
;; Five specialists, each an OnlineSubspace. They measure ANOMALY not
;; DIRECTION. Gated updates: only learn from healthy states.
;;
;; (define healthy? (and (< (drawdown portfolio) max-healthy-drawdown)
;;                       (> (rolling-accuracy portfolio) min-healthy-accuracy)))

;; ── Drawdown specialist ─────────────────────────────────────────────
;;
;; (define drawdown-branch (online-subspace dims 8))
;;
;; (bundle
;;   (bind (atom "drawdown")          (encode-linear dd 1.0))
;;   (bind (atom "drawdown-velocity") (encode-linear dd-vel 0.2))
;;   (bind (atom "recovery-progress") (encode-linear recovery 2.0))
;;   (bind (atom "drawdown-duration") (encode-linear (/ trades-since-bottom 100) 2.0))
;;   (bind (atom "dd-historical")     (encode-linear (/ dd hist-worst) 2.0)))

;; ── Accuracy specialist ─────────────────────────────────────────────
;;
;; (define accuracy-branch (online-subspace dims 8))
;;
;; (bundle
;;   (bind (atom "accuracy-10")          (encode-linear wr10 2.0))
;;   (bind (atom "accuracy-50")          (encode-linear wr50 2.0))
;;   (bind (atom "accuracy-200")         (encode-linear wr200 2.0))
;;   (bind (atom "accuracy-trajectory")  (encode-linear (- wr10 wr50) 0.5))
;;   (bind (atom "acc-divergence")       (encode-linear (- wr10 wr200) 0.5)))

;; ── Volatility specialist ───────────────────────────────────────────
;;
;; (define volatility-branch (online-subspace dims 8))
;;
;; (bundle
;;   (bind (atom "pnl-vol")      (encode-linear vol 0.1))
;;   (bind (atom "trade-sharpe") (encode-linear sharpe 4.0))
;;   (bind (atom "worst-trade")  (encode-linear worst 0.1))
;;   (bind (atom "return-skew")  (encode-linear skew 4.0))
;;   (bind (atom "equity-curve") (encode-linear best 0.1)))

;; ── Correlation specialist ──────────────────────────────────────────
;;
;; (define correlation-branch (online-subspace dims 8))
;;
;; (bundle
;;   (bind (atom "loss-pattern")  (encode-linear autocorr 2.0))
;;   (bind (atom "loss-density")  (encode-linear loss-frac 2.0))
;;   (bind (atom "consec-loss")   (encode-linear (/ streak 10) 2.0))
;;   (bind (atom "trade-density") (encode-linear (/ trades-taken 1000) 2.0))
;;   (bind (atom "streak")        (encode-linear (signum autocorr) 2.0)))

;; ── Panel specialist ────────────────────────────────────────────────
;;
;; (define panel-branch (online-subspace dims 8))
;;
;; (bundle
;;   (bind (atom "equity-curve")    (encode-linear equity-pct 2.0))
;;   (bind (atom "streak")          (encode-linear (/ streak-val 10) 2.0))
;;   (bind (atom "recent-accuracy") (encode-linear wr-all 2.0))
;;   (bind (atom "trade-density")   (encode-linear (/ trades-taken 1000) 2.0))
;;   (bind (atom "trade-frequency") (encode-linear (/ (sqrt trades-taken) 30) 2.0)))

;; ── Risk multiplier ─────────────────────────────────────────────────
;;
;; Each branch: update subspace when healthy, then measure residual.
;;
;; (define (risk-multiplier branches states)
;;   (let* ((residuals  (map residual branches states))
;;          (thresholds (map threshold branches))
;;          (worst      (apply max residuals))
;;          (max-thresh (apply max thresholds)))
;;     (if (> worst max-thresh)
;;         (/ max-thresh worst)     ; scale down proportionally
;;         1.0)))                   ; all clear

;; ── Aspirational ────────────────────────────────────────────────────
;;
;; rune:scry(aspirational) — risk MANAGER with Journal-based discriminant,
;; Healthy/Unhealthy labels, conviction-based trade rejection. Current
;; implementation has only bare OnlineSubspace branches with threshold gating.
;;
;; rune:scry(aspirational) — risk GENERALIST that sees ALL risk dimensions
;; simultaneously via OnlineSubspace. Not yet implemented.
;;
;; rune:scry(aspirational) — risk-alpha-journal with Profitable/Unprofitable
;; labels that learns from alpha (did the last action beat inaction?).
;; Requires treasury alpha tracking.

;; ── What risk does NOT do ───────────────────────────────────────────
;; - Does NOT predict market direction (that's the market branch)
;; - Does NOT decide sizing amount (that's the Kelly formula)
;; - Does NOT execute swaps (that's the treasury)
;; - It MODULATES. It GATES. It does not DECIDE.
