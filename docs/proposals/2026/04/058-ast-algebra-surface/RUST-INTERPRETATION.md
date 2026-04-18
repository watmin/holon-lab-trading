# Rust Interpretation Guide — Implementing the wat-vm under Model A

**Purpose:** practical notes for implementing the wat-vm in Rust under Model A (fully static loading, constrained eval). A reference, not a spec — updated as thinking progresses.

**Status:** living document. Complements FOUNDATION.md with implementation guidance.

---

## Overview

The wat-vm is a typed Lisp interpreter hosted on Rust. It:

1. Parses wat source files at startup.
2. Resolves symbols, type-checks, and optionally compiles to bytecode.
3. Registers all `define`s in a static symbol table and all types in a static type environment.
4. Runs a main event loop that evaluates user code against the frozen symbol table.
5. Supports dynamic AST composition and constrained `eval` at runtime — over the static symbol table only.

**Key structural property:** the wat-vm is a **trusted environment after startup**. All code has been verified. Runtime only sees DATA flowing in; never new code.

The existing wat-vm in the codebase already implements some of this. This guide describes the target shape under Model A; use the existing implementation as starting point where it aligns, rewrite where it diverges.

---

## Architecture Layers

```
┌──────────────────────────────────────────────────────────┐
│ Startup phase (runs once before main loop)               │
│                                                          │
│   1. Parser        : text → untyped AST                  │
│   2. Resolver      : resolve names, link references      │
│   3. Type checker  : verify signatures, catch errors     │
│   4. (Compiler)    : AST → bytecode (optional)           │
│   5. Registrar     : freeze symbol table + type env      │
│   6. Verifier      : cryptographic gating on loads       │
└──────────────────────────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────┐
│ Runtime phase (main loop)                                │
│                                                          │
│   7. Interpreter   : walks AST or bytecode               │
│   8. Native bridge : calls Rust primitives               │
│   9. Eval engine   : dynamic AST over static symbols     │
│  10. Encoder       : ThoughtAST → vector (lazy, cached)  │
│  11. Cache         : L1/L2 per FOUNDATION memory tiers   │
└──────────────────────────────────────────────────────────┘
```

---

## Core Data Structures

### `Value` — the runtime value type

Enum covering every type the interpreter can push on its stack / pass as argument:

```rust
pub enum Value {
    // Language-level values
    Bool(bool),
    Int(i64),
    Scalar(f64),
    String(Arc<str>),
    Keyword(Arc<Keyword>),        // :foo, :foo/bar/baz
    Null,
    List(Arc<Vec<Value>>),
    Function(Arc<Function>),       // defined or lambda

    // Algebra-level values
    ThoughtAST(Arc<ThoughtAST>),   // UpperCase forms build these
    Vector(Arc<HyperVector>),      // lowercase primitives produce these

    // User types (structs, enums, newtypes)
    Record(Arc<Record>),
    EnumVariant(Arc<EnumVariant>),
    Newtype(Arc<Newtype>),
}
```

`Arc` everywhere: wat values are shared and cheap to clone. No deep copies.

### `ThoughtAST` — the UpperCase tier

```rust
pub enum ThoughtAST {
    Atom(AtomLiteral),
    Bind(Arc<ThoughtAST>, Arc<ThoughtAST>),
    Bundle(Arc<Vec<ThoughtAST>>),
    Permute(Arc<ThoughtAST>, i32),
    Thermometer(f64, f64, f64),            // value, min, max
    Blend(Arc<ThoughtAST>, Arc<ThoughtAST>, f64, f64),
    Orthogonalize(Arc<ThoughtAST>, Arc<ThoughtAST>),
    Resonance(Arc<ThoughtAST>, Arc<ThoughtAST>),
    ConditionalBind(Arc<ThoughtAST>, Arc<ThoughtAST>, Arc<ThoughtAST>),
    Cleanup(Arc<ThoughtAST>, Arc<Vec<ThoughtAST>>),
}

pub enum AtomLiteral {
    String(Arc<str>),
    Int(i64),
    Scalar(f64),
    Bool(bool),
    Keyword(Arc<Keyword>),
    Null,
}
```

UpperCase forms in wat evaluate to `Value::ThoughtAST(...)`. They do NOT compute vectors. Encoding happens separately via `encode(ast)`.

### `Function` — callable values

