#!/usr/bin/env python
"""raster_poc.py — Proof of concept: raster scan encoding with manual vector composition.

Each pixel = bind(col_pos, row_pos, color_set_or_null)
Full viewport = bundle of all pixel bindings (including nulls)
"""

import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))
from holon import DeterministicVectorManager
from holon.kernel.primitives import cosine_similarity, bind, prototype

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
DIM = 4096
vm = DeterministicVectorManager(dimensions=DIM)

# Color atoms
COLORS = ["gs", "rs", "gw", "rw", "dj", "yl", "rl", "gl", "wu", "wl",
          "vg", "vr", "rb", "ro", "rn", "ml", "ms", "mhg", "mhr"]
NULL = "null"

def get_atom(name: str) -> np.ndarray:
    return vm.get_vector(name)

def get_col_pos(col: int) -> np.ndarray:
    return vm.get_position_vector(col)

def get_row_pos(row: int) -> np.ndarray:
    return vm.get_position_vector(10000 + row)  # offset to avoid collision with col positions

# ---------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------
def encode_color_set(colors: set) -> np.ndarray:
    """Bundle color atoms into a set vector."""
    if not colors:
        return get_atom(NULL)
    vecs = [get_atom(c) for c in colors]
    if len(vecs) == 1:
        return vecs[0]
    bundled = np.sum(np.stack(vecs), axis=0)
    return np.sign(bundled).astype(np.int8)

def encode_pixel(col: int, row: int, colors: set | None) -> np.ndarray:
    """Encode a single pixel: bind(col_pos, row_pos, content)."""
    content = encode_color_set(colors) if colors else get_atom(NULL)
    return bind(bind(get_col_pos(col), get_row_pos(row)), content)

def encode_viewport(grid: dict, n_cols: int, n_rows: int) -> np.ndarray:
    """Encode full viewport. grid = {(col, row): {colors}} for occupied cells."""
    pixel_vecs = []
    for c in range(n_cols):
        for r in range(n_rows):
            colors = grid.get((c, r))
            pixel_vecs.append(encode_pixel(c, r, colors))
    bundled = np.sum(np.stack(pixel_vecs), axis=0)
    return np.sign(bundled).astype(np.int8)

def unbind_pixel(viewport_vec: np.ndarray, col: int, row: int) -> np.ndarray:
    """Probe what's at (col, row) by unbinding position."""
    pos = bind(get_col_pos(col), get_row_pos(row))
    return bind(viewport_vec, pos)  # bind is self-inverse for bipolar

def identify_content(probed: np.ndarray) -> list:
    """Find which atoms the probed vector is most similar to."""
    results = []
    for name in COLORS + [NULL]:
        sim = cosine_similarity(probed, get_atom(name))
        results.append((name, float(sim)))
    results.sort(key=lambda x: -x[1])
    return results

# ---------------------------------------------------------------------------
# Test 1: Roundtrip — can we recover what's at a specific pixel?
# ---------------------------------------------------------------------------
print("=" * 60)
print("TEST 1: Roundtrip Recovery")
print("=" * 60)

N_COLS, N_ROWS = 10, 10  # tiny 10x10 grid

grid = {
    (2, 3): {"gs"},           # green solid body
    (2, 4): {"gs", "yl"},     # green body + SMA20 overlap
    (2, 5): {"gs"},
    (5, 2): {"rs"},           # red solid body
    (5, 3): {"rs"},
    (5, 7): {"yl"},           # SMA20 line
    (7, 1): {"gw"},           # green wick
    (7, 2): {"gs"},
    (7, 3): {"gs"},
    (7, 4): {"gw"},           # green wick
}

t0 = time.time()
vp = encode_viewport(grid, N_COLS, N_ROWS)
enc_time = time.time() - t0

print(f"  Grid: {N_COLS}x{N_ROWS} = {N_COLS*N_ROWS} pixels, {len(grid)} occupied")
print(f"  Encode time: {enc_time*1000:.1f}ms")
print(f"  Total bindings: {N_COLS * N_ROWS} (including {N_COLS*N_ROWS - len(grid)} nulls)")
print()

