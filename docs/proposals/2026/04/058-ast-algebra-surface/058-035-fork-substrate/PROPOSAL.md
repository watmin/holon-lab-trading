# 058-035: Fork substrate — `:wat::kernel::pipe` / `fork-with-forms` / `wait-child` + hermetic as wat stdlib

**Scope:** kernel primitives (new) + stdlib relocation (hermetic
moves from kernel-registered Rust primitive to wat stdlib define)
**Class:** KERNEL + STDLIB — **INSCRIPTION 2026-04-21**
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** FOUNDATION's kernel-primitives tier,
`:wat::io::IOReader` / `IOWriter` substrate (wat-rs arc 008),
`:wat::core::forms` variadic-quote (wat-rs arc 010),
`:wat::kernel::run-sandboxed-hermetic-ast` (wat-rs arc 011 —
retired here and replaced)

---

## INSCRIPTION

Code led, spec follows — the *inscription* pattern. This
proposal records what wat-rs shipped on 2026-04-21 across
`src/fork.rs` + `src/io.rs` + `wat/std/hermetic.wat` and the
two retirements that landed alongside. Code and prose are
reflections; this document brings the prose into parity.

wat-rs arc reference: `docs/arc/2026/04/012-fork-and-pipes/`
(DESIGN.md + BACKLOG.md + INSCRIPTION.md). Every design decision,
sub-fog resolution, and retired primitive is recorded there;
this proposal is the summary for the 058 audit trail.

---

## Motivation

Arc 007 shipped `:wat::kernel::run-sandboxed-hermetic` for
service tests whose driver threads panic under in-process
`StringIo` stdio (the ThreadOwnedCell single-thread discipline).
Arc 011 added the AST-entry sibling `-ast` to let tests pass
inner programs as `:Vec<wat::WatAST>` instead of strings.

Both were operational, both coupled the language runtime to its
own binary path: `std::env::current_exe()` (or a
`WAT_HERMETIC_BINARY` env var) + tempfile write + `Command::spawn`
+ pipe-and-capture via `wait_with_output`.

Builder direction (2026-04-21): *"we need real fork."* The
substrate had the capability — libc was already a dep, the arc
008 IO traits abstracted over readers/writers, the arc 010
forms-are-values primitive gave us in-memory AST transport. What
was missing was the primitive that IS fork.

---

## The surface

Three new kernel primitives plus one struct plus the wat-stdlib
hermetic define.

### Kernel primitives

```scheme
(:wat::kernel::pipe
  -> :(wat::io::IOWriter, wat::io::IOReader))
```

Wraps `libc::pipe(2)`. Returns a 2-tuple: write end (producer)
first, read end (consumer) second. Both ends are fd-backed
wrappers (`PipeWriter` / `PipeReader` over `OwnedFd`) that call
`libc::read/write/close` directly — bypassing `std::io::Read`
/ `Write` entirely. This sidesteps the stdlib's reentrant Mutex
on `std::io::Stdin` / `Stdout` / `Stderr` — critical for fork
safety; a parent thread holding those Mutexes at fork time would
leave the child with a dead lock.

```scheme
(:wat::kernel::fork-with-forms
  (forms :Vec<wat::WatAST>)
  -> :wat::kernel::ForkedChild)
```

Allocates three pipe pairs (stdin, stdout, stderr), calls
`libc::fork(2)`, redirects the child's fd 0 / 1 / 2 via `dup2`,
closes every other inherited fd in the child, constructs wat-
level stdio over the redirected fds using `PipeReader` /
`PipeWriter`, runs `startup_from_forms(forms, None, InMemoryLoader)`
+ `validate_user_main_signature` + `invoke_user_main` inside
`std::panic::catch_unwind`, exits via `libc::_exit` with a code
per the EXIT_* convention (below). Parent receives the
`ForkedChild` struct holding the child's handle + three parent-
side pipe ends.

Critical: the child inherits the parent's loaded runtime via
COW — including the caller's `Vec<WatAST>` already in memory.
No re-parse, no tempfile, no binary reload. The child simply
builds its own `FrozenWorld` from the inherited AST.

```scheme
(:wat::kernel::wait-child
  (handle :wat::kernel::ChildHandle)
  -> :i64)
```

Blocking `waitpid(pid, &status, 0)` + exit-code extraction via
`WEXITSTATUS` (normal exit) or `128 + WTERMSIG` (signal
termination — shell convention; readable as a normal `:i64`
alongside EXIT_* codes without a separate discriminator).
Idempotent via `OnceLock<i64>` cached on `ChildHandleInner`;
repeat calls return the cached value. Matches Rust
`Child::try_wait` semantics.

