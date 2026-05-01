# wat-clojure-flavor — local short-name package for the lab

**Status: draft / planning.** Not yet a real package. Captured
2026-05-01 mid-arc-109-slice-1f.

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

## The principle

**The substrate (`wat-rs`) vendors only FQDN.** Verbose, honest,
correct. That's our contract with users — they know exactly what
every name means, where it lives, what host it hits.

**Ergonomic short names are user-space.** This package is the
first proof-of-concept: the trading lab as a downstream consumer
takes wat-rs's FQDN substrate AND its own lab-local short-name
package, and the lab code becomes readable.

This validates the architectural position captured at
`~/work/holon/scratch/2026/04/009-substrate-fqdn-userspace-shorts/NOTES.md`:
substrate is the canonical truth; ergonomics is layered.

If this lab-local proof-of-concept proves itself, the package
graduates to a vendable `wat-common-clojure-flavor` (or whatever
name the community settles on).

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

## Lifecycle

1. **Phase 0 — wait** (now). Arc 109 mid-flight; substrate isn't
   stable yet for aliasing.
2. **Phase 1 — lab-local prove-out.** Create
   `holon-lab-trading/wat-clojure-flavor/` (or crates/) once arc
   109 substantially closes. Implement the typealias + macro
   layer. Migrate one lab subsystem (probably `wat/types/` or
   `wat/encoding/`) to use the short forms; verify readability
   improves; iterate.
3. **Phase 2 — lab full migration.** Migrate all lab wat code to
   the short forms. The lab becomes the proof-of-concept.
4. **Phase 3 — graduation (maybe).** If the lab's experience is
   compelling, the package graduates to `wat-common-clojure-flavor`
   in the wat-rs ecosystem (separate repo or sibling crate).
   Other consumers can depend on it.

## What the substrate decides

We are intentional: wat-rs (the substrate) does NOT pick a
flavor. It vendors FQDN. Multiple flavor packages can coexist:

- `wat-clojure-flavor` (this draft)
- `wat-haskell-flavor` (`Maybe<T>`, `Either<E,T>`, `>>=`, etc.)
- `wat-ml-flavor` (lowercase `option`, `result`, `list`, etc.)

Each user picks their favorite (or none) and writes wat code
under that flavor's surface. Substrate stays canonical.

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
