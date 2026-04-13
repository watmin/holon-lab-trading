# Resolution: Proposal 040 — Exit Trade Vocabulary

**Decision: APPROVED.**

**Resolves:** 038 (hold architecture), 039 (exit diversity), 040 (trade atoms)

## The atoms

Three voices converged. Five core atoms all three independently
proposed. Five additional atoms from unique perspectives. The
convergence IS the signal.

```scheme
;; Core — all three agreed
(Log "exit-excursion" excursion)
(Linear "exit-retracement" retracement 1.0)
(Log "exit-age" age)
(Log "exit-peak-age" peak-age)
(Linear "exit-signaled" signaled 1.0)

;; Seykota additions
(Log "exit-trail-distance" trail-distance)
(Log "exit-stop-distance" stop-distance)

;; Van Tharp additions
(Log "exit-r-multiple" r-multiple)
(Linear "exit-heat" heat 1.0)

;; Wyckoff addition
(Linear "exit-trail-cushion" trail-cushion 1.0)
```

## The exit observers

Two. Not one (traps us). Not four (no vocabulary basis).

- **Exit observer A:** core 5 atoms. The consensus. Lean.
- **Exit observer B:** all 10 atoms. The full vocabulary. Rich.

Both receive market context through extraction (28 atoms).
Both have self-assessment (2 atoms). Both predict trail WIDTH
as a continuous distance. The reckoner discovers if the extras
matter. The architecture handles two from day one.

## The grid

6 market × 2 exit = 12 brokers. Half the current 24.
Half the threads. Half the fees. Half the telemetry noise.
Enough diversity to discover which pairings hold.

## What changes

1. The exit lenses (Volatility, Timing, Structure, Generalist)
   are replaced by two trade-state observers (Core, Full).
2. The exit vocabulary shifts from MARKET facts (candle data) to
   TRADE facts (paper state). Market facts arrive through extraction.
3. The paper needs `peak_age` — candles since the extreme. Either
   a new field or computed from price_history at tick time.
4. The `domain/config.rs` changes: `create_exit_observers` returns
   2 observers instead of 4, with new atom sets.

## What doesn't change

- The market observers (6 lenses, unchanged)
- The pipeline (candle → market → exit → broker)
- The chain types (MarketChain, MarketExitChain)
- The telemetry, the cache, the database
- The journey grading (036, 037 — already implemented)
- The three primitives, the wat-vm, the architecture

## Next

Implement the 10 trade atoms. Wire them into the exit observer.
Run 10k. Measure trail widths, grace rates, residue. Compare
to the old 28-atom market-facing exit. The data decides.
