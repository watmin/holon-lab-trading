# Enterprise Trading Plan

## Where We Are (2026-04-03)

The streaming refactor is complete. Seven wards clean. 272 tests, 92.5% coverage.
The Journal sign bug (abs-sort discarding direction) is fixed in holon-rs. Observers
now predict both Buy and Sell. Momentum leads at 53.3% on 10k candles.

Full 652k validation pending. Accounting / position sizing needs investigation —
trades are $37 on a $5000 base (dust). P&L dominated by passive BTC appreciation.

## Architecture

```
Treasury (asset map: USDC + WBTC, hold mode, Rate newtype)
├── Desk (the fold — on_candle, positions, learning)
│   ├── Manager Journal (signed expert opinions → raw price direction)
│   │   ├── Momentum Observer [GATED, sampled window]
│   │   ├── Structure Observer [GATED, sampled window]
│   │   ├── Volume Observer [GATED, sampled window]
│   │   ├── Narrative Observer [GATED, sampled window]
│   │   ├── Regime Observer [GATED, sampled window]
│   │   ├── Generalist [GATED, fixed window=48, full vocab]
│   │   └── Gen-Classic [GATED, fixed window=48, original 8-method vocab]
│   ├── Exit Expert [learns Hold/Exit from position state]
│   └── Positions [ManagedPosition: stop/TP/trailing from ATR]
├── Risk Manager (Template 1 Journal: Healthy/Unhealthy)
│   ├── Drawdown Branch (OnlineSubspace)
│   ├── Accuracy Branch (OnlineSubspace)
│   ├── Volatility Branch (OnlineSubspace)
│   ├── Correlation Branch (OnlineSubspace)
│   ├── Panel Branch (OnlineSubspace)
│   └── Risk Generalist (OnlineSubspace, holistic)
├── Portfolio (phase transitions, drawdown tracking)
└── Ledger (candle_snapshot, trade_facts, disc_decode, observer_log, risk_log)
```

## Completed

- [x] Hold-mode manager reward (#17)
- [x] Fractional allocation (#18)
- [x] Per-position stop/TP from ATR (#19)
- [x] Partial profit taking — runners (#20)
- [x] Exit Expert (#1)
- [x] Risk generalist (#14)
- [x] Risk manager with Journal (#21)
- [x] Manager delta/motion encoding
- [x] Temporal encoding (hour, day-of-week, session)
- [x] Panel coherence fact
- [x] Streaming indicators (IndicatorBank from raw OHLCV)
- [x] Ichimoku streaming (9/26/52-period midpoints)
- [x] ROC acceleration fix (normalized per-candle rates)
- [x] Journal sign fix (raw cosine sort, not abs)
- [x] Diagnostic DB (candle_snapshot, trade_facts, prototype health)

## Open

### Debugging (blocks accuracy recovery)
- [ ] Full 652k run with sign fix — does accuracy recover to 59%?
- [ ] Accounting investigation — positions are dust ($37), P&L is passive BTC appreciation
- [ ] Layer 4-8 verification (see docs/verification-sequence.md)

### Expert Path (each replaces a magic value)
- [ ] **#3** Threshold Expert — learns move size from ATR/regime
- [ ] **#4** Horizon Expert — learns resolution time
- [ ] **#5** Position Sizing Expert — learns allocation from treasury state

### Architecture
- [ ] **#26** Unify Fact interface — flow ObvFacts and divergence Vec<Divergence>
- [ ] Ward the holon-rs substrate — the sign bug lived there unwarded
- [ ] Remove gen-classic observer once A/B testing is complete

## Holon Toolkit — Unused

We use ~10 of ~40 operations. Unexplored:
- `attend` — soft attention over expert opinions
- `prototype` + `cleanup` — pattern templates for winning/losing configs
- `segment` — regime change detection without labels
- `cross_correlate` — per-expert optimal horizon discovery
- `Engram` + `EngramLibrary` — serializable pattern memory
- `StripedSubspace` — high-complexity attribution
- `negate` — counterfactual reasoning ("without momentum's contribution")
- `analogy` — cross-asset pattern transfer