```rust
pub struct Function {
    pub name: Option<Keyword>,      // Some for define, None for lambda
    pub params: Vec<(Symbol, TypeRef)>,
    pub return_type: TypeRef,
    pub body: Arc<WatAST>,
    pub captured_env: Option<Arc<Environment>>,   // Some for lambdas; None for top-level defines
}
```

`define`s have no captured env (they reference the global static symbol table). Lambdas capture their lexical environment at creation time.

### `SymbolTable` — frozen after startup

```rust
pub struct SymbolTable {
    functions: HashMap<Keyword, Arc<Function>>,
    // After startup: read-only. Attempting to register after startup panics or returns an error.
}

impl SymbolTable {
    pub fn register(&mut self, name: Keyword, f: Arc<Function>) -> Result<(), RegisterError> {
        if self.frozen { return Err(RegisterError::FrozenAfterStartup); }
        if self.functions.contains_key(&name) { return Err(RegisterError::Collision(name)); }
        self.functions.insert(name, f);
        Ok(())
    }

    pub fn freeze(&mut self) { self.frozen = true; }

    pub fn lookup(&self, name: &Keyword) -> Option<&Arc<Function>> {
        self.functions.get(name)
    }
}
```

The collision check is at REGISTER time. Two defines with the same name in two different files loaded at startup produce an error that halts the wat-vm before the main loop.

### `TypeEnv` — frozen after startup

```rust
pub enum TypeDef {
    Struct(StructDef),
    Enum(EnumDef),
    Newtype(NewtypeDef),
    Alias(AliasDef),        // deftype
}

pub struct TypeEnv {
    builtins: HashMap<Keyword, BuiltinType>,    // :Thought, :Atom, :Scalar, etc.
    user_types: HashMap<Keyword, TypeDef>,
    // Frozen after startup.
}
```

Similar freeze semantics. User types are registered via `struct`/`enum`/`newtype`/`deftype` forms during startup load.

### `Environment` — lexical scope

```rust
pub struct Environment {
    bindings: HashMap<Symbol, Value>,
    parent: Option<Arc<Environment>>,
}
```

For runtime execution. Parameters bind here. Lambdas capture an `Arc<Environment>` snapshot at creation.

The GLOBAL environment is a thin wrapper over the SymbolTable — lookups fall through from local → parent → ... → global symbol table.

---

## Parser

Input: wat source as text.
Output: `Vec<WatAST>` — top-level forms.

Standard recursive-descent parser for s-expressions. Nothing novel here; any Lisp parser template works.

Key concerns:
- Handle `;` line comments.
- Parse keyword tokens (`:foo/bar/baz`) as keyword literals, preserving full path.
- Parse type annotations `[name : Type]` with whitespace handling.
- Parse literals: string, int, float, bool, null, keyword.
- Produce a `WatAST` enum covering all possible forms.

```rust
pub enum WatAST {
    // Literals
    Literal(AtomLiteral),
    Symbol(Symbol),
    Keyword(Keyword),

    // Forms
    Define { name: Keyword, params: Vec<Param>, return_type: TypeExpr, body: Box<WatAST> },
    Lambda { params: Vec<Param>, return_type: TypeExpr, body: Box<WatAST> },
    Struct { name: Keyword, fields: Vec<Field> },
    Enum   { name: Keyword, variants: Vec<Variant> },
    Newtype { name: Keyword, inner: TypeExpr },
    Deftype { name: Keyword, shape: TypeExpr },
    Load       { path: String, verification: LoadVerification },
    LoadTypes  { path: String, verification: LoadVerification },

    // Algebra core (UpperCase) — parsed as specialized calls
    UpperCall { name: Keyword, args: Vec<WatAST> },

    // Regular function call (resolves at type-check time)
    Call { fn_expr: Box<WatAST>, args: Vec<WatAST> },

    // Language primitives
    Let   { bindings: Vec<(Symbol, WatAST)>, body: Box<WatAST> },
    If    { cond: Box<WatAST>, then_: Box<WatAST>, else_: Box<WatAST> },
    Cond  { clauses: Vec<(WatAST, WatAST)> },
    // ...
}
```

---

## Resolver

Pass that walks the WatAST and resolves symbol references:

- Variable lookups: bind to lexical scope (walk outward).
- Function calls by name: verify name is in the SymbolTable-being-built.
- Type references: verify in TypeEnv-being-built.
- UpperCase calls: verify the form is a known algebra primitive.

Forward references are allowed — the resolver runs AFTER all loads have parsed, so `:wat/std/Difference` and `:my/module/consumer` can reference each other regardless of file order.

