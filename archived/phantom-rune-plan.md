# Phantom Rune Resolution Plan

110 phantom runes across 15 files. Partitioned into 8 groups.
Groups A-D require language growth. Groups E-H are application defines.

## A. Host language gaps (~16 forms, expand LANGUAGE.md)

Quick win. These are standard Lisp forms any host provides.

`length`, `second`, `member?`, `some?`, `sort-by`, `when-let`,
`fold-left`, `flatten`, `deque`, `push-back`, `pop-front`,
`range`, `unzip`, `quantile`, `last-n`, `zeros`

**Action:** Expand LANGUAGE.md host section. Strip runes.

## B. Enums / sum types (~6 runes, /propose structural)

Wat has struct (product types) but no enum (sum types). The enterprise
needs finite alternatives:

- Direction: `:long` | `:short`
- Phase: `:observe` | `:tentative` | `:confident`
- ExitReason: `:trailing-stop` | `:take-profit` | `:horizon-expiry`
- PositionPhase: `:active` | `:runner` | `:closed`
- PositionExit: `:stop-loss` | `:take-profit`

**Action:** `/propose structural` for `enum` form. Designers review.

## C. Constructors (~8 runes, naming convention)

`new-journal`, `new-online-subspace`, `new-scalar-encoder`,
`new-window-sampler`

The core says `(journal name dims refit-interval)`. The application
says `(new-journal ...)`. These are the same form — the constructor IS
the type name. Resolve by using core form names consistently.

**Action:** Update wat files to use core constructor names. Strip runes.

## D. IO / database layer (~8 runes, /propose structural)

`insert`, `commit`, `load-candles`, `parse-f64`, `parse-i32`,
`parse-hour`, `parse-day`

How does wat express side effects? The fold is (conceptually) pure.
The ledger uses `insert`/`commit` in the interpreter. File loading
and parsing are IO operations.

**Action:** `/propose structural` for IO forms. Or accept these as
the Rust compilation target's responsibility (wat specifies the shape,
Rust handles IO). Needs thought.

## E. Indicator engine vocabulary (~25 runes, application define)

`sma`, `ema`, `wilder-*`, `roc`, `slope`, `obv`, `cci`, `mfi`,
`williams-r`, `stochastic-k`, `range-position`, `trend-consistency`,
`body-ratio`, `ret-pct`, `last-close`, `max-high`, `min-low`,
`field`, `parse-hour`, `parse-day`

These are the streaming indicator reducers from proposal 004.
They belong in candle.wat as application defines — the indicator
engine's vocabulary.

**Action:** Define in candle.wat. These are domain, not language.

## F. Domain helpers (~15 runes, application define)

`drawdown`, `win-rate`, `streak-value`, `recovery-progress`,
`consecutive-losses`, `count-losses`, `last-n-returns`,
`last-n-outcomes`, `recent-return-mean`, `historical-worst-drawdown`,
`drawdown-velocity`, `accuracy`

Portfolio domain vocabulary.

**Action:** Define in portfolio.wat. Domain, not language.

## G. Encoding internals (~15 runes, application define)

`expert`, `encode-manager-thought`, `risk-multiplier`, `cache-get`,
`vocab-get`, `build-fact-cache`, `get-vector`, `get-position-vector`,
`dimensions`, `discriminant`, `mean-pairwise-cosine`, `recalib-count`,
`return-pct`

Enterprise-specific encoding pipeline.

**Action:** Define in their respective wat files. Domain, not language.

## H. Algorithm functions (~15 runes, application define)

`log-linear-regression`, `bin`, `covariance`, `autocorrelation`,
`cumulative-*`, `dynamic-program`, `find-peaks`, `find-troughs`,
`lag-1`, `log-returns`, `hash-to-uniform`, `segment-direction`,
`adx-zone`, `check-bullish-pairs`, `check-bearish-pairs`

Math and algorithm helpers specific to the enterprise.

**Action:** Define in their respective wat files. Some (covariance,
autocorrelation) might earn std/statistics.wat promotion later if
they prove generic across domains.

## Priority order

1. **A** — host language gaps (quick, dissolves ~16 runes)
2. **C** — constructor naming (quick, dissolves ~8 runes)
3. **E-H** — application defines (medium, dissolves ~70 runes)
4. **B** — enums (proposal needed, dissolves ~6 runes but high impact)
5. **D** — IO layer (proposal needed, needs design thought)