# Probe occupied positions
for (c, r), colors in sorted(grid.items()):
    probed = unbind_pixel(vp, c, r)
    top3 = identify_content(probed)[:3]
    expected = ", ".join(sorted(colors))
    recovered = top3[0][0]
    match = "OK" if recovered in colors or (len(colors) > 1 and top3[0][1] > 0.1) else "MISS"
    print(f"  ({c},{r}) expected={{{expected}:>8s}} → top: {top3[0][0]}={top3[0][1]:.3f}, "
          f"{top3[1][0]}={top3[1][1]:.3f}, {top3[2][0]}={top3[2][1]:.3f}  [{match}]")

# Probe empty position
probed_empty = unbind_pixel(vp, 0, 0)
top3 = identify_content(probed_empty)[:3]
print(f"  (0,0) expected={{null}}       → top: {top3[0][0]}={top3[0][1]:.3f}, "
      f"{top3[1][0]}={top3[1][1]:.3f}  [{'OK' if top3[0][0] == NULL else 'MISS'}]")

# ---------------------------------------------------------------------------
# Test 2: Similarity — do similar charts produce similar vectors?
# ---------------------------------------------------------------------------
print(f"\n{'=' * 60}")
print("TEST 2: Similarity Between Charts")
print("=" * 60)

# Chart A: uptrend (green candles moving up)
chart_a = {}
for c in range(10):
    body_top = 8 - c  # moves up
    for r in range(body_top, body_top + 2):
        chart_a[(c, r)] = {"gs"}

# Chart B: also uptrend but shifted slightly
chart_b = {}
for c in range(10):
    body_top = 7 - c  # similar uptrend, slightly different level
    for r in range(body_top, body_top + 2):
        chart_b[(c, r)] = {"gs"}

# Chart C: downtrend (red candles moving down)
chart_c = {}
for c in range(10):
    body_top = 1 + c  # moves down
    for r in range(body_top, body_top + 2):
        chart_c[(c, r)] = {"rs"}

va = encode_viewport(chart_a, 10, 10)
vb = encode_viewport(chart_b, 10, 10)
vc = encode_viewport(chart_c, 10, 10)

sim_ab = cosine_similarity(va, vb)
sim_ac = cosine_similarity(va, vc)
sim_bc = cosine_similarity(vb, vc)

print(f"  Uptrend A vs Uptrend B (similar):  {sim_ab:.4f}")
print(f"  Uptrend A vs Downtrend C (opposite): {sim_ac:.4f}")
print(f"  Uptrend B vs Downtrend C (opposite): {sim_bc:.4f}")
print(f"  Separation (same-class vs cross): {sim_ab - max(sim_ac, sim_bc):.4f}")

# ---------------------------------------------------------------------------
# Test 3: Scale test — realistic viewport size
# ---------------------------------------------------------------------------
print(f"\n{'=' * 60}")
print("TEST 3: Scale — Realistic Viewport")
print("=" * 60)

for n_cols, n_rows, n_occupied in [(48, 50, 500), (48, 50, 2000), (48, 25, 300), (24, 25, 200)]:
    total = n_cols * n_rows
    np.random.seed(42)
    occ_indices = np.random.choice(total, n_occupied, replace=False)
    grid = {}
    for idx in occ_indices:
        c, r = divmod(idx, n_rows)
        n_colors = np.random.choice([1, 2], p=[0.8, 0.2])
        colors = set(np.random.choice(COLORS, n_colors, replace=False))
        grid[(c, r)] = colors

    t0 = time.time()
    vp = encode_viewport(grid, n_cols, n_rows)
    elapsed = time.time() - t0

    # Quick roundtrip check on first occupied pixel
    first_pos = sorted(grid.keys())[0]
    probed = unbind_pixel(vp, *first_pos)
    top = identify_content(probed)
    recovered = top[0][0] in grid[first_pos]

    print(f"  {n_cols}x{n_rows} ({total} px, {n_occupied} occupied, "
          f"{total - n_occupied} null): {elapsed*1000:.0f}ms, "
          f"roundtrip={'OK' if recovered else 'MISS'} (sim={top[0][1]:.3f})")

