# Ward: Gaze — Proposal 056 renamed files

Five files examined after the 056 restructure. The question: do the names
speak after the rename? Are old ghosts still whispering?

## Findings

### Level 1 — Lies

**1. broker_program.rs line 5: "Encodes anxiety atoms from active position receipts."**

The broker no longer encodes "anxiety atoms." It builds portfolio rhythm ASTs
and feeds them through a noise subspace. The word "anxiety" is the old
architecture. The comment lies about what the code does. Lines 5-6 of the
module doc are stale.

Actual code: `portfolio_rhythm_asts()` builds avg-paper-age, avg-time-pressure,
avg-unrealized-residue, grace-rate, active-positions. Then `noise_subspace`
strips background. The gate reckoner predicts from the anomaly. No anxiety
atoms exist.

**2. broker.rs line 2: "anxiety atoms"**

The struct doc says "The broker owns the game — gate 4, anxiety atoms,
exit/hold decisions." Same ghost. The broker owns the noise subspace and
gate reckoner, not anxiety atoms. The doc lies about the struct's contents.

**3. wat-vm.rs lines 4-5: "Position observers compose market thoughts with position facts."**

The module doc says "Position observers" — the old name. They are regime
observers now. The entire top-of-file doc tells the wrong story.

**4. wat-vm.rs line 187: "Position observer wiring" section header**

The code inside (`WiredRegimeObservers`, `wire_regime_observers`) uses the
correct name. The section comment lies.

**5. wat-vm.rs line 530: "Position observer does not learn."**

Should say "Regime observer does not learn."

**6. wat-vm.rs line 546: "Position observers" section header**

Same ghost. The variables below (`regime_observers`, `wire_regime_observers`)
speak correctly. The comment lies.

### Level 2 — Mumbles

**7. chain.rs line 37: `regime_facts: Vec<ThoughtAST>`**

The field carries rhythm ASTs built by `build_rhythm_asts()` — bundled bigrams
of trigrams with structural deltas. These are not "facts" in the way the
codebase uses the word elsewhere (e.g., `encode_regime_facts` in lens.rs
returns individual scalar bindings). The regime observer's output is rhythm
ASTs. A reader arriving at `chain.regime_facts` will expect the old
per-candle scalar facts, not rhythm trees.

Suggested: `regime_rhythms` — mirrors "market rhythms" and "portfolio rhythms"
used in broker_program.rs comments.

**8. broker_program.rs line 69: parameter `regime_facts`**

Same issue. The parameter to `broker_thought_ast()` is named `regime_facts`
but carries rhythm ASTs. The comment on line 81 says "Regime rhythms" which
is the truth — the parameter name should agree.

**9. broker_program.rs line 276: `fact_count: chain.regime_facts.len()`**

The LogEntry field is named `fact_count` but counts rhythm ASTs. Minor —
follows from finding 7.

### Level 3 — Taste (not findings)

- `portfolio_rhythm_asts` is clear but slightly long. Acceptable — it says
  exactly what it does.
- `extract_and_build` closure in `portfolio_rhythm_asts` — the name is
  generic but scope is tiny (5 lines). Acceptable.
- `ns` as a variable name for namespace string in telemetry blocks — scope
  is tight, type is obvious. Acceptable.
- rhythm.rs: the `10_000 as f64` hardcoded twice (lines 57 and 116) —
  already runed as `rune:forge(dims)`. Not a gaze finding.

## Summary

| Level | Count | Location |
|-------|-------|----------|
| 1     | 6     | broker_program.rs (2), broker.rs (1), wat-vm.rs (3) |
| 2     | 3     | chain.rs (1), broker_program.rs (2) |
| 3     | 4     | taste only, not counted |

The gaze does not converge. Six lies and three mumbles.

The "anxiety atoms" ghost appears in two files. It was the pre-056
architecture. The noise subspace replaced it.

The "position observer" ghost appears in three places in wat-vm.rs. The
structs and functions were renamed but the comments were not.

The `regime_facts` naming is a mumble — the field carries rhythm ASTs, not
individual facts. Renaming to `regime_rhythms` would align with the
vocabulary used in comments throughout broker_program.rs.

## Files examined

- `/home/watmin/work/holon/holon-lab-trading/src/programs/app/broker_program.rs`
- `/home/watmin/work/holon/holon-lab-trading/src/programs/app/regime_observer_program.rs` — clean
- `/home/watmin/work/holon/holon-lab-trading/src/programs/chain.rs`
- `/home/watmin/work/holon/holon-lab-trading/src/encoding/rhythm.rs` — clean
- `/home/watmin/work/holon/holon-lab-trading/src/domain/broker.rs`
- `/home/watmin/work/holon/holon-lab-trading/src/bin/wat-vm.rs` — checked for stale references
