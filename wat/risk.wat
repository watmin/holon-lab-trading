;; ── risk.wat — the risk branch ──────────────────────────────────────
;;
;; The risk branch mirrors the market branch: fractal structure.
;; Risk specialists + risk generalist + risk manager.
;;
;; The risk branch subscribes to ALL channels with NO filter.
;; It needs the full picture: proven and unproven, traded and hypothetical.
;; Risk can't learn what "unhealthy" looks like if it only sees healthy states.
;;
;; Template 2 (REACTION): OnlineSubspace learns the manifold of healthy
;; portfolio states. Residual = distance from healthy. The risk manager
;; uses this to modulate sizing and reject bad trades.

;; ── Subscriptions (from channels.wat) ───────────────────────────────
;;
;; (subscribe "risk" → "momentum"   :filter (always))
;; (subscribe "risk" → "structure"  :filter (always))
;; (subscribe "risk" → "volume"     :filter (always))
;; (subscribe "risk" → "narrative"  :filter (always))
;; (subscribe "risk" → "regime"     :filter (always))
;; (subscribe "risk" → "generalist" :filter (always))
;; (subscribe "risk" → "treasury"   :filter (always))
;; (subscribe "risk" → "positions"  :filter (always))
;;
;; Risk sees everything. The filter is (always). This is policy.

;; ── Risk specialists ────────────────────────────────────────────────
;;
;; Same pattern as market experts: each has a vocabulary, a journal,
;; and a gate. But they use Template 2 (OnlineSubspace) not Template 1
;; (Journal). They measure ANOMALY not DIRECTION.

;; Drawdown specialist
;;   Vocabulary: equity curve shape, drawdown depth/duration/velocity
;;   Learns: what does "normal drawdown recovery" look like?
;;   Anomaly: drawdown that doesn't match the recovery pattern
(atom "risk-drawdown")
(atom "drawdown-depth")    ; (encode-linear depth 1.0)
(atom "drawdown-duration") ; (encode-log candles-since-peak)
(atom "drawdown-velocity") ; (encode-linear dd-change-rate 1.0)
(atom "drawdown-recovering") ; boolean: equity rising from bottom
(atom "drawdown-deepening")  ; boolean: equity still falling

;; Accuracy specialist
;;   Vocabulary: rolling win rates at multiple scales
;;   Learns: what does "normal accuracy" look like?
;;   Anomaly: accuracy regime change
(atom "risk-accuracy")
(atom "accuracy-10")       ; 10-trade rolling accuracy
(atom "accuracy-50")       ; 50-trade rolling accuracy
(atom "accuracy-200")      ; 200-trade rolling accuracy
(atom "accuracy-trajectory") ; (encode-linear (accuracy-10 - accuracy-50) 1.0) — improving or degrading?

;; Volatility specialist
;;   Vocabulary: trade return distribution shape
;;   Learns: what does "normal P&L variance" look like?
;;   Anomaly: P&L distribution changed (fat tails, skew shift)
(atom "risk-volatility")
(atom "trade-sharpe")      ; recent trade Sharpe ratio
(atom "worst-trade")       ; worst trade in last N

;; Correlation specialist
;;   Vocabulary: trade outcome patterns, loss clustering
;;   Learns: what does "normal loss distribution" look like?
;;   Anomaly: losses clustering (serial correlation in outcomes)
(atom "risk-correlation")
(atom "loss-pattern")      ; autocorrelation of win/loss sequence
(atom "loss-density")      ; fraction of recent trades that lost
(atom "consec-loss")       ; consecutive losing streak length
(atom "trade-density")     ; trade frequency (trades per 1000 candles)
(atom "streak")            ; direction of outcome clustering

;; Panel specialist
;;   Vocabulary: equity curve, streak, recent accuracy, trade density
;;   Learns: what does "normal panel output" look like?
;;   Anomaly: panel behavior deviating from healthy patterns
(atom "risk-panel")
(atom "equity-curve")      ; return since inception
(atom "recent-accuracy")   ; overall win rate
(atom "trade-frequency")   ; sqrt(trades) / 30

;; ── Risk generalist (#14) ───────────────────────────────────────────
;;
;; Sees ALL risk dimensions simultaneously. Same as market generalist.
;; Bundle(drawdown-state, accuracy-state, volatility-state, correlation-state)
;; Uses OnlineSubspace: learns "what healthy looks like" from all dimensions.

;; ── Risk manager ────────────────────────────────────────────────────
;;
;; Reads risk specialist opinions. Same Holon encoding as market manager.
;; bind(risk-specialist-atom, residual-magnitude) per specialist.
;; The risk manager's discriminant learns which risk configurations
;; precede capital loss.
;;
;; Label: did the portfolio LOSE VALUE in the next N candles?
;;   Buy = portfolio healthy (no loss)
;;   Sell = portfolio unhealthy (lost value)
;;
;; The risk manager's prediction modulates position sizing:
;;   High conviction "healthy" → full size
;;   High conviction "unhealthy" → reduce or reject
;;   Low conviction → default size (don't know = be cautious)

;; ── Risk rejection ──────────────────────────────────────────────────
;;
;; The risk manager can REJECT a proposed trade:
;;   (if (risk-predicts unhealthy high-conviction)
;;       (reject proposed-trade)
;;       (allow proposed-trade :size (modulate size risk-conviction)))
;;
;; Rejection is the risk manager's filter on the treasury subscription.
;; The treasury subscribes to manager decisions WITH the risk filter:
;;   (subscribe "treasury" → "manager"
;;     :filter (and (band-valid?)
;;                  (conviction-in-band?)
;;                  (risk-allows?)))

;; ── Alpha as risk feedback ──────────────────────────────────────────
;;
;; The risk manager learns from alpha: did the last action beat inaction?
;; Alpha < 0 for N consecutive actions → risk tightens.
;; Alpha > 0 → risk loosens.
;; This is the counterfactual comparison — the ultimate risk measure.
;;
;; (define profitable   (register risk-alpha-journal "Profitable"))
;; (define unprofitable (register risk-alpha-journal "Unprofitable"))
;;
;; (observe risk-alpha-journal
;;   (bundle
;;     (bind alpha-atom (encode-linear alpha 1.0))
;;     (bind action-count (encode-log recent-swaps))
;;     (bind portfolio-state treasury-snapshot))
;;   (if (> alpha 0) profitable unprofitable))
