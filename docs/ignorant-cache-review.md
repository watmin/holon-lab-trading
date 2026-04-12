# Ignorant Ward — Cache Review (First Pass)

Reviewed: 2026-04-11
Files: `src/services/queue.rs`, `src/services/mailbox.rs`, `src/services/cache.rs`, `src/services/mod.rs`
Ward: /ignorant — reads as a stranger, knows nothing about the project.

---

## Understanding

Reading `cache.rs` cold, after absorbing queue and mailbox:

The module header says: "Gets are request-response pairs. Sets are fire-and-forget into a shared mailbox." This is immediately legible. The structure follows from the primitives: N per-client get-request queues (contention-free), N per-client get-response queues (contention-free, private), one shared mailbox for sets (N senders, one fan-in receiver). The driver thread owns the LRU and selects across all of them.

What confused me:

1. The `set_senders` VecDeque pop — the senders arrive from `mailbox()` in a `Vec`, then get converted to a `VecDeque` for `.pop_front()` during handle construction. This means `handles[0]` gets `set_senders[0]`, `handles[1]` gets `set_senders[1]`, etc. It works, but the conversion to VecDeque exists solely to consume sequentially. A `into_iter()` drain would be cleaner. Minor.

2. The shutdown condition `if alive_get_rxs.is_empty() && !set_alive` — a stranger must reason that this means "all get channels gone AND all set channels gone." This is correct but the asymmetry between the two conditions is not commented. When get receivers drop the driver removes them from `alive_get_rxs` one by one. When the set mailbox sender-side drains, `set_alive` flips to false. The driver exits only when BOTH are exhausted. Why not exit when either one drops? Because clients may still want to set after they stop getting (or vice versa). The intent is reasonable but undocumented.

3. The `_name` parameter is accepted but immediately discarded. The comment says "Named instances — `cache("encoder")` holds ThoughtAST → Vector." The name is part of the intended interface but has no effect. A stranger cannot tell if this is a future placeholder or a mistake.

---

## Soundness

**Bugs:** None found.

**Race conditions:** None structural. Each client has its own get-request sender and its own get-response receiver. The driver is the sole reader of all request channels and the sole writer of all response channels. No two threads read or write the same channel simultaneously.

**Deadlock paths:**

The get protocol is: client sends key on `get_tx`, then blocks on `get_rx.recv()`. The driver receives the key on `alive_get_rxs[idx]` and sends the response on `alive_resp_txs[idx]`. The driver loop is `select()` across all receivers — it WILL eventually reach the get request as long as the loop runs.

Can the driver loop block indefinitely before reaching the get request? Yes, in theory: if the set mailbox fires continuously and gets selected every iteration, the get request starves. In practice, `crossbeam::Select::select()` is fair (pseudo-random order across ready channels), so starvation is extremely unlikely. But it is not guaranteed — there is no priority on get requests. This is not a deadlock but it is a potential liveness issue under high set load. Not a bug for the current use case (encoding cache with infrequent concurrent writers), but worth noting.

Can the `get` call deadlock if the driver never responds? Only if the driver exits before sending the response. The driver exits when `alive_get_rxs.is_empty() && !set_alive`. If a client sends a key and the driver has already removed that client's receiver from `alive_get_rxs` — which happens when that receiver disconnects — the driver will never send a response. But the receiver disconnects only when `get_tx` (the sender) is dropped, and `get_tx` lives in the same `CacheHandle` as `get_rx`. A client cannot drop `get_tx` while still holding `get_rx` because both live in the same struct. So this scenario cannot occur while the client struct is alive.

**Edge case — driver removed the client slot, but the response receiver is still alive:**
When the driver receives `Err(_)` on a get-request channel (line 175), it does `alive_get_rxs.remove(idx)` and `alive_resp_txs.remove(idx)`. After this, the client's `get_rx` is orphaned (no writer). If the client then calls `get_rx.recv()` it will block forever — but only if it had already sent a key on `get_tx`. Since `get_tx` is what caused the `Err(_)` (the sender was dropped), this means the client dropped its sender and called recv on its receiver in a separate step — which is impossible if both live in the same `CacheHandle`. Sound.

**The select miss:** The select indexes into `alive_get_rxs` by position. After a `remove(idx)`, indices shift. The select object is rebuilt on the next loop iteration, so shifted indices are never used stale. Sound.