# ---------------------------------------------------------------------------
# Test 4: Capacity — does null encoding help or hurt?
# ---------------------------------------------------------------------------
print(f"\n{'=' * 60}")
print("TEST 4: With vs Without Null Encoding")
print("=" * 60)

def encode_viewport_sparse(grid: dict, n_cols: int, n_rows: int) -> np.ndarray:
    """Encode only occupied cells (no nulls for empty space)."""
    if not grid:
        return np.zeros(DIM, dtype=np.int8)
    pixel_vecs = []
    for (c, r), colors in grid.items():
        pixel_vecs.append(encode_pixel(c, r, colors))
    bundled = np.sum(np.stack(pixel_vecs), axis=0)
    return np.sign(bundled).astype(np.int8)

# Same uptrend charts
va_full = encode_viewport(chart_a, 10, 10)     # with nulls (100 bindings)
va_sparse = encode_viewport_sparse(chart_a, 10, 10)  # without nulls (20 bindings)
vb_full = encode_viewport(chart_b, 10, 10)
vb_sparse = encode_viewport_sparse(chart_b, 10, 10)
vc_full = encode_viewport(chart_c, 10, 10)
vc_sparse = encode_viewport_sparse(chart_c, 10, 10)

print(f"  WITH nulls (100 bindings each):")
print(f"    Uptrend A vs B: {cosine_similarity(va_full, vb_full):.4f}")
print(f"    Uptrend A vs Downtrend C: {cosine_similarity(va_full, vc_full):.4f}")

print(f"  WITHOUT nulls (20 bindings each):")
print(f"    Uptrend A vs B: {cosine_similarity(va_sparse, vb_sparse):.4f}")
print(f"    Uptrend A vs Downtrend C: {cosine_similarity(va_sparse, vc_sparse):.4f}")

# Roundtrip comparison
for label, vp, n_bind in [("full", va_full, 100), ("sparse", va_sparse, 20)]:
    probed = unbind_pixel(vp, 2, 8)  # chart_a has gs at (2,8)
    top = identify_content(probed)
    print(f"  {label:>6s} ({n_bind} bindings) probe (2,8)={{gs}}: "
          f"top={top[0][0]}={top[0][1]:.3f}")

# ---------------------------------------------------------------------------
# Test 5: Engram Library — cluster similar charts, classify by nearest engram
# ---------------------------------------------------------------------------
print(f"\n{'=' * 60}")
print("TEST 5: Engram Library (Cluster, Don't Average)")
print("=" * 60)

class EngramLibrary:
    """Simple nearest-engram library with online clustering."""

    def __init__(self, merge_threshold: float = 0.4):
        self.engrams = []       # list of (label, vec, count)
        self.merge_threshold = merge_threshold

    def add(self, label: str, vec: np.ndarray):
        best_sim = -1.0
        best_idx = -1
        for i, (lbl, evec, cnt) in enumerate(self.engrams):
            if lbl != label:
                continue
            sim = float(cosine_similarity(vec, evec))
            if sim > best_sim:
                best_sim = sim
                best_idx = i

        if best_sim >= self.merge_threshold and best_idx >= 0:
            lbl, evec, cnt = self.engrams[best_idx]
            # incremental prototype update
            updated = (evec.astype(np.float64) * cnt + vec.astype(np.float64)) / (cnt + 1)
            self.engrams[best_idx] = (lbl, np.sign(updated).astype(np.int8), cnt + 1)
        else:
            self.engrams.append((label, vec.copy(), 1))

    def classify(self, vec: np.ndarray) -> tuple:
        best_sim = -2.0
        best_label = None
        best_idx = -1
        for i, (lbl, evec, cnt) in enumerate(self.engrams):
            sim = float(cosine_similarity(vec, evec))
            if sim > best_sim:
                best_sim = sim
                best_label = lbl
                best_idx = i
        return best_label, best_sim, best_idx

    def stats(self):
        from collections import Counter
        label_counts = Counter(lbl for lbl, _, _ in self.engrams)
        sizes = [cnt for _, _, cnt in self.engrams]
        return {
            "n_engrams": len(self.engrams),
            "labels": dict(label_counts),
            "size_range": f"{min(sizes)}-{max(sizes)}" if sizes else "0",
        }


