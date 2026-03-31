;; -- portfolio.wat -- equity, phases, and risk vocabulary encoding --
;;
;; Tracks equity, win/loss history, drawdown, and phase transitions.
;; Encodes risk state as five named-atom branches for OnlineSubspace.
;; Does NOT predict. Does NOT decide entry/exit. Does NOT hold positions.

(require core/primitives)
(require core/structural)
(require risk)

;; -- Phase lifecycle --------------------------------------------------------

;; phase: :observe | :tentative | :confident
;;
;; :observe    -> :tentative   when observe_left reaches 0
;; :tentative  -> :confident   when rolling.len >= 500 AND rolling_acc > 0.52
;; :confident  -> :tentative   when rolling.len >= 200 AND rolling_acc < 0.50
;; :observe    -> never re-entered

;; -- State ------------------------------------------------------------------

(struct portfolio
  equity
  initial-equity
  peak-equity
  phase                  ; :observe | :tentative | :confident
  observe-left           ; candles remaining in observe phase
  trades-taken
  trades-won
  trades-skipped
  rolling                ; (deque bool) — recent trade outcomes, cap 500
  rolling-cap            ; 500
  by-year                ; (map year year-stats) — rune:reap(unused-struct)

  ;; Risk vocabulary infrastructure
  equity-at-trade        ; (deque f64) — equity after each trade, cap 500
  trade-returns          ; (deque f64) — directional return per trade, cap 500
  dd-bottom-equity       ; deepest point of current drawdown
  trades-since-bottom    ; trades since drawdown bottom
  completed-drawdowns)   ; (deque f64) — max depth of each completed dd, cap 20

;; rune:reap(unused-struct) — by_year populated every trade but never read
(struct year-stats
  trades wins pnl)

;; -- Construction -----------------------------------------------------------

(define (new-portfolio initial-equity observe-period)
  (portfolio
    :equity initial-equity
    :initial-equity initial-equity
    :peak-equity initial-equity
    :phase :observe
    :observe-left observe-period
    :trades-taken 0 :trades-won 0 :trades-skipped 0
    :rolling (deque) :rolling-cap 500
    :by-year {}
    :equity-at-trade (deque) :trade-returns (deque)
    :dd-bottom-equity initial-equity
    :trades-since-bottom 0
    :completed-drawdowns (deque)))

;; -- Queries ----------------------------------------------------------------

(define (rolling-acc portfolio)
  "Fraction of recent trades that won."
  (if (empty? (:rolling portfolio)) 0.5
      (/ (count true (:rolling portfolio))
         (len (:rolling portfolio)))))

(define (win-rate portfolio)
  "Lifetime win rate as percentage."
  (if (= (:trades-taken portfolio) 0) 0.0
      (* (/ (:trades-won portfolio) (:trades-taken portfolio)) 100.0)))

(define (win-rate-last-n portfolio n)
  "Win rate over the last N trades."
  (let ((recent (take-last n (:rolling portfolio))))
    (if (empty? recent) 0.5
        (/ (count true recent) (len recent)))))

; rune:gaze(phantom) — drawdown is not in the wat language
; rune:gaze(phantom) — mean is not in the wat language

(define (is-healthy? portfolio)
  "Gates subspace updates. All three must hold."
  (and (< (drawdown portfolio) 0.02)
       (> (win-rate-last-n portfolio 50) 0.55)
       (> (mean (take-last 50 (:trade-returns portfolio))) 0.0)))

;; -- Position sizing --------------------------------------------------------

;; rune:forge(bare-type) -- graduated thresholds (0.005, 0.01, 0.02, 0.05)
;; are magic f64 constants baked into code rather than derived from data
(define (position-frac portfolio conviction min-conviction flip-threshold)
  "Returns position fraction or nothing."
  (if (= (:phase portfolio) :observe) nothing
  (if (< conviction min-conviction) nothing
  (let ((base (match (:phase portfolio)
                :tentative 0.005
                :confident (let ((conf (max 0.0 (- (rolling-acc portfolio) 0.5))))
                             (cond ((< conf 0.05) 0.005)
                                   ((< conf 0.10) 0.01)
                                   (else (min 0.02 (* conf 0.10))))))))
    ;; Below flip threshold: no trade (noise zone)
    (if (and (> flip-threshold 0.0) (< conviction flip-threshold))
        nothing
        ;; Scale by conviction ratio, cap at 5%
        (if (> flip-threshold 0.0)
            (min 0.05 (* base (/ conviction flip-threshold)))
            base))))))

