# wat-clojure-flavor — the trading lab's flavor surface

**Status: committed plan.** Drafted 2026-05-01 mid-arc-109; commitment
made same day after the polyglot architecture and namespace rules
firmed up.

The trading lab is the first concrete consumer of wat-rs's
polyglot lowering architecture. The lab adopts the
Clojure-flavored surface; the substrate stays FQDN-canonical.
The pair becomes the proof that **wat earns its name** — wat
hosts whatever surface a community wants, and this is the first
demonstration in production code.

## User direction

> i think i want to prove out some of these "clojure-familiar"
> forms in the trading lab... basically do a sub-crate like we've
> been doing for the wat-rs repo..
>
> we then depend on this localized clojure forms repo and clean up
> the lab to be remarkably readable..... the verbosity in the wat-rs
> repo is necessary for correctness
>
> users rely on us being correct and they can compose on top of us...

And later, after the polyglot framing settled (2026-05-01):

> i think we're going to make the trading lab a clojure-style app...
> ...
> this is a compelling path.. the substrate earns it name

## The principle

**The substrate (`wat-rs`) vendors only FQDN.** Verbose, honest,
correct. That's our contract with users — they know exactly what
every name means, where it lives, what host it hits.

**Ergonomic short names are user-space.** This package is the
**first proof-of-concept** of the polyglot lowering architecture
captured in scratch
`~/work/holon/scratch/2026/04/012-wat-as-polyglot-lowering-target/NOTES.md`:
substrate is the canonical truth; ergonomic surfaces are layered;
multiple flavor packages coexist via namespace separation; cross-
flavor calls work without FFI.

The trading lab is the live demo. Once arc 109 closes, the lab's
existing FQDN-canonical wat code migrates to the Clojure-flavored
surface. **Same compiled output; different reading experience.**

## The vision — strongly-typed Clojure as the forcing function

User direction (2026-05-01):

> i think the vision statement... we build the trading lab as a
> strongly-typed-clojure -- this forces us to find gaps in the
> substrate - this is a forcing function for completeness...

**The lab is not a demo. It's the requirements engine.**

Migrating the trading lab to a **strongly-typed Clojure** surface
on top of wat-rs forces every substrate gap into the open. A real
production-style multi-thousand-line codebase exercising the
substrate at full breadth will surface what's missing — reader
forms, typeclass dispatch, macro mechanics, diagnostic shapes,
type-system corners. Each gap becomes a substrate arc.

**Strongly-typed Clojure** is the framing — not just "Clojure
ergonomics," but "Clojure expressive power on a static-type
substrate." That's what wat uniquely offers. Most Clojure code
is dynamically typed; most static-type FP languages don't have
Clojure's threading-macro / data-literal / repl-friendly feel.
The lab proves the combination is possible AND useful.

The forcing-function dynamic:

```
lab module migrates → trips into substrate gap → gap becomes arc
                                                     ↓
substrate ships arc → lab module migration continues → next module
```

Each migrated module is a single requirements document for the
substrate. By the time the lab is fully migrated, the substrate
has absorbed every gap a working strongly-typed Clojure system
encounters. **Substrate completeness measured by usage, not by
spec.**

## Why the polyglot architecture pays off here

Other polyglot runtimes have FFI boundaries. JVM has JNI; .NET
has P/Invoke; Node has N-API; WebAssembly modules have
linear-memory ABIs. **wat has none of that.** Cross-flavor
function calls are ordinary function calls because flavor markup
vanishes at compile time.

So the lab is more than just "wat code that reads Clojure-y."
It demonstrates that:

- The substrate's FQDN-canonical core can host multiple
  ergonomic surfaces simultaneously
- A team can pick the surface that matches each module's nature
  (concurrency-heavy → Erlang flavor when that lands; pure
  transforms → Haskell flavor; domain logic → Clojure flavor)