# Generate synthetic chart patterns
def make_uptrend(offset=0, steepness=1, color="gs", n_cols=12, n_rows=15):
    grid = {}
    for c in range(n_cols):
        row = max(0, min(n_rows - 2, n_rows - 3 - int(c * steepness) + offset))
        grid[(c, row)] = {color}
        grid[(c, row + 1)] = {color}
    return grid

def make_downtrend(offset=0, steepness=1, color="rs", n_cols=12, n_rows=15):
    grid = {}
    for c in range(n_cols):
        row = max(0, min(n_rows - 2, 1 + int(c * steepness) + offset))
        grid[(c, row)] = {color}
        grid[(c, row + 1)] = {color}
    return grid

def make_flat(level=7, color="dj", n_cols=12, n_rows=15):
    grid = {}
    for c in range(n_cols):
        grid[(c, level)] = {color}
    return grid

def make_vshape(bottom=5, color="gs", n_cols=12, n_rows=15):
    grid = {}
    mid = n_cols // 2
    for c in range(n_cols):
        dist = abs(c - mid)
        row = max(0, min(n_rows - 2, n_rows - 3 - dist + bottom))
        grid[(c, row)] = {color}
        grid[(c, row + 1)] = {color}
    return grid

N_C, N_R = 12, 15
lib = EngramLibrary(merge_threshold=0.35)
np.random.seed(42)

# Training: generate varied patterns
train_data = []
for _ in range(20):
    off = np.random.randint(-2, 3)
    steep = np.random.choice([0.5, 0.8, 1.0, 1.2])
    train_data.append(("BUY", make_uptrend(off, steep, n_cols=N_C, n_rows=N_R)))
    train_data.append(("SELL", make_downtrend(off, steep, n_cols=N_C, n_rows=N_R)))

for _ in range(10):
    lvl = np.random.randint(5, 10)
    train_data.append(("BUY", make_vshape(lvl, n_cols=N_C, n_rows=N_R)))

for _ in range(10):
    lvl = np.random.randint(5, 10)
    train_data.append(("SELL", make_flat(lvl, n_cols=N_C, n_rows=N_R)))

np.random.shuffle(train_data)

for label, grid in train_data:
    vec = encode_viewport(grid, N_C, N_R)
    lib.add(label, vec)

print(f"  Library after training: {lib.stats()}")

# Test: classify new patterns
test_cases = [
    ("BUY",  "steep uptrend",      make_uptrend(1, 1.3, n_cols=N_C, n_rows=N_R)),
    ("BUY",  "gentle uptrend",     make_uptrend(-1, 0.6, n_cols=N_C, n_rows=N_R)),
    ("BUY",  "v-shape recovery",   make_vshape(6, n_cols=N_C, n_rows=N_R)),
    ("SELL", "steep downtrend",    make_downtrend(0, 1.2, n_cols=N_C, n_rows=N_R)),
    ("SELL", "gentle downtrend",   make_downtrend(1, 0.7, n_cols=N_C, n_rows=N_R)),
    ("SELL", "flat/no momentum",   make_flat(8, n_cols=N_C, n_rows=N_R)),
]

correct = 0
for expected, desc, grid in test_cases:
    vec = encode_viewport(grid, N_C, N_R)
    pred, sim, idx = lib.classify(vec)
    ok = pred == expected
    correct += ok
    print(f"  {desc:>20s}  expected={expected} pred={pred} sim={sim:.3f} "
          f"engram#{idx} [{'OK' if ok else 'MISS'}]")

print(f"\n  Accuracy: {correct}/{len(test_cases)} = {correct/len(test_cases)*100:.0f}%")

# Show engram diversity
print(f"\n  Engram breakdown:")
for i, (lbl, evec, cnt) in enumerate(lib.engrams):
    # how similar is this engram to all others of same label?
    same_label = [(j, cosine_similarity(evec, e)) for j, (l, e, _) in enumerate(lib.engrams)
                  if l == lbl and j != i]
    if same_label:
        max_intra = max(s for _, s in same_label)
    else:
        max_intra = 0
    print(f"    #{i:>2d} {lbl} (n={cnt:>2d}) max_intra_sim={max_intra:.3f}")

print(f"\nDone.")
