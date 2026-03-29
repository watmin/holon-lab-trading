# Risk Vocabulary Design — 204 atoms, 54 facts/candle

## Categories:
1. Drawdown Dynamics (25 atoms, ~6 facts) — velocity, duration, historical context
2. Position/Exposure (15 atoms, ~3 facts) — trade density, recency, size
3. Win Rate Dynamics (24 atoms, ~5 facts) — multi-scale accuracy, trajectory, divergence
4. Return Volatility (22 atoms, ~6 facts) — Sharpe, skew, kurtosis, worst-trade
5. Expert Panel Dynamics (32 atoms, ~8 facts) — agreement, shift detection, conviction spread
6. Regime Awareness (18 atoms, ~5 facts) — historical accuracy by regime
7. Recovery Dynamics (14 atoms, ~4 facts) — progress, pace, quality
8. Calendar/Session Risk (14 atoms, ~5 facts) — session/dow accuracy, weekend proximity
9. Loss Correlation (14 atoms, ~4 facts) — clustering, run distribution, density
10. Curve/Edge Health (26 atoms, ~8 facts) — curve strength, stability, expectancy

## Key structural changes needed:
- Expand Trader struct: equity_at_trade, trade_returns, trade_timestamps,
  dd_bottom tracking, expert_rolling, completed_drawdowns, session_accuracy
- RiskContext struct to avoid parameter explosion
- 10 risk sub-methods mirroring market eval methods

## Implementation order:
1. Trader struct expansion + atom registration
2. Categories 1+3 (drawdown + accuracy dynamics) — highest impact
3. Categories 4+9 (return vol + loss correlation) — statistical depth
4. Category 5 (expert panel dynamics) — meta-awareness
5. Categories 6+8 (regime + calendar) — conditional accuracy
6. Categories 7+10 (recovery + edge health) — finishing touches

Full spec in agent output.