- Cross-flavor interop is free — no marshalling, no boundary
- Other communities (Erlang shops, Haskell shops, ML shops) can
  follow the same architecture pattern when they adopt wat —
  the lab provides the template

The lab proves it for one flavor first; future labs/projects/
external consumers can replicate the pattern for theirs.

## How the lab claims its surface — namespaces

**`:wat::*` is reserved for substrate** — one-way contract. The
lab's flavor package lives under its own top-level namespace:

```scheme
;; wat-common-clojure-flavor's aliases live under :clojure::*:
(:wat::core::typealias :clojure::Map<K,V>     :wat::core::HashMap<K,V>)
(:wat::core::typealias :clojure::Set<T>       :wat::core::HashSet<T>)
(:wat::core::typealias :clojure::Maybe<T>     :wat::core::Option<T>)

;; Lab's project prelude pulls them up to bare-keyword level:
(:wat::core::typealias :Map<K,V>              :clojure::Map<K,V>)
(:wat::core::typealias :Set<T>                :clojure::Set<T>)
(:wat::core::typealias :Maybe<T>              :clojure::Maybe<T>)

;; Lab code reads:
(defn (encode-tick (t :Tick) -> :Maybe<Vector>)
  (let [(price :I64) (get t :price)
        (qty   :I64) (get t :qty)]
    (Some (encode (* price qty)))))
```

Substrate sees one canonical wat program. The lab sees Clojure-
flavored source. Both are right, simultaneously.

## Where it lives

Sub-crate under the lab repo. Two candidate paths:

1. `holon-lab-trading/crates/wat-clojure-flavor/` — Cargo crate
   with bundled wat sources.
2. `holon-lab-trading/wat-clojure-flavor/` — pure-wat directory
   loaded via `(:wat::load!)` from lab's main entry.

Likely (2): pure-wat package is just typealiases + macros. No
Rust changes. Loaded once at startup; every wat consumer in the
lab gets the short forms.

## What gates this work

This package depends on:

- **Arc 109 closing** (or substantially closing). The FQDN
  canonical forms must be stable before we alias them.
- **Variant constructor FQDN** (slices 1h Option / 1i Result, in
  flight) before the macros for `Some`/`Nothing`/`Just`/etc.
  land.
- **Substrate parser extension for bracket-form reader macros**
  (`[...]`, `{...}`, `#{...}`) — this is a **prerequisite arc**,
  not yet scheduled. Without parser support, the user can't
  write Clojure-style `(defn name [args] body)` because `[args]`
  doesn't parse. See scratch
  `~/work/holon/scratch/2026/04/012-wat-as-polyglot-lowering-target/NOTES.md`
  § "Gaps from syntax — reader-level extensions" for the full
  rationale. **One parser arc lights up the bracket forms for
  all flavor packages** (Clojure, Haskell `[a]`, ML cons-pattern).

Until the bracket-reader arc lands, this package's `defn` macro
form will use lispier paren wrapping like `(defn (name (args ->
:ret) body))` — still ergonomic, but less Clojure-feel than the
final `[args]` shape.

So this draft is captured now; the package gets built once arc
109 substantially closes AND the bracket-reader arc ships.

## Top forms by lab-frequency (data-driven priority)

Counted from `holon-lab-trading/wat/` (1230+ lines of substrate
references). Sorted by frequency:

| Substrate FQDN | Lab uses | Proposed short name | Notes |
|---|---|---|---|
| `:wat::core::f64` | 1230 | `:f64` | Rust-spelled primitive; Rust convention is lowercase |
| `:wat::core::i64` | 351 | `:i64` | same |
| `:wat::core::define` | 289 | `:def` | Clojure spelling |
| `:wat::core::let*` (post-rename `:let`) | 233 | `:let` | already queued in arc 109 follow-ups |
| `:wat::core::if` | 208 | `:if` | already short |
| `:wat::core::match` | 169 | `:match` | already short |
| `:wat::core::bool` | 115 | `:bool` | Rust-spelled primitive |
| `:wat::core::first` | 107 | `:first` | Clojure exact |
| `:wat::core::second` | 103 | `:second` | Clojure exact |
| `:wat::core::lambda` | 77 | `:fn` | Clojure spelling |
| `:wat::core::String` | 66 | `:String` | Rust-spelled primitive |
| `:wat::core::struct` | 63 | `:defstruct` | Clojure flavor with Lisp tradition |
| `:wat::core::tuple` (post `:Tuple` rename) | 59 | `:tuple` | constructor verb stays lowercase per Clojure flavor |
| `:wat::core::vec` (post `:Vector` rename) | 52 | `:vec` or `:vector` | Clojure: `(vec ...)` is the constructor — keep `:vec` |
| `:wat::core::get` | 49 | `:get` | Clojure exact |
| `:wat::core::length` | 48 | `:count` | Clojure spelling — `count` not `length` |
| `:wat::core::i64::to-f64` | 44 | `:i64->f64` | arrow convention |
| `:wat::core::map` | 32 | `:map` | Clojure exact (collides with HashMap constructor — see below) |
| `:wat::core::f64::max` | 31 | `:max` | polymorphic short |
| `:wat::core::typealias` | 30 | `:deftype` | Clojure flavor |
| `:wat::core::and` | 26 | `:and` | already short |
| `:wat::core::enum` | 24 | `:defenum` | Clojure flavor |
| `:wat::core::f64::abs` | 23 | `:abs` | polymorphic |
| `:wat::core::conj` | 22 | `:conj` | Clojure exact |
| `:wat::core::range` (post-§H move) | 18 | `:range` | Clojure exact |
| `:wat::core::assoc` | 18 | `:assoc` | Clojure exact |
| `:wat::core::foldl` | 15 | `:reduce` | Clojure spelling — "reduce" not "foldl" |

### Operator paths (currently typed-namespaced)

| Substrate FQDN | Lab uses (combined) | Proposed short name | Notes |
|---|---|---|---|
| `:wat::core::i64::+` / `:wat::core::f64::+` | many | `:+` | polymorphic; Clojure exact |
| `:wat::core::i64::-` / `:wat::core::f64::-` | 192+ | `:-` | same |
| `:wat::core::i64::*` / `:wat::core::f64::*` | many | `:*` | same |
| `:wat::core::i64::/` / `:wat::core::f64::/` | many | `:div` or `:/` | `:/` reads weird in keyword form; `:div` may be cleaner |
| `:wat::core::>` / `:wat::core::<` / etc | 82+ | `:>` `:<` `:=` `:>=` `:<=` | already polymorphic; just shorter |

## Open questions

1. **Polymorphic vs typed dispatch.** Clojure's `+` is one
   polymorphic op that does the right thing across numeric types.
   wat-rs has both `:wat::core::+` (polymorphic per arc 050) and
   `:wat::core::i64::+` / `:wat::core::f64::+` (typed strict).
   Lab uses both. The package should expose `:+` as the
   polymorphic; users who want type-strict reach for the FQDN.
2. **`:map` collision.** `map` is both a HOF (apply fn over coll)
   and a HashMap constructor. Clojure uses `map` for the HOF and
   `hash-map` (or `{...}` literal) for the constructor. wat-rs
   has `:wat::core::map` (the HOF) and the parametric type
   `:wat::core::HashMap<K,V>`. Probably fine to expose `:map` for
   the HOF and `:Map<K,V>` (capitalized typealias) for the type.
3. **Define-family naming.** Clojure has `def`, `defn`, `defmacro`,
   `defstruct`. wat-rs has `define` (defines a function),
   `defmacro`, `struct`, `enum`, `typealias`, `newtype`. Mapping:
   - `:def` → `:wat::core::define`? Maybe — but Clojure's `def`
     is a value-binding (not function), and `defn` is the
     function-defining form. wat's `define` is the function form.
     So `:defn` → `:wat::core::define` is more honest.
   - `:def` would be a value binding, which wat doesn't have at
     top level (top-level forms are functions/types, not bindings).