### Structs

`:wat::kernel::ForkedChild` — four fields; auto-generated `/new`
+ per-field accessors land at freeze via wat-rs's
`register_struct_methods`:

```scheme
(:wat::core::struct :wat::kernel::ForkedChild
  (handle :wat::kernel::ChildHandle)
  (stdin  :wat::io::IOWriter)    ;; parent writes → child stdin
  (stdout :wat::io::IOReader)    ;; parent reads ← child stdout
  (stderr :wat::io::IOReader))   ;; parent reads ← child stderr
```

`:wat::kernel::ChildHandle` — opaque from wat's POV; holds the
child's pid + `reaped: AtomicBool` + `cached_exit: OnceLock<i64>`.
`Drop` SIGKILLs + reaps via blocking `waitpid` if the caller
never called `wait-child`, keeping zombies out of the process
table.

### Exit-code convention

Five codes, pinned as `pub const i32` in `src/fork.rs` and
imported by the wat-stdlib hermetic for Failure reconstruction:

```
EXIT_SUCCESS         = 0
EXIT_RUNTIME_ERROR   = 1   // RuntimeError from :user::main
EXIT_PANIC           = 2   // panic caught by catch_unwind
EXIT_STARTUP_ERROR   = 3   // parse / check / macro failure
EXIT_MAIN_SIGNATURE  = 4   // :user::main signature mismatch
// Signal termination: 128 + WTERMSIG(status)
```

### Hermetic as wat stdlib

The core deliverable. `:wat::kernel::run-sandboxed-hermetic-ast`
is no longer a Rust-registered primitive. It is a `define` in
`wat/std/hermetic.wat` — roughly:

```scheme
(:wat::core::define
  (:wat::kernel::run-sandboxed-hermetic-ast
    (forms :Vec<wat::WatAST>)
    (stdin :Vec<String>)
    (scope :Option<String>)
    -> :wat::kernel::RunResult)
  ;; :Some scope → Failure (ScopedLoader-through-fork deferred).
  ;; :None scope →
  ;;   let* ((child :ForkedChild) (fork-with-forms forms))
  ;;        ((handle :ChildHandle) (ForkedChild/handle child))
  ;;        (write stdin via ForkedChild/stdin)
  ;;        ((exit-code :i64) (wait-child handle))
  ;;        (drain stdout + stderr via tail-recursive read-line)
  ;;        ((failure :Option<Failure>)
  ;;         (failure-from-exit exit-code stderr-lines))
  ;;   (struct-new :RunResult stdout-lines stderr-lines failure))
  ...)
```

