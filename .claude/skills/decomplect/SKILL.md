---
name: decomplect
description: Defend the architecture from complection. The codebase was a mess because we let it get there trying to get here. We are here now. Good thoughts must survive.
argument-hint: [file-path]
---

# Decomplect

> "I'd rather have more things hanging nice, straight down, not twisted together, than just a couple of things tied in a knot." — Rich Hickey

The enterprise is built from six primitives. Two templates. One tree. The code must reflect that simplicity. When the code is complected, the architecture is hidden. When the architecture is hidden, we can't think about it. When we can't think about it, we can't improve it.

This skill defends what we built. The codebase was a mess because we let it get there trying to get here. We arrived. Now we hold the line.

## The principle

Simple means not interleaved. The momentum expert doesn't know about the treasury. The risk manager doesn't know about PELT segments. The exit expert doesn't know about expert opinions. Each is an island connected through abstractions. The channel contract is the abstraction. Producers always emit. Consumers subscribe with filters.

The six primitives don't complect. Atom names a concept — that's all it does. Bind composes two things — it doesn't accumulate or measure. Bundle superimposes — it doesn't predict or filter. Each primitive does one thing. They compose but they don't interleave.

The binary is the heartbeat — it orchestrates. It calls modules. It doesn't define vocabulary. It doesn't encode. It doesn't own domain concepts. When encoding logic appears inline in enterprise.rs, a thought has escaped its home.

## Step 1: Scan

Read the target file (default: `src/bin/enterprise.rs`). Find:

1. **Inline struct definitions** inside functions. Every struct is a concept. Every concept has a domain. Every domain has a module. A struct in `main()` is a thought without a home.

2. **Duplicated encoding patterns** — the same `Primitives::bind` / `encode` / `bundle` sequence at multiple call sites. This is the most dangerous complection. When encoding diverges between prediction and resolution, the manager learns from a different thought than it predicted with. One function. Called N times. The encoding IS the thought — it must be identical everywhere.

3. **Atoms that belong in a module** — `vm.get_vector("...")` calls that create domain vocabulary inline. Atoms are named thoughts. Named thoughts belong with their thinkers. Market atoms in `market/`. Risk atoms in `risk/`. The vocabulary IS the module's identity.

4. **Domain logic on the wrong struct** — encoding methods that read from one domain but live on another domain's struct. `risk_branch_wat` on `Trader` is risk thinking trapped in portfolio state. Domain logic lives in its domain module.

5. **Concerns braided together** — one block doing encoding + learning + logging + gating. The encoding is pure (no side effects). The learning is accumulation (state change). The logging is measurement (read-only). The gating is policy (conditional). When these interleave, you can't change one without risking the others.

Report what you find with line numbers, grouped by type. Count occurrences.

## Step 2: Propose

For each finding:

- **Where it goes**: which module (existing or new). Follow the fractal — `market/` has a manager and observers. `risk/` has branches. When `risk/` needs a manager, it gets `risk/manager.rs`. Same shape as `market/manager.rs`. The architecture IS the module layout.
- **What the call site becomes**: show the before (braided) and after (straight down).
- **Why this matters**: not just "cleaner code" but what capability this unlocks. Extracting the exit encoding to `market/exit.rs` means a future exit expert gets its own module to grow in.

Don't over-abstract. Three similar lines are better than a premature helper. The threshold: extract when something appears 2+ times, or when a struct/concept is defined in the wrong scope. If you're not sure, it's not complection yet.

## Step 3: Execute

One change at a time. Build after each. Smoke test after each.

```
1. Create or update the destination module
2. Add to lib.rs if new module
3. Update imports in enterprise.rs
4. Remove the inline definition
5. cargo build --release --bin enterprise
6. ./enterprise.sh run --max-candles 500 --asset-mode hold
```

Never batch structural moves. A failed build with 5 changes is 5x harder to debug than 5 builds with 1 change each. We learned this the hard way — sed broke brace matching during visual ghost removal. One change. One build. One confirmation.

## Module layout

```
src/bin/enterprise.rs  — the heartbeat. Orchestrates. Doesn't define.
src/market/
  mod.rs               — shared market primitives (time parsing)
  manager.rs           — manager encoding (atoms, context, encode function)
  observer.rs          — Observer struct + constructor
src/risk/
  mod.rs               — RiskBranch struct + constructor
src/vocab/             — thought vocabulary modules
src/journal.rs         — the learning primitive (generic, no domain)
src/thought.rs         — Layer 0: candle -> thoughts
src/portfolio.rs       — Trader struct (state + phase transitions)
src/position.rs        — Pending, ExitObservation, ManagedPosition
src/treasury.rs        — asset map
src/sizing.rs          — Kelly criterion
```

Flat modules stay flat until they need a sibling. Promote `foo.rs` to `foo/mod.rs` only when `foo/bar.rs` arrives. Don't create empty shells — grow the tree when the leaves arrive.

## What is NOT complection

- **A long function that does one thing.** The heartbeat loop is 1,900 lines. It is long. It is not complected. It orchestrates a sequence: encode, predict, manage positions, learn, log. Each step calls modules. The length is the sequence, not the interleaving.

- **Pre-warming `vm.get_vector()` calls.** Cache warming is infrastructure, not encoding. It doesn't define vocabulary — it ensures the vector cache is hot before the hot path.

- **Similar-looking code on different data.** Building a ManagerContext at prediction time and at resolution time looks similar — same struct, same fields. But the data differs (current state vs snapshot state). That's not duplication. That's the same interface serving different moments. The ENCODING function is shared. The CONTEXT construction is per-site.

- **The main loop itself.** The heartbeat is the enterprise's pulse. It is the one place where all the modules meet. That meeting IS the orchestration. Don't extract it into abstraction — the heartbeat's clarity comes from being readable top-to-bottom, not from being hidden behind traits.

## The test

After all changes: enterprise.rs has zero inline struct definitions, zero duplicated encoding blocks, and every domain concept lives in its domain module. The binary calls functions. The modules define vocabulary. The architecture is visible in the file tree.

The module layout IS the enterprise tree:
```
market/     → the market team (manager + observers)
risk/       → the risk team (branches, future: manager)
vocab/      → the language the experts speak
journal.rs  → the learning primitive every expert uses
```

When someone reads the `src/` directory, they should see the enterprise. Not a list of files — a tree of roles.