;; -- Trade recording --------------------------------------------------------

;; rune:forge(escape) -- mutates 15+ fields. Accounting, drawdown tracking,
;; and phase transitions are three concerns in one method.
(define (record-trade portfolio outcome-pct frac direction year swap-fee slippage)
  "Record a completed trade. Updates equity, drawdown, rolling, phase."
  (let ((directional-return (match direction :long outcome-pct :short (- outcome-pct)))
        (per-swap-cost (+ swap-fee slippage))
        (after-entry (- 1.0 per-swap-cost))
        (gross-value (* after-entry (+ 1.0 directional-return)))
        (after-exit (* gross-value (- 1.0 per-swap-cost)))
        (net-return (- after-exit 1.0))
        (position-value (* (:equity portfolio) frac))
        (pnl (* position-value net-return))
        (won (> net-return 0.0)))
    ;; Mutates: equity, peak-equity (with 0.999 decay), dd-bottom,
    ;; trades-since-bottom, completed-drawdowns, equity-at-trade,
    ;; trade-returns, trades-taken/won, rolling, by-year, phase
    ))

;; -- Drawdown tracking ------------------------------------------------------
;;
;; Peak equity decays: peak = peak * 0.999 + equity * 0.001
;; After ~700 trades below peak, the cap has halved the gap.
;; When equity exceeds peak, the previous drawdown (if > 0.1%) is recorded
;; in completed-drawdowns (cap 20).

;; -- Phase transitions ------------------------------------------------------

(define (tick-observe portfolio)
  "Decrement observe counter. Transition to :tentative when done."
  (if (and (= (:phase portfolio) :observe) (> (:observe-left portfolio) 0))
      (let ((left (- (:observe-left portfolio) 1)))
        (if (= left 0)
            (update portfolio :phase :tentative :observe-left 0)
            (update portfolio :observe-left left)))))

(define (check-phase portfolio)
  "Promote or demote based on rolling accuracy."
  (match (:phase portfolio)
    :tentative (if (and (>= (len (:rolling portfolio)) 500)
                        (> (rolling-acc portfolio) 0.52))
                   (update portfolio :phase :confident))
    :confident (if (and (>= (len (:rolling portfolio)) 200)
                        (< (rolling-acc portfolio) 0.50))
                   (update portfolio :phase :tentative))
    :observe portfolio))

;; -- Risk branch encoding ---------------------------------------------------

;; rune:sever(wrong-struct) -- risk encoding lives on Portfolio but belongs
;; in risk/ module. Portfolio is state, not an encoder.
;; rune:forge(coupling) -- takes &VectorManager and &ScalarEncoder; this is
;; encoding logic wearing a Portfolio method's clothes.

;; Returns [dd-branch acc-branch vol-branch corr-branch panel-branch]
;; Each branch is a bundled vector of named atoms bound with scalar magnitudes.
;; See risk.wat for the full vocabulary of all five branches.
(define (risk-branch-wat portfolio vm scalar)
  "Five risk WAT vectors. Named atoms bound with scalar magnitudes."
  (let ((thought (lambda (name value scale)
                   (bind (atom name) (encode-linear value scale)))))

    ;; drawdown branch: dd, dd-velocity, recovery, duration, historical
    ;; accuracy branch: wr-10, wr-50, wr-200, trajectory, divergence
    ;; volatility branch: pnl-vol, sharpe, worst-trade, skew, equity-curve
    ;; correlation branch: loss-pattern, loss-density, consec-loss, trade-density, streak
    ;; panel branch: equity-curve, streak, recent-accuracy, trade-density, trade-frequency
    (map bundle [dd-branch acc-branch vol-branch corr-branch panel-branch])))

;; -- What portfolio does NOT do ---------------------------------------------
;; - Does NOT predict direction (that's the observers + manager)
;; - Does NOT hold positions (that's managed-position)
;; - Does NOT execute trades (that's the treasury)
;; - Does NOT own the risk branches (that's risk/mod.rs)
;; - It counts. It phases. It encodes risk state for others to consume.