4. **`:foldl` → `:reduce` rename.** Clojure flavor uses `reduce`.
   ML/Haskell flavor uses `foldl`. The package commits to one.
5. **Variant constructors after slice 1g.** Once
   `:wat::core::Some` / `:wat::core::None` / `:wat::core::Ok` /
   `:wat::core::Err` are canonical, the package aliases them to
   `:Some` / `:None` / `:Ok` / `:Err` (bare-feeling, but as
   keywords).

## What the package CAN and CAN'T deliver — the colon stays

Before sketching the surface, name the permanent boundary. The
leading `:` on outer-position type annotations is wat's
lexer-level distinction between keyword (global symbol table) and
bare symbol (local binding). Permanent substrate requirement;
flavor packages cannot remove it.

| The package CAN | The package CAN'T |
|---|---|
| Drop the `wat::core::` namespace prefix via aliases (`:i64` for `:wat::core::i64`) | Drop the leading `:` on outer-position type annotations |
| Rewrite operator heads in macro-controlled slots (`+` → `:wat::core::+` inside `defn` body) | Drop `:` from type annotations outside macro-controlled slots |
| Provide Clojure-style `defn` / `fn` / `let` macros + container shortcuts | Erase the keyword/symbol distinction at the lexer level |
| Re-register names like `:Some` / `:Vec<T>` as user-space aliases (post-arc-109) | Reclaim names under `:wat::*` |

Bottom line: the package shrinks the FQDN namespace via aliases
and rewrites operator heads via macros. The colon-prefix on
outer-type annotations stays. It's the wat way.

Canonical framing: see
`~/work/holon/scratch/2026/04/009-substrate-fqdn-userspace-shorts/NOTES.md`
§ "What's permanent vs what's temporary."

## Reading the wat-clojure-flavor preview

Before:
```scheme
(:wat::core::define
  (:my::trade::pnl
    (entry  :wat::core::f64)
    (exit   :wat::core::f64)
    (qty    :wat::core::f64)
    -> :wat::core::f64)
  (:wat::core::*
    (:wat::core::- exit entry)
    qty))
```

After (with `wat-clojure-flavor` loaded):
```scheme
(:defn (:my::trade::pnl
         (entry :f64) (exit :f64) (qty :f64) -> :f64)
  (:* (:- exit entry) qty))
```

The substrate's truth doesn't change — both forms parse to the
same internal AST. The package adds a layer of macros + aliases
on top.

## Lifecycle — committed plan

### Phase 0 — wait (now)

Arc 109 mid-flight. Slices remaining: 1i (Result variants —
in-flight), § D' (Option/Result method forms), § H (range move),
plus three follow-ups (unit→Unit, Queue→Channel, let*→let).
Substrate vocabulary still moving; flavor package premature.

