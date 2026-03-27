# Visual Grid Fixes — Queued

## Problem

The visual encoding is a 3D grid: (x=column/time, y=row, color), with panels
folded into the y-axis (rows 0-24 = price+vol, 25-49 = RSI, 50-74 = MACD,
75-99 = DMI). Two structural issues in how we decompose and represent this grid.

## Fix 1: Position Vector Collision

Row and column position vectors both come from `vm.get_position_vector(i)`,
which is seeded by `__pos__{i}`. For indices 0-47, row and column positions
are **identical vectors**:

```
row_pos[5] = get_position_vector(5)   // seeded "__pos__5"
col_pos[5] = get_position_vector(5)   // seeded "__pos__5"  ← same vector
```

**Fix**: Offset column positions by `total_rows` (100) so the two axes
occupy non-overlapping index ranges:

```rust
// In VisualCache::new()
let col_positions: Vec<Vector> = (0..n_cols)
    .map(|ci| vm.get_position_vector((total_rows + ci) as i64))
    .collect();
```

Row positions use indices 0-99, column positions use 100-147. No collision.
One-line change in `viewport.rs`.

## Fix 2: Column-Aware Discriminative Decomposition

The decomposition in `Journaler::recalibrate()` correctly unbinds each column
position from the prototype, then inverts against the (row, color) codebook.
But it then **aggregates by taking max similarity across all 48 columns**,
discarding which column (time position) the atom appeared in.

Result: we know "r42-gs is buy-discriminative" but NOT that it appeared in
column 47 (the newest candle). The discriminative prototype is built from
(y, color) atoms only — the full (x, y, color) input structure is not matched.

**Fix**: Key atom maps by `(column_index, atom_index)` instead of just
`atom_index`, and rebind the column position when constructing the
discriminative prototype:

```rust
// Instead of:
atom_buy_sims.entry(idx).or_insert(0.0);  // keyed by atom only

// Do:
atom_buy_sims.insert((ci, idx), sim);     // keyed by (column, atom)

// When building disc prototype, rebind column:
// full_atom = bind(col_pos[ci], codebook_atom[idx])
for (d, (&c, &a)) in disc.iter_mut().zip(col_pos_data.iter().zip(atom_data.iter())) {
    *d += ((c as f64) * (a as f64)) * diff;
}
```

This preserves the full (x, y, color) structure in the discriminative
prototype so `dot(input, disc_proto)` matches on WHERE + WHAT.

Change is in `Journaler::recalibrate()` in `trader.rs`.

## Impact

Both fixes are visual-system only. Thought encoding has no grid, unaffected.
Both require a fresh run (position vectors change the encoding).
