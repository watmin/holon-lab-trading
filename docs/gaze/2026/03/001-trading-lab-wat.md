# Gaze Report: Trading Lab Wat Specifications

*First gaze. 2026-03-30.*

## Summary

| File | Spark | Issues |
|------|-------|--------|
| `enterprise.wat` | Yes | Stale has/needs section; exit expert missing from org chart |
| `market/manager.wat` | Yes | Minor prose inconsistency; orphaned "coalgebra" reference |
| `market/generalist.wat` | Partial | Eval method wall; stale DISCOVERY; window description contradicts enterprise.wat |
| `market/observer/momentum.wat` | Yes | Example includes removed DFA fact; stale require statements |
| `market/observer/structure.wat` | Yes | Vocabulary header claims regime indicators it doesn't own |
| `market/observer/volume.wat` | Partial | Self-contradicting DISCOVERY (4 methods listed, says 3) |
| `market/observer/narrative.wat` | Yes | "Does NOT see" contradicts eval list re: PELT |
| `market/observer/regime.wat` | Yes | Aspirational items buried in RESOLVED section |
| `market/observer/exit.wat` | Yes | Lives under market/observer but says it's NOT a market observer |
| `risk.wat` | Partial | Duplicate `loss-density` atom; Buy/Sell labels need clarification |
| `treasury.wat` | Yes | No findings |
| `position.wat` | Yes | Asset-specific names (USDC/WBTC) in asset-agnostic spec |
| `ledger.wat` | Yes | No findings — the standard for brevity with impact |
| `candle.wat` | Yes | Aspirational sections not clearly marked |
| `vocab.wat` | Yes | No findings — best-written spec in the set |

## Cross-file findings

1. **Stale DISCOVERY sections.** generalist.wat, volume.wat, and narrative.wat have DISCOVERY sections that may no longer be current. regime.wat RESOLVED is the model — mark answered questions RESOLVED with the answer.

2. **Exit expert has no home.** Filed under `wat/market/observer/` but explicitly says it's not a market observer. enterprise.wat's org chart doesn't include it.

3. **Duplicate atom: `loss-density`** in risk.wat appears in both volatility and correlation specialists.

4. **Narrative contradiction.** "Does NOT see PELT segment narrative" vs the vocabulary and eval list that say it does (via eval_temporal which operates on PELT segments).

5. **Asset-specific names in position.wat** (USDC, WBTC) — should be base_asset/quote_asset given the multi-desk vision.

6. **Momentum example includes DFA fact** that the RESOLVED section says was removed from momentum.

7. **Structure vocabulary header** includes "advanced regime indicators" but regime.wat claims exclusive ownership.

8. **Volume.wat self-contradicts.** Eval list has 4 methods, DISCOVERY says 3. Flow module described as existing in eval list, asked for in DISCOVERY.

## What shines

- enterprise.wat is the crown jewel. The org chart, the interfaces, the boundaries — a newcomer could understand the enterprise from this file alone.
- regime.wat's "WHY REGIME SURVIVED THE GATES" section explains empirical results through architecture. Insight, not commentary.
- ledger.wat's contract (seven numbered rules, each one sentence) is the standard for brevity.
- vocab.wat is the best-written spec in the set. The Hickey quote earns its place.
- narrative.wat's opening example ("RSI was trending up for 8 candles...") is the best single sentence in any observer file.
- The "does NOT see/do" boundary sections across all files create a clear immune system.