**Eviction correctness:**

The LRU has two data structures: `HashMap<K, V>` and `VecDeque<K>`. They must stay in sync.

- **Insert new key:** `map.insert(key, value)` and `order.push_back(key)`. Sync.
- **Update existing key:** `order.retain(|k| k != &key)` removes the key from its current position, then `map.insert(key, value)` and `order.push_back(key)` put it at the back. Sync.
- **Evict:** `order.pop_front()` removes the oldest key, `map.remove(&oldest)` removes its value. Sync.

The eviction check is `self.map.len() >= self.capacity`. This fires before inserting the new key when the map is full. At capacity, evict one, then insert — map stays at or under capacity. Correct.

**Access on get:** `get` calls `order.retain(|k| k != key)` then `order.push_back(key.clone())`. This correctly promotes accessed keys to most-recently-used. The `retain` is O(n) — fine for a cache, not fine for large n. Not a bug.

**Duplicate key in `order`:** Can the order deque contain duplicate keys? On insert of an existing key, `retain` removes all occurrences before pushing once. On get, same pattern. No duplicate accumulation. Sound.

---

## Composition

The cache ACTUALLY composes from queues and mailbox. Specifically:

- `mailbox::mailbox::<(K, V)>(num_clients)` — the real mailbox primitive, used for sets.
- `queue::queue_unbounded::<K>()` for get-request channels.
- `queue::queue_unbounded::<Option<V>>()` for get-response channels.
- `set_rx.inner()` and `rx.inner()` — the `pub(crate)` escape hatch defined in queue.rs, used here to pass raw crossbeam receivers into `Select`.

The `inner()` escape hatch is the only way to reach crossbeam from outside the queue/mailbox modules. It is correctly scoped `pub(crate)` — the cache can use it, external code cannot. This is the designed seam.

The cache does not bypass the abstractions. It uses the public API for sends and the `pub(crate)` inner for select registration. Composition is real.

---

## The Get Protocol

**Request-response safety:** The protocol is safe as argued above. One client holds exactly one request sender and one response receiver. The driver routes by index. No cross-client contamination.

**Two programs get the same key simultaneously:** Each client has its own request and response queue. Client A sends key on its `get_tx`, client B sends the same key on its own `get_tx`. The driver handles them sequentially (single-threaded event loop). It performs two LRU lookups, sends two independent responses. Neither client sees the other's response. Safe.

**Program drops its handle mid-get:** The handle owns `get_tx`, `get_rx`, and `set_tx`. All three are in one struct. Rust's ownership model means the handle cannot be partially dropped — you cannot drop `get_tx` while holding `get_rx`. You either hold the whole handle or drop the whole handle. There is no mid-get partial drop. The borrow checker enforces this statically. Safe.

---

## The LRU

**Access order updates on get:** Yes. Line 71–73: `retain` removes the key, `push_back` places it at back. Correct.

**Capacity honored:** Eviction fires when `map.len() >= self.capacity` (line 84). If capacity is 2 and the map has 2 entries, inserting a third triggers eviction first. After evict: map.len() = 1, then insert: map.len() = 2. Never exceeds capacity. Correct.

**Corner case — capacity 1:** Insert A: map = {A}, order = [A]. Insert B: map.len() (1) >= capacity (1), evict front (A), map = {}, then insert B: map = {B}, order = [B]. Correct.

**Corner case — insert same key twice at capacity:** Insert A, insert B (at capacity). Insert A again: map.contains_key(&A) is true → retain removes A from order → `map.insert(A, new_val)` → `push_back(A)`. No eviction fires because the size check is in the `else if` branch. Map stays at capacity. Correct.

---

## Shutdown Cascade

**Drop all handles:** When all `CacheHandle`s drop:
- All `get_tx` senders drop → their channels disconnect → driver's `alive_get_rxs` receivers will return `Err` on next read → driver removes them one by one until `alive_get_rxs.is_empty()`.
- All `set_tx` (mailbox) senders drop → mailbox fan-in thread sees all inputs disconnected → fan-in thread exits → `set_rx` (mailbox output) becomes disconnected → driver's next recv on `set_rx` returns `Err` → `set_alive = false`.

Exit condition `alive_get_rxs.is_empty() && !set_alive` becomes true. Driver exits. `CacheDriverHandle::join()` returns.