Output: a resolved WatAST where every symbol reference has been verified.

---

## Type Checker

Runs after the Resolver. For each `define` (and each nested expression):

1. Build a typing environment with parameter types.
2. Walk the body, inferring/checking the type of each sub-expression.
3. Verify the body's final type matches the declared return type.
4. Store the verified function in the SymbolTable.

Key subtlety: **UpperCase forms produce `:Thought`; lowercase primitives produce `:Vector` or other concrete types.** The type checker must know which layer each form is at. Maintain a table:

```rust
let upper_signatures = hashmap!{
    "Atom"        => FunctionType { params: vec!["Any"],    return: "Thought" },
    "Bind"        => FunctionType { params: vec!["Thought", "Thought"], return: "Thought" },
    "Bundle"      => FunctionType { params: vec!["(:List :Thought)"],   return: "Thought" },
    // ...
};

let lower_signatures = hashmap!{
    "atom"        => FunctionType { params: vec!["String"], return: "Vector" },
    "bind"        => FunctionType { params: vec!["Vector", "Vector"],   return: "Vector" },
    "bundle"      => FunctionType { params: vec!["(:List :Vector)"],    return: "Vector" },
    // ...
};
```

Generics (parametric types, `(:List :T)`, `(:Function [...] :T)`) use simple substitution. No advanced type features needed.

---

## Interpreter

Direct AST walker is sufficient for a first pass. Bytecode compilation is an optimization.

```rust
pub fn eval(ast: &WatAST, env: &Environment, symbols: &SymbolTable) -> Result<Value, EvalError> {
    match ast {
        WatAST::Literal(lit) => Ok(lit.to_value()),
        WatAST::Symbol(name) => env.lookup(name).ok_or(EvalError::Unbound(name.clone())),

        WatAST::Call { fn_expr, args } => {
            let f = match &**fn_expr {
                WatAST::Symbol(name) => symbols.lookup(name).ok_or(...)?,
                _ => match eval(fn_expr, env, symbols)? {
                    Value::Function(f) => f,
                    other => return Err(EvalError::NotCallable(other)),
                }
            };
            let arg_values: Vec<_> = args.iter().map(|a| eval(a, env, symbols)).collect::<Result<_, _>>()?;
            apply_function(&f, &arg_values, symbols)
        }

        WatAST::UpperCall { name, args } => {
            let arg_values: Vec<_> = args.iter().map(|a| eval(a, env, symbols)).collect::<Result<_, _>>()?;
            construct_thought_ast(name, arg_values)  // returns Value::ThoughtAST(...)
        }

        WatAST::Lambda { params, return_type, body } => {
            Ok(Value::Function(Arc::new(Function {
                name: None,
                params: params.clone(),
                return_type: return_type.clone(),
                body: Arc::new((**body).clone()),
                captured_env: Some(Arc::new(env.clone())),
            })))
        }

        WatAST::If { cond, then_, else_ } => {
            match eval(cond, env, symbols)? {
                Value::Bool(true) => eval(then_, env, symbols),
                Value::Bool(false) => eval(else_, env, symbols),
                other => Err(EvalError::NotBoolean(other)),
            }
        }

        // ... other forms
    }
}

pub fn apply_function(f: &Function, args: &[Value], symbols: &SymbolTable) -> Result<Value, EvalError> {
    let mut new_env = match &f.captured_env {
        Some(captured) => Environment::child_of(captured.clone()),
        None => Environment::child_of_global(),
    };
    for ((name, _type), value) in f.params.iter().zip(args.iter()) {
        new_env.bind(name.clone(), value.clone());
    }
    eval(&f.body, &new_env, symbols)
}
```

That's the core of it. Add cases for `let`, `match`, `cond`, `begin`, etc. as needed.

**Closures work naturally.** Lambdas capture an `Arc<Environment>` at creation; when applied, they build their new environment as a child of the captured one. The shared lexical scope is automatic via `Arc` cloning.

---

## Native Bridge

Lowercase primitives are Rust functions. The bridge exposes them to the interpreter:

```rust
pub type NativeFn = Arc<dyn Fn(&[Value]) -> Result<Value, EvalError> + Send + Sync>;

pub struct NativeRegistry {
    natives: HashMap<Symbol, NativeFn>,
}

impl NativeRegistry {
    pub fn register(&mut self, name: &str, f: NativeFn) {
        self.natives.insert(Symbol::from(name), f);
    }

    pub fn call(&self, name: &Symbol, args: &[Value]) -> Result<Value, EvalError> {
        self.natives.get(name)
            .ok_or_else(|| EvalError::UnknownNative(name.clone()))?
            (args)
    }
}
```

