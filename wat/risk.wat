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
(atom "dd-depth")          ; (encode-linear depth 1.0)
(atom "dd-duration")       ; (encode-log candles-since-peak)
(atom "dd-velocity")       ; (encode-linear dd-change-rate 1.0)
(atom "dd-recovering")     ; boolean: equity rising from bottom
(atom "dd-deepening")      ; boolean: equity still falling

;; Accuracy specialist
;;   Vocabulary: rolling win rates at multiple scales
;;   Learns: what does "normal accuracy" look like?
;;   Anomaly: accuracy regime change
(atom "risk-accuracy")
(atom "acc-10")            ; 10-trade rolling accuracy
(atom "acc-50")            ; 50-trade rolling accuracy
(atom "acc-200")           ; 200-trade rolling accuracy
(atom "acc-trajectory")    ; (encode-linear (acc-10 - acc-50) 1.0) — improving or degrading?

;; Volatility specialist
;;   Vocabulary: trade return distribution shape
;;   Learns: what does "normal P&L variance" look like?
;;   Anomaly: P&L distribution changed (fat tails, skew shift)
(atom "risk-volatility")
(atom "trade-sharpe")      ; recent trade Sharpe ratio
(atom "worst-trade")       ; worst trade in last N
(atom "loss-density")      ; fraction of recent trades that lost

;; Correlation specialist
;;   Vocabulary: position concentration, expert agreement patterns
;;   Learns: what does "normal diversification" look like?
;;   Anomaly: all positions correlated (concentrated risk)
(atom "risk-correlation")
(atom "position-count")    ; how many open positions
(atom "position-coherence"); cosine similarity between open positions
(atom "directional-tilt")  ; net long/short exposure

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
;; (observe risk-alpha-journal
;;   (bundle
;;     (bind alpha-atom (encode-linear alpha 1.0))
;;     (bind action-count (encode-log recent-swaps))
;;     (bind portfolio-state treasury-snapshot))
;;   (if (> alpha 0) Buy Sell))