Same keyword path. Same `(forms, stdin, scope)` signature. Same
`:wat::kernel::RunResult` return shape. Every existing caller
(including wat-rs's Console + Cache service tests) works
unchanged. Only the implementation layer moved.

---

## What retired

Four pieces from wat-rs's `src/` tree:

1. **`eval_kernel_run_sandboxed_hermetic_ast`** (sandbox.rs,
   arc 011) — replaced by the wat stdlib define above.
2. **`eval_kernel_run_sandboxed_hermetic`** (sandbox.rs, arc
   007) — the string-entry variant. Retired without replacement.
   Callers with raw source text parse at the Rust boundary or,
   when a wat-level caller demands one, a future
   `:wat::core::parse` primitive + thin stdlib wrapper. No
   demand has surfaced.
3. **`run_hermetic_core`** + helpers (`expect_option_string`,
   `split_captured_lines`) — the subprocess-spawning machinery
   both hermetic primitives shared. Zero remaining callers.
4. **`wat_ast_to_source`** + **`wat_ast_program_to_source`**
   (ast.rs, arc 011) — added to bridge AST → source → subprocess.
   Fork retires the bridge entirely; child inherits AST via COW,
   no textual round-trip. Eight serializer unit tests retire
   alongside.

Additional cleanup in the side quest:

5. **`in_signal_subprocess`** Command::spawn path (runtime.rs
   test helper) — migrated to `libc::fork` directly. Last
   `Command::spawn` in `src/`.

After this arc, `grep -rn "std::process::Command\|Command::new\|
Command::spawn\|process::exit"` on wat-rs `src/` returns zero
actual uses. The fork substrate is the single source of
subprocess truth for the language implementation.

---

## Fork-safety discipline

Documented in arc 012 DESIGN.md. Four rules the child branch
honors:

1. **No `std::io::stdin/stdout/stderr`.** Those wrap reentrant
   Mutexes inherited from the parent. Child constructs its own
   `PipeReader(fd0)` / `PipeWriter(fd1)` / `PipeWriter(fd2)`
   over the dup2'd fds, using direct `libc::read/write`.
2. **Zero-Mutex runtime.** wat-rs's existing discipline
   (ZERO-MUTEX.md) already ensures `SymbolTable`, `TypeEnv`,
   `MacroRegistry`, `EncodingCtx` all use `Arc<T>` of immutable
   post-freeze data. No Mutex anywhere in the runtime paths
   the child touches.
3. **Close inherited fds.** Child iterates `/proc/self/fd`
   (Linux) or `/dev/fd` (macOS), collects fds > 2, lets the
   iterator drop cleanly, then closes the collected fds. First-
   pass attempted to close mid-iteration; glibc's `closedir`
   panicked with EBADF because the iterator's own fd was in the
   listing. The honest pattern is: iterator-under-teardown is
   not safe to mutate; collect first, close after.
4. **`libc::_exit`, not `std::process::exit`.** _exit skips
   atexit handlers that the parent registered (cargo's test
   harness, etc.) and is async-signal-safe.

---

## Why this matters

Three prior arcs factored ceremony into substrate:

- **Arc 009** — names are values. Registered defines' keyword
  paths lift to callable `Value::wat__core__lambda`.
- **Arc 010** — forms are values. `:wat::core::forms` captures
  N unevaluated forms into a `Vec<WatAST>`.
- **Arc 011** — hermetic is AST-entry. Stringified inner
  programs retired; the subprocess still required the binary's
  path on disk.

Arc 012 closes the last structural coupling those arcs didn't
touch: **hermetic no longer requires the wat binary's path.**
Three substrate primitives + arc 008's IO traits + arc 010's
`program` macro + arc 009's name-as-value convention + existing
`struct-new` + existing `string::split` = ~50 lines of wat
stdlib that replace ~80 lines of purpose-built Rust plus its
tempfile / current-exe / Command::spawn machinery.

The fork primitives are now in the kernel tier alongside `spawn`
/ `send` / `recv` / `select` / `drop` / `join` / `HandlePool`.
They compose cleanly: any future subprocess-like use case
(daemon parallelism, replay runners, test-per-process harnesses)
has the building blocks at the wat level — no re-invention, no
binary coupling.

---

## What this proposal does NOT add

Deferred — named explicitly so future readers see the
non-scope as principled rather than omitted:

- **Windows support.** Fork doesn't exist there. wat-rs is
  Unix-only.
- **`spawn-process` fork+exec primitive.** Calling external
  binaries via argv + args is a different shape (exec replaces
  the process image; fork-with-forms keeps it). Its own arc
  when a caller demands.
- **`:wat::core::parse`.** Needed for a wat-level
  `run-sandboxed-hermetic` (string-entry) rewrite. No caller.
- **Concurrent drain of child stdout vs stderr.** The wat-stdlib
  hermetic serializes wait-child → drain-stdout → drain-stderr.
  Works when child output fits in pipe buffers (~64KB+). A
  child writing more to one stream blocks. No caller has hit
  the limit.
- **Force-close of the parent's stdin writer.** Child sees EOF
  on stdin only when the outer `ForkedChild` binding drops.
  Children that read-stdin-to-EOF as a prerequisite to further
  work would deadlock. No caller has hit this.
- **Scope-through-fork (`ScopedLoader` in the child).**
  `:Some scope` still returns Failure. Wiring is its own slice.
- **`:wat::kernel::kill-child` + `try-wait-child`.** Scope-
  based reaping via `ChildHandle::Drop` covers misuse. Non-
  blocking wait future if needed.

---

## Status

INSCRIPTION — shipped 2026-04-21 across wat-rs commits `000bbb0`
(docs open) through `b2d8faa` (arc close). Nine core commits.
Net line delta in wat-rs's `src/`: net code shrinkage (-356
lines in the retirement commit alone; arc net +433 counting
new primitives). Fork substrate lives in `src/fork.rs` +
`src/io.rs` (PipeReader/PipeWriter additions); wat-stdlib
hermetic lives in `wat/std/hermetic.wat`.

Full test matrix green:
- 518 Rust unit tests
- 25+ Rust integration test groups (every `tests/*.rs`)
- 31 wat-level tests via `wat test wat-tests/`

Zero regressions across every commit.

**Signature:** *these are very good thoughts.* **PERSEVERARE.**