**Gate to leave Phase 0**: arc 109 substantially closes (slice
1i ships + § D' lands + most follow-ups absorbed). FQDN
canonical names settled. Walkers retired post-sweep.

### Phase 1 — package scaffold + first lab module migration (committed)

Create `holon-lab-trading/wat-clojure-flavor/` (pure-wat package,
loaded via `(:wat::load!)` from the lab's main entry). Implement:

- `:clojure::*` typealiases for the most-used substrate types
  (`:Map<K,V>`, `:Set<T>`, `:Maybe<T>`, `:Either<E,T>`,
  `:Vector<T>`, etc.)
- `:clojure::*` macros for the high-level forms (`defn`, `fn`,
  `let`, `case`, `cond`, threading macros if useful)
- Operator alias macros (`:+`, `:-`, `:*`, `:/`, `:=`, `:<`,
  `:>`, etc.) — keyword forms that expand to substrate FQDN
  operator paths
- The lab's project prelude pulls flavor aliases up to bare
  keyword level (e.g., `(:wat::core::typealias :Map :clojure::Map)`)

Migrate **one lab module** as the prove-out — probably
`wat/types/` (smallest, most type-annotation-heavy). Verify
readability improves; iterate on macro shapes.

### Phase 2 — lab full migration (committed)

Migrate every lab wat module to the Clojure-flavored surface.
Same canonical wat output; different source experience. Lab
runs the full trading system on the substrate via the flavor
package.

This is the **compelling-path proof**. A real production-style
trading system with multi-thousand-line codebase running on
wat-rs through the Clojure surface validates that the polyglot
architecture works end-to-end.

### Phase 3 — graduation (committed)

Once the lab's experience matures, the package graduates to a
vendable `wat-common-clojure-flavor` in the wat-rs ecosystem
(separate repo or sibling crate). Other consumers depend on it.

**This is also when other flavor packages become real targets.**
The lab proves the pattern for Clojure; subsequent flavors
(Erlang for Erlang shops, Haskell for typed-FP shops, ML for
OCaml shops) follow the template the lab established.

### Phase 4+ — community grows

Each new flavor surfaces its own substrate gaps (per scratch
012 § "Gaps from each language family"). The substrate roadmap
becomes community-driven: which language wants to land on wat;
which gap is cheapest to close; pick that arc.

## What the substrate decides

We are intentional: wat-rs (the substrate) does NOT pick a
flavor. It vendors FQDN under `:wat::*` (substrate-reserved).
**Flavor packages live under their own top-level keyword
namespaces — NOT under `:wat::*`.** Each flavor claims its own
prefix:

- `:clojure::*` — this package's namespace. `:clojure::Map<K,V>`,
  `:clojure::defn`, `:clojure::reduce`, etc.
- `:haskell::*` — Haskell-flavor package's namespace.
  `:haskell::Maybe<T>`, `:haskell::Either<E,T>`.
- `:ml::*` — ML-flavor namespace. `:ml::option`, `:ml::list`.
- `:erlang::*` — Erlang-flavor namespace. `:erlang::receive`,
  `:erlang::spawn`.

Each user picks their favorite (or none) and writes wat code
under that flavor's prefix. Substrate stays canonical (`:wat::*`).

**Cross-flavor function calls work without FFI** — once macros
expand, the whole program is canonical wat AST and a Clojure-
flavored function calling a Haskell-flavored helper inside an
Erlang-flavored actor is just three ordinary function calls.
See scratch
`~/work/holon/scratch/2026/04/012-wat-as-polyglot-lowering-target/NOTES.md`
§ "Cross-flavor calls — no FFI boundary" for the worked example.

For the common-case "I'm a Clojure shop; give me bare `:Map`"
ergonomics, users add a project-local typealias:

```scheme
;; In project prelude:
(:wat::core::typealias :Map<K,V> :clojure::Map<K,V>)
;; Now :Map<K,V> works at bare-keyword level, resolving via two
;; alias hops to :wat::core::HashMap<K,V>.
```

When mixing flavors, code uses the flavor-prefixed forms
explicitly (`:clojure::Map`, `:haskell::Map`).

## Cross-references

- `~/work/holon/scratch/2026/04/009-substrate-fqdn-userspace-shorts/NOTES.md`
  — the broader principle (substrate FQDN; ergonomic surface
  user-space). This lab proof-of-concept is the first concrete
  outgrowth.
- `wat-rs/docs/arc/2026/04/109-kill-std/` — the arc that puts the
  substrate in its FQDN-only position.
- `wat-rs/docs/SUBSTRATE-AS-TEACHER.md` — discipline. Migration
  walkers retire after consumer sweeps; FQDN canonical forms
  stay; user packages layer on top.

## Status — append more here as the idea matures

- 2026-05-01: draft captured during arc 109 slice 1f sweep. Top
  forms by lab-frequency tabulated. Open questions named. No
  package yet; waiting on arc 109 to substantially close.
