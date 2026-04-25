# Lab arc 024 — polymorphic arithmetic sweep — BACKLOG

**Shape:** two slices. Sweep + INSCRIPTION/changelog.

---

## Slice 1 — sed sweep + cargo test

**Status: ready** (wat-rs arc 050 already shipped).

```bash
find wat/ wat-tests/ -name "*.wat" -exec sed -i \
  -e 's|:wat::core::f64::+|:wat::core::+|g' \
  -e 's|:wat::core::f64::-|:wat::core::-|g' \
  -e 's|:wat::core::f64::\*|:wat::core::*|g' \
  -e 's|:wat::core::f64::/|:wat::core::/|g' \
  -e 's|:wat::core::i64::+|:wat::core::+|g' \
  -e 's|:wat::core::i64::-|:wat::core::-|g' \
  -e 's|:wat::core::i64::\*|:wat::core::*|g' \
  -e 's|:wat::core::i64::/|:wat::core::/|g' \
  {} \;
```

Then `cargo test --release --test test`. Expected: all 149
tests green.

**Sub-fogs:**
- (none.)

## Slice 2 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slice 1 lands).

- `docs/arc/2026/04/024-polymorphic-arithmetic-sweep/INSCRIPTION.md` —
  scope, mechanics, per-tree breakdown, what stays typed.
- `docs/proposals/.../FOUNDATION-CHANGELOG.md` — row.
- Lab repo commit + push.

**Sub-fogs:**
- (none.)