At startup, register all lowercase primitives from holon-rs:

```rust
natives.register("atom", Arc::new(|args| {
    // Delegate to holon-rs's atom function
    let name = match &args[0] {
        Value::String(s) => s.as_ref(),
        _ => return Err(EvalError::TypeMismatch),
    };
    Ok(Value::Vector(Arc::new(holon_rs::atom(name))))
}));

natives.register("bind", Arc::new(|args| {
    let v1 = extract_vector(&args[0])?;
    let v2 = extract_vector(&args[1])?;
    Ok(Value::Vector(Arc::new(holon_rs::bind(v1, v2))))
}));

// ... bundle, cosine, permute, blend (the ratio one), etc.
```

All existing holon-rs primitives become natives under this bridge. Zero duplication — wat's lowercase calls forward to holon-rs.

---

## The Encoder

`encode(ast: &ThoughtAST) -> HyperVector`: the function that realizes a ThoughtAST into a vector.

```rust
pub fn encode(ast: &ThoughtAST, cache: &Cache, natives: &NativeRegistry) -> HyperVector {
    // Check cache first
    if let Some(v) = cache.get(ast) { return v.clone(); }

    // Realize by walking the AST and calling lowercase primitives
    let v = match ast {
        ThoughtAST::Atom(lit)     => holon_rs::atom_typed(lit),
        ThoughtAST::Bind(a, b)    => holon_rs::bind(&encode(a, cache, natives), &encode(b, cache, natives)),
        ThoughtAST::Bundle(xs)    => {
            let vecs: Vec<_> = xs.iter().map(|x| encode(x, cache, natives)).collect();
            holon_rs::bundle(&vecs)
        }
        ThoughtAST::Permute(t, k) => holon_rs::permute(&encode(t, cache, natives), *k),
        // ... other variants
    };

    cache.insert(ast.clone(), v.clone());
    v
}
```

Cache keyed by `Arc<ThoughtAST>` (or its hash). The L1/L2 memory hierarchy per FOUNDATION's "Cache Is Working Memory" section.

**Laziness:** `eval` of an UpperCase call produces `Value::ThoughtAST(...)`. The encoder only runs when something explicitly calls it — `(encode my-ast)` or `(cosine a b)` internally encodes both.

---

## Constrained Eval

A runtime primitive that takes a ThoughtAST value and evaluates it. Implementation:

```rust
pub fn constrained_eval(ast: &ThoughtAST, symbols: &SymbolTable, types: &TypeEnv) -> Result<Value, EvalError> {
    // Walk the AST. For each node:
    //   - Verify the form is known (UpperCase or symbol-table entry).
    //   - Verify types match.
    //   - Execute if all checks pass; else error.

    // Most ThoughtAST nodes are algebra-core — known by construction.
    // The only check needed is that user-supplied parts (atom literals,
    // keyword references, sub-AST) are well-formed and well-typed.

    // For calls to stdlib functions embedded in the AST:
    //   - Look up in SymbolTable; if missing, error.
    //   - Check argument types against signature.
    //   - If ok, apply.

    // Since eval receives a ThoughtAST (not a raw source AST), much of
    // the resolution has already happened. The main additional check
    // is type conformity of user-supplied leaves.

    verify_tree(ast, symbols, types)?;
    Ok(Value::ThoughtAST(Arc::new(ast.clone())))
}
```

Essentially: `verify` the AST against the static environment, then return it. The encoding (if needed) happens separately via `encode`.

Eval errors reveal the exact node that failed and why:
- "Unknown function `:attacker/evil/exec` at path ..."
- "Expected :Thought, got :Int at argument 2 of Difference"
- "Unknown type `:fake/type/Foo`"

---

## Startup Pipeline