**Ordering question:** Can the driver exit before processing all outstanding sets? Yes. If all handles drop simultaneously, there may be unconsumed messages in the set mailbox. The mailbox fan-in thread will forward them to `set_rx`, but if the driver's `alive_get_rxs` empties first AND `set_alive` is still true, the driver does NOT exit — it stays alive waiting on `set_rx`. The driver only exits when BOTH conditions are met. Outstanding sets drain before the driver exits, provided the mailbox fan-in thread processes them. Sound, but dependent on the mailbox fan-in thread running — which it will, since the fan-in thread's lifecycle is governed by its input senders, not the consumer.

**Partial drops (some clients leave):** A client's `get_tx` drops → driver removes that index from `alive_get_rxs` and `alive_resp_txs`. Remaining clients are unaffected. The client's `set_tx` (mailbox sender) drops → the mailbox fan-in thread removes that input. Remaining set senders still work. No impact on surviving clients. Correct.

**One gap:** The shutdown test (line 278) drops all handles, then joins with no timeout. If the driver deadlocks the test hangs. The comment says "use a timeout via a separate thread," but the test does `join_thread.join()` with no timeout — so a hung driver produces a hung test, not a test failure. This is a test weakness, not a code bug.

---

## Tests

**Honest:** Yes. The tests exercise real concurrent behavior, not mocked paths. The 50ms sleeps are genuine waits for async message propagation, not cargo-cult sleeps — the set-then-get pattern requires propagation time because set is fire-and-forget.

**Coverage:**

| Test | What it covers |
|---|---|
| `get_returns_none_on_miss` | Miss path, single client |
| `set_then_get_returns_some` | Basic round trip |
| `multiple_clients_independent` | Isolation between clients |
| `eviction_at_capacity` | LRU eviction, access-order update |
| `shutdown_all_handles_dropped_driver_exits` | Lifecycle |
| `shared_state_across_clients` | One writes, another reads |

**What's missing:**

- **High-frequency set during get:** Does the driver starve get requests under heavy set load? Not tested.
- **Simultaneous get of same key from two clients:** Not tested explicitly.
- **Update existing key:** `eviction_at_capacity` does not test re-inserting an existing key. The `insert` branch for existing keys (retain + reinsert) is untested.
- **Capacity = 1:** Not tested. Corner case with eviction on first insert after initial fill.
- **Partial client drop:** One client drops; remaining clients continue working. Not tested.
- **Driver shutdown with pending sets:** Drop handles while a set is in-flight. The test drops all handles cleanly, not mid-flight.
- **Shutdown timeout:** The shutdown test cannot fail with a timeout — it will hang instead.

---

## Findings

**F1 (documentation gap): `_name` parameter is silently discarded.**

Line 99: `_name: &str`. The module comment says "Named instances — `cache("encoder")` holds ThoughtAST → Vector." A name is part of the intended model. The underscore prefix tells the compiler to suppress the unused warning, which means the author knows it is unused. No comment explains whether this is a future placeholder, a logging hook to be added, or intentional no-op. A stranger cannot tell.

Not a bug. But a stranger who reads the module comment and then looks for where the name is used will find nothing and be confused. The intent should be documented at the parameter.

**F2 (documentation gap): Shutdown exit condition is not commented.**

Lines 145–147:
```rust
if alive_get_rxs.is_empty() && !set_alive {
    break;
}
```

The driver exits only when BOTH all get channels are gone AND the set mailbox is gone. Why not exit when either drops? A stranger must reason this out. One sentence would close the gap: "Exit only when both gets and sets are exhausted — clients may still set after their last get, or vice versa."

**F3 (test gap): Shutdown test has no timeout.**

Lines 285–292: The `join_thread.join()` has no timeout. If the driver deadlocks, this test hangs rather than fails. The comment acknowledges the intent was to guard against hangs, but the implementation does not achieve it.

---

## Finding Count

**3 findings.** None are structural bugs or race conditions. Two are documentation gaps. One is a test weakness.

| Finding | Severity | Type |
|---|---|---|
| F1: `_name` undocumented | Low | Documentation gap |
| F2: Shutdown condition undocumented | Low | Documentation gap |
| F3: Shutdown test has no timeout | Low | Test weakness |

The cache is sound. The LRU is correct. The get protocol cannot deadlock. The composition is real. The shutdown cascade works.
