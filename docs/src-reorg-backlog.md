# src/ Reorganization Backlog

The src/ root has 30+ flat files. The services and programs are
organized. The root files aren't. Move them into clusters.
Leaves to root. Assess after each move.

## Dependency levels (leaves first)

```
LEVEL 0 — leaves (no root deps):
  enums, newtypes, raw_candle, candle, window_sampler,
  engram_gate, thought_encoder, trade_origin

LEVEL 1 — depend on leaves:
  distances, scalar_accumulator, paper_entry, proposal,
  trade, scale_tracker, ctx, indicator_bank, simulation,
  log_entry

LEVEL 2 — depend on level 1:
  market_observer, exit_observer, settlement, broker

LEVEL 3 — depend on level 2:
  treasury, post

LEVEL 4 — the root:
  enterprise
```

## Clusters (proposed — assess after each move)

1. **types/** — enums, newtypes, distances, raw_candle, candle
   Foundation. Leaves. Everything depends on these.

2. **encoding/** — thought_encoder, scale_tracker, ctx
   The encoding pipeline.

3. **learning/** — scalar_accumulator, engram_gate, window_sampler
   Learning primitives.

4. **trades/** — paper_entry, trade, trade_origin, proposal, settlement
   Trade lifecycle.

5. **domain/** — market_observer, exit_observer, broker
   The structs the programs own. Not the programs — the state.

6. **orchestration/** — post, treasury, enterprise
   The wiring layer (legacy — replaced by the kernel).

## Pending renames

- [ ] `RawCandle` → `Ohlcv` — it IS ohlcv data. Asset pair + timestamp +
      open/high/low/close/volume. The name should say what it IS.
      `raw_candle.rs` → `ohlcv.rs`. Large blast radius — touch later.
- [ ] `Candle` stays — the enriched form. Ohlcv + 100 indicators.

## Uncertain

- `indicator_bank.rs` — enrichment pipeline. encoding/? its own?
- `simulation.rs` — pure functions. trades/? its own?
- `log_entry.rs` — used everywhere. types/?
- `domain/` as a name — is there a better word?

## Move order (leaves to root)

- [ ] **types/** — move first. Leaves. Nothing depends on
      types/ that types/ depends on. Update all `crate::enums`
      → `crate::types::enums`, etc. Assess.
- [ ] **encoding/** — move second. Depends on types/ only.
- [ ] **learning/** — move third. Depends on types/ only.
- [ ] **trades/** — move fourth. Depends on types/ + learning/.
- [ ] **domain/** — move fifth. Depends on types/ + encoding/ + learning/.
- [ ] **orchestration/** — move last. Depends on everything.
- [ ] **Delete legacy** — encoder_service.rs, log_service.rs.
      After kernel migration is complete.

## Principle

Assess after each move. The ignorant walks. If the move
created confusion, fix before advancing. The names may change
as we see them in place. The clusters may merge or split.
Leaves to root. Always.