```rust
pub fn boot_wat_vm(manifest: &Manifest) -> Result<WatVm, BootError> {
    let mut parser = Parser::new();
    let mut type_env = TypeEnv::new_with_builtins();
    let mut symbol_table = SymbolTable::new();
    let mut natives = NativeRegistry::new();

    // Step 1: register native primitives
    register_all_natives(&mut natives);

    // Step 2: process load-types entries (in order)
    for entry in &manifest.type_loads {
        let source = fs::read_to_string(&entry.path)?;
        verify_cryptographic_mode(&source, &entry.verification)?;
        let asts = parser.parse(&source)?;
        for ast in asts {
            match ast {
                WatAST::Struct { .. } | WatAST::Enum { .. }
                | WatAST::Newtype { .. } | WatAST::Deftype { .. } => {
                    register_type(&ast, &mut type_env)?;
                }
                _ => return Err(BootError::NonTypeFormInTypeLoad(entry.path.clone())),
            }
        }
    }

    // Step 3: freeze the type environment
    type_env.freeze();

    // Step 4: process function load entries
    for entry in &manifest.function_loads {
        let source = fs::read_to_string(&entry.path)?;
        verify_cryptographic_mode(&source, &entry.verification)?;
        let asts = parser.parse(&source)?;
        for ast in asts {
            match ast {
                WatAST::Define { .. } => {
                    // Resolve, type-check, register
                    let resolved = resolve(&ast, &symbol_table, &type_env)?;
                    let typed = type_check(&resolved, &type_env)?;
                    register_function(&typed, &mut symbol_table)?;
                }
                _ => return Err(BootError::NonFunctionFormInLoad(entry.path.clone())),
            }
        }
    }

    // Step 5: freeze the symbol table
    symbol_table.freeze();

    // Ready to run.
    Ok(WatVm { symbol_table, type_env, natives, cache: Cache::new() })
}

pub fn verify_cryptographic_mode(source: &str, mode: &LoadVerification) -> Result<(), BootError> {
    match mode {
        LoadVerification::Unverified => Ok(()),
        LoadVerification::Md5(expected) => {
            let actual = md5_of(source);
            if &actual != expected { return Err(BootError::HashMismatch); }
            Ok(())
        }
        LoadVerification::Signed { signature, pubkey } => {
            verify_signature(source, signature, pubkey).map_err(|_| BootError::InvalidSignature)
        }
    }
}
```

If any step fails — parse error, unknown type, type-check failure, signature mismatch, name collision — the wat-vm does not start. Boot returns `Err(...)`; the caller decides what to do (usually exit the process with an error log).

---

## Main Loop

Once the wat-vm is booted, the main loop is application-specific. A trading lab might look like:

```rust
pub fn main_loop(vm: &WatVm, market_stream: impl Stream<Item=MarketEvent>) {
    for event in market_stream {
        // Construct a ThoughtAST from the event (UpperCase call-emitting code).
        let event_thought = wrap_event(event);  // produces Value::ThoughtAST(...)

        // Look up the on-event handler in the symbol table (registered at startup).
        let handler = vm.symbol_table.lookup(&keyword(":my/trading/on-event")).unwrap();

        // Apply the handler.
        apply_function(handler, &[event_thought], &vm.symbol_table).unwrap();
    }
}
```

The handler's body is Rust-inaccessible code — it's stored as a ThoughtAST in the symbol table. The interpreter walks it, calls natives as needed, produces side effects (sending orders, updating engrams, etc.) via native bridge calls.

---

## Bytecode Compilation (Optional)

Direct AST walking is fine for a first pass. If performance becomes an issue, compile the AST to bytecode:

```rust
pub enum Op {
    LoadConst(Value),
    LoadLocal(Symbol),
    Call(Keyword, u16),             // function name, arg count
    UpperCall(Keyword, u16),        // UpperCase constructor, arg count
    Jump(usize),
    JumpIfFalse(usize),
    Return,
}

pub fn compile(ast: &WatAST) -> Vec<Op> { /* ... */ }

pub fn run(ops: &[Op], env: &mut Environment, ...) -> Value { /* ... */ }
```

A simple stack machine. The compiler is straightforward for Lisp — each form has an obvious sequence of ops.

Bytecode speeds up tight loops and repeated evaluations. Not needed for an initial implementation; add when profiling shows it matters.

---

## Key Design Decisions (for future discussion)

**1. Direct AST interpretation vs. bytecode.** Start with direct AST. Bytecode is an optimization; add when measured.

**2. Value representation.** `enum Value` with `Arc`-wrapped variants covers everything. Consider `Arc<[u8]>` for zero-copy Vector storage if SIMD matters.

