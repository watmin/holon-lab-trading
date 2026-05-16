# 058-037: `def-restricted` — Declared Access Control on Bindings

**Scope:** language
**Class:** LANGUAGE CORE — **INSCRIPTION 2026-05-16**
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-028-define (the `def` form this extends)
**Companion proposals:** 058-031-defmacro (the macro family `defn-restricted` lifts through)

---

## INSCRIPTION — 2026-05-16 — Declared restriction, both surfaces

A binding declared via `def-restricted` carries an allowed-caller-prefix
whitelist. The walker rejects call sites whose enclosing definition
does not match. This is "private functions" generalized — instead of
binary public/private, you declare which namespaces may call.

### The shape

**Substrate primitive (wat-side):**

```scheme
(:wat::core::def-restricted
  :name                              ;; the symbol being bound
  [:prefix-1:: :prefix-2:: ...]      ;; allowed-caller prefix list (Vec<keyword>)
  <value-expr>)                      ;; the value being bound
```

Three positional args. Same shape as `(def name value)` plus a
Vec-of-keywords whitelist between them.

**Defmacro sugar (wat-side):**

```scheme
(:wat::core::defn-restricted :name
  [:prefix-1:: :prefix-2::]
  [param <- :T ...]
  -> :Ret
  body)
;; expands to (def-restricted :name [prefixes] (fn [params] -> :Ret body))
```

Mirrors `defn`'s relationship to `def` (per 058-028).

**Rust-side complement (proc-macro attribute):**

```rust
#[restricted_to("wat-name", "prefix-1", "prefix-2")]
fn substrate_primitive(...) -> ... { ... }
```

Variadic positional string-literal args. First = wat name; rest =
prefixes. Codegen emits an `inventory::submit!` block; substrate setup
drains the inventory into the same `defined_value_restrictions` HashMap.

### Prefix matching

- Entry ending in `::` (e.g., `:wat::kernel::`) → namespace prefix match
  (caller FQDN must START WITH this prefix)
- Entry NOT ending in `::` (e.g., `:wat::kernel::specific-fn`) → exact
  FQDN match (only this single caller name allowed)
- Empty whitelist `[]` → no callers allowed (every call site fails)

### Semantics

At type-check time, every callable invocation is checked against the
binding's restriction list (if any). The walker traverses each user
fn/define body, identifies the enclosing definition's FQDN, and for
each call site whose head names a restricted binding:

1. Look up the binding's prefix list in `defined_value_restrictions`
2. If no entry → no restriction → call allowed
3. If entry exists → check enclosing FQDN against each prefix entry
4. If any entry matches → call allowed
5. If none match → emit `CheckError::DefRestrictedCallerNotAllowed`
   with callee name + enclosing fn FQDN + allowed prefix list

### The architecture — one storage, two surfaces

```
       Wat-side                                    Rust-side
       def-restricted                          #[restricted_to(...)]
       defn-restricted                                 │
            │                                          ▼
            │                        inventory::submit! at fn site
            │                                          │
            │                                          ▼
            │              freeze-time iteration of inventory::iter
            │              populates symbols.defined_value_restrictions
            │                                          │
            └──────────────────────────────────────────┘
                              │
                              ▼
            defined_value_restrictions HashMap
            (sym, mirrored to env at check time)
                              │
                              ▼
            walk_for_def_restricted_call walker
            enforces at type-check time
```

One walker, one storage, two declaration surfaces — symmetric across
the wat ↔ Rust boundary.

### Convergent design

The pattern across language traditions:

| Tradition | Form |
|-----------|------|
| **Rust** | `pub(crate)` / `pub(super)` — caller-scope visibility |
| **Clojure** | `^:private` metadata + `defn-` shortcut |
| **Erlang** | `-export([...])` — module-internal vs exported (inverted) |
| **Common Lisp** | symbol externals vs internals via packages |
| **Java** | `private` / `package-private` |
| **wat** | `def-restricted` (wat) + `#[restricted_to(...)]` (Rust) |

`def-restricted` is closest in spirit to Erlang's `-export` but inverted:
we declare who CAN call rather than what IS exported. More expressive
than binary public/private — a single binding can name multiple
specific allowed namespaces.

### What it enables

- Module-internal helpers (forbidden from calling code outside the
  module's namespace prefix)
- Substrate-internal primitives (forbidden from user wat code; only
  callable from `:wat::*` namespace)
- Test-fixture helpers (only callable from `:my::tests::*`)
- The 2-substrate-primitive consumer set in arc 170 Stone B
  (`Thread/join-result` + `Process/join-result` — both annotated
  `#[restricted_to("name", ":wat::")]`)

### What it does NOT enable

- **Runtime access control.** Restriction is type-check-time. Once
  the binding is captured as a value (e.g., passed as a fn argument),
  the runtime has no enforcement.
- **Cross-arc visibility scoping.** This is namespace-prefix-based,
  not module-system-based. Arc boundaries don't enter the check.
- **Sealing.** A user can always declare a binding in the allowed
  namespace and call from there. Restriction is collaborative —
  intended for substrate-author + test-fixture-author discipline,
  not adversarial sandbox.

### wat-rs reference implementation

- Wat-side primitive: `wat/core.wat` (slice 1, commit `24d3b0d`)
- Wat-side defmacro sugar: `wat/core.wat` adjacent to `defn`
- Rust-side proc-macro: `crates/wat-macros/src/lib.rs` (slice 2)
- Storage: `CheckEnv.defined_value_restrictions` / `SymbolTable.defined_value_restrictions`
  (`src/check.rs` + `src/runtime.rs`)
- Inventory wiring: `src/restriction_entry.rs` (slice 2 Stone 1)
- Setup iteration: `src/freeze.rs` step 6.8
- Walker: `walk_for_def_restricted_call` + `CheckError::DefRestrictedCallerNotAllowed`
  in `src/check.rs`

Arc INSCRIPTION: `docs/arc/2026/05/198-defn-restricted/INSCRIPTION.md`
in the wat-rs repo.
