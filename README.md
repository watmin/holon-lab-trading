# Holon Lab: Trading

A machine that measures thoughts against reality. Grace or Violence. Nothing more.

Built from six primitives. Specified in [wat](https://github.com/watmin/wat). Defended by eight wards. The specification IS the program — delete it, run the spells, it reappears.

## What This Is

A self-organizing trading enterprise that learns which thoughts about markets predict value. The architecture is domain-agnostic — point it at BTC, SOL, gold, anything with a candle stream. The six primitives don't care what they think about.

**Current state:** The specification is complete — 40 wat files, 3248 lines, proven by eight wards across three inscriptions. The Rust compilation from the proven wat is next.

## Architecture

```
f(state, candle) → state   where state learns.
```

One fold. One expression. The enterprise processes raw candles through a four-step loop:

1. **RESOLVE** — settle trades, propagate outcomes
2. **COMPUTE+DISPATCH** — encode → predict → compose → propose
3. **TICK** — paper trades learn, triggers update
4. **COLLECT+FUND** — treasury funds the proven

N market observers × M exit observers × N×M brokers per asset pair. Each broker is an accountability unit — it measures Grace or Violence. The treasury funds proportionally to proven edge.

## The Specification

`wat/GUIDE.md` is the source of truth. Everything else derives from it.

```
wat/
  GUIDE.md              — the master blueprint
  CIRCUIT.md            — signal flow diagrams (8 circuits)
  ORDER.md              — construction order (leaves to root)
  40 .wat files         — s-expression specifications
```

The wat is disposable. The guide produces it. Delete the wat. Run the spells. The wat reappears. Proven three times.

## Eight Wards

Spells that defend against bad thoughts:

| Ward | Question |
|------|----------|
| `/ignorant` | Does the path teach? |
| `/scry` | Does the spec match the code? |
| `/sift` | Are all forms real? |
| `/gaze` | Does it communicate? |
| `/forge` | Does it compose? |
| `/reap` | Is anything dead? |
| `/sever` | Is anything tangled? |
| `/assay` | Is there substance? |

Seven check correctness. The eighth checks completeness.

## Six Primitives

```
atom    — name a thought
bind    — compose thoughts
bundle  — superpose thoughts
cosine  — measure a thought
reckoner — learn from a stream of thoughts
curve   — evaluate the quality of learned thoughts
```

## The Book

[BOOK.md](BOOK.md) documents the full journey. The architecture, the philosophy, the songs, the Latin, the catharsis. From visual encoding failure to three inscriptions of a self-improving specification.

## Quick Start

```bash
./enterprise.sh build                                    # compile (release)
./enterprise.sh run --max-candles 5000 --asset-mode hold  # quick run
./enterprise.sh test 100000 --asset-mode hold --name run  # benchmark
```

## Links

- [Holon](https://github.com/watmin/holon) — the VSA/HDC library (Python reference)
- [holon-rs](https://github.com/watmin/holon-rs) — the Rust implementation
- [wat](https://github.com/watmin/wat) — the specification language