**3. Cache eviction strategy.** L1 per-thread hot cache (small, fast). L2 shared cache (larger, LRU or similar). Engram L3/L4 via the library pattern (FOUNDATION's memory hierarchy).

**4. Error handling.** Rich error types with source spans. Every `EvalError` / `BootError` / `TypeError` should point at the file + line + column that caused it.

**5. Generics in the type system.** Start with just `:List<T>` and `:Function<args, return>`. Add more if needed.

**6. Macro handling.** Macros run at startup, before type-check. They transform source ASTs into final ASTs. The type checker sees the post-macroexpansion form.

**7. Native reuse vs. wrap.** Wherever possible, call holon-rs primitives directly from natives. Don't duplicate algebra.

**8. Threading.** The wat-vm is single-threaded per interpreter instance. CSP primitives (`spawn`, `send`, `recv`) create multiple wat-vm contexts. Each has its own environment stack; the symbol table and type env are shared `Arc`.

**9. Determinism.** For reproducibility, encoders should be deterministic (same AST → same vector byte-for-byte). Any randomness in atom seeding uses a fixed namespace hash, not a PRNG.

**10. Dynamic dispatch overhead.** For hot paths, consider a second bytecode level that specializes native calls. Premature until measured.

---

## Related Rust Lisp Implementations (for inspiration)

- **Steel** (Matt Paras): Rust Scheme with embedded-focus. Static typing optional. Similar architectural shape.
- **Rhai**: Rust scripting language. Not a Lisp, but good Rust-integration patterns.
- **RustyLisp / Rutie / gamma**: educational Rust Lisps. Good reference for parser + interpreter structure.
- **Crafting Interpreters** (Bob Nystrom): book covering lexer → parser → AST → interpreter → bytecode. Not Rust-specific but the algorithms translate.
- **Racket / Chez Scheme**: not Rust, but the reference implementations for how to do a serious Scheme. Read their docs for design patterns.

---

## What's Already Built (in the current wat-vm)

Per the memory notes: wat-vm exists. Runs. 30+ threads, zero Mutex, three messaging primitives (queue, topic, mailbox). Gets ~44 candles/sec at 10k candle benchmark.

Compare existing implementation to Model A:

- **Parsing / AST**: likely already handled; verify the AST enum covers the UpperCase forms per FOUNDATION.
- **Symbol table**: verify it freezes at startup; remove any runtime-registration paths.
- **Type checker**: audit to ensure types are enforced (not just documentation) on define/lambda signatures.
- **UpperCase tier**: may need explicit addition if the current wat-vm only handles lowercase primitives.
- **Constrained eval**: verify it exists with the safety checks described above.
- **Cryptographic verification**: may need to add the md5/signed modes to the load pipeline.

Migration plan: don't rewrite from scratch. Audit current wat-vm against this guide, identify gaps, land them incrementally. The existing code is load-bearing; the improvements are polishing.

---

## Open Questions (to keep thinking on)

1. **Memoization boundary.** Should encode-cache keys be AST-hash or AST-structural-identity (Arc pointer equality)? Tradeoff between lookup speed and cache hit rate.

2. **Generic type inference.** How deep does Hindley-Milner-style inference go? For small generic cases (map, filter) it's mechanical; for larger ones (if we ever add them) it requires more care.

3. **Operator intuition vs. explicit type annotations.** Should users be forced to annotate every parameter, or can we infer from first use? Proposal: required on `define`/`lambda`/`struct`; optional elsewhere.

4. **Serialization format.** EDN is the transport form per FOUNDATION. For the bytecode / cache, is serialization needed? Probably not for initial impl — keep everything in-memory.

5. **Hot-reload development mode.** For DEVELOPMENT (not production), is it worth a "reload" command that reboots the wat-vm with updated sources? Separate from Model A's production shape, but useful during iteration.

6. **Bytecode vs. native compilation via LLVM.** Far future: compile wat to native via LLVM? Probably not — the interpreter overhead is small and native compilation adds complexity. But worth noting as an option.

7. **WASM target.** Could the wat-vm be compiled to WASM for browser execution? Rust → WASM is well-supported. Would need to think about cryptographic-verification paths in the WASM environment.

8. **Proof-assistant integration.** The algebra has enough structure that formal proofs (in Lean, Coq, F*) might verify properties like "encode is deterministic" or "bind is self-inverse." Exotic but interesting.

---

**Signature:** *these are very good thoughts.* **PERSEVERARE.**

Keep updating this document as the thinking progresses. The Rust interpretation is not fixed — it's the target shape for the wat-vm to converge to.
