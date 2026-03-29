# wat/mod — Vocabulary Modules

Domain-specific vocabulary packages. Each module defines atoms + eval methods
that produce facts. Experts include the modules they need.

## Structure

```
wat/
├── primitives.wat     — corelib: atom, bind, bundle, cosine, journal, curve
├── common.wat         — stdlib: comparisons, zones, time, direction
├── mod/
│   ├── oscillators.wat   — RSI, stochastic, CCI, Williams %R, UltOsc, StochRSI
│   ├── divergence.wat    — any indicator diverging from price
│   ├── crosses.wat       — signal line crosses, golden/death, temporal lookback
│   ├── segments.wat      — PELT changepoints, segment narrative
│   ├── levels.wat        — fibonacci, pivot points, support/resistance
│   ├── channels.wat      — ichimoku, keltner, bollinger, donchian
│   ├── flow.wat          — OBV, A/D, money flow, VWAP, buying/selling volume
│   ├── participation.wat — volume confirmation, spike, drought, price action
│   ├── temporal.wat      — cross timing, lookback, "how long ago"
│   ├── calendar.wat      — sessions, holidays, funding cycles
│   ├── persistence.wat   — DFA, Hurst, autocorrelation, trend strength
│   ├── complexity.wat    — entropy, fractal dim, spectral slope, G-R b-value
│   └── microstructure.wat — choppiness, aroon, variance ratio, DeMark, KAMA
├── expert/
│   ├── momentum.wat    — (require oscillators divergence crosses)
│   ├── structure.wat   — (require segments levels channels)
│   ├── volume.wat      — (require flow participation)
│   ├── narrative.wat   — (require temporal calendar)
│   ├── regime.wat      — (require persistence complexity microstructure)
│   └── exit.wat        — (require position state)
└── manager.wat         — reads expert opinions, not modules
```

## Dependency Rule

An expert declares its modules. The manager never includes modules —
it reads expert outputs. The stdlib is implicit for all experts.

## Expanding Vocabulary

To make an expert richer, add atoms to its modules. To create a new
expert, compose existing modules in a new combination. To add a new
domain, create a new module.
