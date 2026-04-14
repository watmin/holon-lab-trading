//! Cache — generic key-value store with LRU eviction. A program, not a service.
//! Composed of queues and a mailbox from core services.
//! Each program gets its OWN handles (contention-free).
//! Gets are request-response pairs. Sets are fire-and-forget
//! into a shared mailbox.
//!
//! The encoding cache is a specialization: each handle owns a CLONE of the
//! ThoughtEncoder. On miss, encoding happens LOCALLY on the caller's thread.
//! The cache thread only manages the LRU — gets and sets, no computation.
//! Programs encode through `EncodingCacheHandle::encode()` — opaque,
//! hit or miss invisible. The ThoughtEncoder is never accessible to programs.

use std::hash::Hash;
use std::num::NonZeroUsize;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;

use holon::kernel::vector::Vector;
use lru::LruCache;

use crate::encoding::thought_encoder::{ThoughtAST, ThoughtEncoder};
use crate::services::mailbox;
use crate::services::queue::{self, QueueReceiver, QueueSender};

/// A program's handle to the cache. Each program gets its own.
/// Not cloneable — one per program.
pub struct CacheHandle<K, V> {
    get_tx: QueueSender<K>,
    get_rx: QueueReceiver<Option<V>>,
    set_tx: QueueSender<(K, V)>,
}

impl<K: Clone + Send, V: Send> CacheHandle<K, V> {
    /// Synchronous get: send key, block for response.
    /// Returns None on miss or if the driver has shut down.
    pub fn get(&self, key: &K) -> Option<V> {
        self.get_tx.send(key.clone()).ok()?;
        self.get_rx.recv().ok()?
    }

    /// Fire-and-forget set: send (key, value) into the shared mailbox.
    pub fn set(&self, key: K, value: V) {
        let _ = self.set_tx.send((key, value));
    }
}

/// Handle to the cache driver thread for lifecycle management.
///
/// No Drop impl — drop order is unspecified, so joining in Drop
/// would deadlock if senders are still alive. The cascade IS the
/// shutdown guarantee: senders drop → driver drains → driver exits.
/// Call join() explicitly when you need to wait for the driver.
pub struct CacheDriverHandle {
    #[allow(dead_code)]
    name: String,
    thread: Option<thread::JoinHandle<()>>,
    /// Total cache hits since startup. Read at shutdown for telemetry.
    pub hits: Arc<AtomicUsize>,
    /// Total cache misses since startup. Read at shutdown for telemetry.
    pub misses: Arc<AtomicUsize>,
}

impl CacheDriverHandle {
    /// Block until the driver thread exits. The driver exits when
    /// all client handles are dropped.
    pub fn join(mut self) {
        if let Some(h) = self.thread.take() {
            let _ = h.join();
        }
    }
}


/// Create a cache with the given capacity and number of client programs.
///
/// Returns N CacheHandles (one per program) and a CacheDriverHandle.
/// The driver thread exits when all client handles are dropped.
///
/// Telemetry uses the gate pattern: the driver accumulates hit/miss
/// counters and checks `can_emit` after each get. When the gate opens,
/// it calls `emit(hits, misses, cache_size)` and resets. On disconnect,
/// emits remainder unconditionally.
///
/// No Drop impl on the handle — drop order is unspecified, so joining
/// in Drop would deadlock if senders are still alive. The cascade IS
/// the shutdown guarantee: senders drop → driver drains → driver exits.
/// Call join() explicitly when you need to wait for the driver to finish.
pub fn cache<K, V>(
    name: &str, // the cache's identity — used for diagnostics and logging
    capacity: usize,
    num_clients: usize,
    can_emit: Box<dyn Fn() -> bool + Send>,
    emit: Box<dyn Fn(usize, usize, usize) + Send>,
) -> (Vec<CacheHandle<K, V>>, CacheDriverHandle)
where
    K: Send + Clone + Hash + Eq + 'static,
    V: Send + Clone + 'static,
{
    assert!(num_clients > 0, "cache requires at least one client");
    assert!(capacity > 0, "cache requires non-zero capacity");

    // Per-client get queues: each client gets its own request/response pair.
    let mut handles = Vec::with_capacity(num_clients);
    let mut get_rxs = Vec::with_capacity(num_clients);
    let mut get_resp_txs = Vec::with_capacity(num_clients);

    // Create set queues: one per client. Mailbox gets the receivers.
    let mut set_senders = Vec::with_capacity(num_clients);
    let mut set_rxs = Vec::with_capacity(num_clients);
    for _ in 0..num_clients {
        let (tx, rx) = queue::queue_unbounded::<(K, V)>();
        set_senders.push(tx);
        set_rxs.push(rx);
    }
    let set_rx = mailbox::mailbox(set_rxs);
    let mut set_senders = set_senders.into_iter();

    for _ in 0..num_clients {
        // Get request queue: client sends key.
        let (req_tx, req_rx) = queue::queue_unbounded::<K>();
        // Get response queue: driver sends Option<V>.
        let (resp_tx, resp_rx) = queue::queue_unbounded::<Option<V>>();

        get_rxs.push(req_rx);
        get_resp_txs.push(resp_tx);

        handles.push(CacheHandle {
            get_tx: req_tx,
            get_rx: resp_rx,
            set_tx: set_senders.next().unwrap(),
        });
    }

    let hits = Arc::new(AtomicUsize::new(0));
    let misses = Arc::new(AtomicUsize::new(0));
    let hits_inner = Arc::clone(&hits);
    let misses_inner = Arc::clone(&misses);

    // Telemetry: gate + emit. Both mandatory.

    // The driver thread: owns the LRU. Drain sets FIRST, then service gets.
    // This ordering is critical: market observers install via set (async),
    // exit observers query via get (sync). If gets are serviced before sets
    // are drained, the exit observer misses what the market observer just
    // installed. 0% hit rate. Full encode on every query. OOM.
    let thread = thread::spawn(move || {
        let mut cache = LruCache::new(NonZeroUsize::new(capacity).unwrap());
        let alive_get_rxs: Vec<QueueReceiver<K>> = get_rxs;
        let alive_resp_txs: Vec<QueueSender<Option<V>>> = get_resp_txs;
        let mut set_alive = true;
        let mut closed = vec![false; alive_get_rxs.len()];

        // Telemetry accumulators — reset after each emission.
        let mut period_hits: usize = 0;
        let mut period_misses: usize = 0;

        loop {
            // Phase 1: drain ALL pending sets.
            if set_alive {
                loop {
                    match set_rx.try_recv() {
                        Ok((key, value)) => { cache.put(key, value); }
                        Err(crossbeam::channel::TryRecvError::Empty) => break,
                        Err(crossbeam::channel::TryRecvError::Disconnected) => {
                            set_alive = false;
                            break;
                        }
                    }
                }
            }

            // Phase 2: service ALL pending gets.
            let mut all_closed = true;
            for i in 0..alive_get_rxs.len() {
                if closed[i] { continue; }
                all_closed = false;
                match alive_get_rxs[i].try_recv() {
                    Ok(key) => {
                        let result = cache.get(&key).cloned();
                        if result.is_some() {
                            hits_inner.fetch_add(1, Ordering::Relaxed);
                            period_hits += 1;
                        } else {
                            misses_inner.fetch_add(1, Ordering::Relaxed);
                            period_misses += 1;
                        }
                        let _ = alive_resp_txs[i].send(result);
                    }
                    Err(crossbeam::channel::TryRecvError::Empty) => {}
                    Err(crossbeam::channel::TryRecvError::Disconnected) => {
                        closed[i] = true;
                    }
                }
            }

            // Gate check after servicing gets.
            if can_emit() {
                let cache_size = cache.len();
                emit(period_hits, period_misses, cache_size);
                period_hits = 0;
                period_misses = 0;
            }

            // Exit when all get clients disconnected AND sets are done.
            if all_closed && !set_alive {
                // Emit remainder unconditionally — no gate check.
                if period_hits > 0 || period_misses > 0 {
                    let cache_size = cache.len();
                    emit(period_hits, period_misses, cache_size);
                }
                break;
            }
            if all_closed {
                // No get clients left but sets still alive — just drain sets.
                match set_rx.recv() {
                    Ok((key, value)) => { cache.put(key, value); }
                    Err(_) => {
                        // Emit remainder on this exit path too.
                        if period_hits > 0 || period_misses > 0 {
                            let cache_size = cache.len();
                            emit(period_hits, period_misses, cache_size);
                        }
                        break;
                    }
                }
                continue;
            }

            // Phase 3: block until ANY channel has data.
            // ready() wakes without consuming — next iteration picks up.
            let mut sel = crossbeam::channel::Select::new();
            let mut has_ops = false;
            for i in 0..alive_get_rxs.len() {
                if !closed[i] {
                    sel.recv(alive_get_rxs[i].inner());
                    has_ops = true;
                }
            }
            if set_alive {
                sel.recv(set_rx.inner());
                has_ops = true;
            }
            if !has_ops {
                // Emit remainder on this exit path too.
                if period_hits > 0 || period_misses > 0 {
                    let cache_size = cache.len();
                    emit(period_hits, period_misses, cache_size);
                }
                break; // all channels gone between phases
            }
            let _ = sel.ready();
        }
    });

    (
        handles,
        CacheDriverHandle {
            name: name.to_string(),
            thread: Some(thread),
            hits,
            misses,
        },
    )
}

// ─── Encoding cache ─────────────────────────────────────────────────────────
// Specialization: each handle owns a CLONE of the ThoughtEncoder.
// On cache miss, encoding happens LOCALLY on the caller's thread (parallel).
// The cache thread only manages the LRU — gets and sets, no computation.

/// A program's handle to the encoding cache. Each program gets its own.
/// Not cloneable — one per program.
/// The ONLY way to encode a ThoughtAST into a Vector.
pub struct EncodingCacheHandle {
    get_tx: QueueSender<ThoughtAST>,
    get_rx: QueueReceiver<Option<Vector>>,
    set_tx: QueueSender<(ThoughtAST, Vector)>,
    encoder: ThoughtEncoder, // LOCAL clone — computation happens here
}

impl EncodingCacheHandle {
    /// Encode an AST. Hit or miss is invisible to the caller.
    /// On hit: returns cached vector from the LRU (via the cache thread).
    /// On miss: encodes LOCALLY on the caller's thread, then notifies
    /// the cache thread to install the result (fire-and-forget).
    pub fn encode(&self, ast: &ThoughtAST) -> Option<Vector> {
        // 1. Check cache
        self.get_tx.send(ast.clone()).ok()?;
        if let Some(cached) = self.get_rx.recv().ok()? {
            return Some(cached); // hit
        }
        // 2. Miss — encode locally (on caller's thread)
        let (vec, misses) = self.encoder.encode(ast);
        // 3. Notify cache — fire and forget
        let _ = self.set_tx.send((ast.clone(), vec.clone()));
        for (sub_ast, sub_vec) in misses {
            let _ = self.set_tx.send((sub_ast, sub_vec));
        }
        Some(vec)
    }
}

/// Create an encoding cache. The ThoughtEncoder is CONSUMED — cloned into
/// each handle. No program can reference it directly. Programs encode
/// through `EncodingCacheHandle::encode()`.
///
/// The cache thread owns ONLY the LRU. It services gets (check LRU, respond
/// Some or None) and sets (install into LRU). It does NOT encode.
///
/// Returns N EncodingCacheHandles (one per program) and a CacheDriverHandle.
/// The driver thread exits when all client handles are dropped.
pub fn encoding_cache(
    name: &str,
    encoder: ThoughtEncoder, // CONSUMED — cloned into handles
    capacity: usize,
    num_clients: usize,
    can_emit: Box<dyn Fn() -> bool + Send>,
    emit: Box<dyn Fn(usize, usize, usize) + Send>,
) -> (Vec<EncodingCacheHandle>, CacheDriverHandle) {
    assert!(num_clients > 0, "cache requires at least one client");
    assert!(capacity > 0, "cache requires non-zero capacity");

    let mut handles = Vec::with_capacity(num_clients);
    let mut get_rxs = Vec::with_capacity(num_clients);
    let mut get_resp_txs = Vec::with_capacity(num_clients);

    // Create set queues: one per client. Mailbox gets the receivers.
    let mut set_senders = Vec::with_capacity(num_clients);
    let mut set_rxs = Vec::with_capacity(num_clients);
    for _ in 0..num_clients {
        let (tx, rx) = queue::queue_unbounded::<(ThoughtAST, Vector)>();
        set_senders.push(tx);
        set_rxs.push(rx);
    }
    let set_rx = mailbox::mailbox(set_rxs);
    let mut set_senders = set_senders.into_iter();

    for _ in 0..num_clients {
        // Get request queue: client sends key.
        let (req_tx, req_rx) = queue::queue_unbounded::<ThoughtAST>();
        // Get response queue: driver sends Option<Vector>.
        let (resp_tx, resp_rx) = queue::queue_unbounded::<Option<Vector>>();

        get_rxs.push(req_rx);
        get_resp_txs.push(resp_tx);

        handles.push(EncodingCacheHandle {
            get_tx: req_tx,
            get_rx: resp_rx,
            set_tx: set_senders.next().unwrap(),
            encoder: encoder.clone(), // each handle gets a clone
        });
    }

    let hits = Arc::new(AtomicUsize::new(0));
    let misses = Arc::new(AtomicUsize::new(0));
    let hits_inner = Arc::clone(&hits);
    let misses_inner = Arc::clone(&misses);

    // The driver thread: owns the LRU. Drain sets FIRST, then service gets.
    // This ordering is critical: callers install via set (async after local encode),
    // then query via get (sync). If gets are serviced before sets are drained,
    // we miss what was just installed. 0% hit rate.
    let thread = thread::spawn(move || {
        let mut cache = LruCache::new(NonZeroUsize::new(capacity).unwrap());
        let mut closed = vec![false; get_rxs.len()];
        let mut set_alive = true;

        let mut period_hits: usize = 0;
        let mut period_misses: usize = 0;

        loop {
            // Phase 1: drain ALL pending sets.
            if set_alive {
                loop {
                    match set_rx.try_recv() {
                        Ok((key, value)) => { cache.put(key, value); }
                        Err(crossbeam::channel::TryRecvError::Empty) => break,
                        Err(crossbeam::channel::TryRecvError::Disconnected) => {
                            set_alive = false;
                            break;
                        }
                    }
                }
            }

            // Phase 2: service ALL pending gets.
            let mut all_closed = true;
            for i in 0..get_rxs.len() {
                if closed[i] { continue; }
                all_closed = false;
                match get_rxs[i].try_recv() {
                    Ok(key) => {
                        let result = cache.get(&key).cloned();
                        if result.is_some() {
                            hits_inner.fetch_add(1, Ordering::Relaxed);
                            period_hits += 1;
                        } else {
                            misses_inner.fetch_add(1, Ordering::Relaxed);
                            period_misses += 1;
                        }
                        let _ = get_resp_txs[i].send(result);
                    }
                    Err(crossbeam::channel::TryRecvError::Empty) => {}
                    Err(crossbeam::channel::TryRecvError::Disconnected) => {
                        closed[i] = true;
                    }
                }
            }

            // Gate check after servicing gets.
            if can_emit() {
                let cache_size = cache.len();
                emit(period_hits, period_misses, cache_size);
                period_hits = 0;
                period_misses = 0;
            }

            // Exit when all get clients disconnected AND sets are done.
            if all_closed && !set_alive {
                if period_hits > 0 || period_misses > 0 {
                    let cache_size = cache.len();
                    emit(period_hits, period_misses, cache_size);
                }
                break;
            }
            if all_closed {
                // No get clients left but sets still alive — just drain sets.
                match set_rx.recv() {
                    Ok((key, value)) => { cache.put(key, value); }
                    Err(_) => {
                        if period_hits > 0 || period_misses > 0 {
                            let cache_size = cache.len();
                            emit(period_hits, period_misses, cache_size);
                        }
                        break;
                    }
                }
                continue;
            }

            // Phase 3: block until ANY channel has data.
            // ready() wakes without consuming — next iteration picks up.
            let mut sel = crossbeam::channel::Select::new();
            let mut has_ops = false;
            for i in 0..get_rxs.len() {
                if !closed[i] {
                    sel.recv(get_rxs[i].inner());
                    has_ops = true;
                }
            }
            if set_alive {
                sel.recv(set_rx.inner());
                has_ops = true;
            }
            if !has_ops {
                if period_hits > 0 || period_misses > 0 {
                    let cache_size = cache.len();
                    emit(period_hits, period_misses, cache_size);
                }
                break; // all channels gone between phases
            }
            let _ = sel.ready();
        }
    });

    (
        handles,
        CacheDriverHandle {
            name: name.to_string(),
            thread: Some(thread),
            hits,
            misses,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn get_returns_none_on_miss() {
        let (handles, _driver) = cache::<String, String>("test", 16, 1, Box::new(|| true), Box::new(|_, _, _| {}));
        let h = &handles[0];
        assert_eq!(h.get(&"missing".to_string()), None);
    }

    #[test]
    fn set_then_get_returns_some() {
        let (handles, _driver) = cache::<String, i32>("test", 16, 1, Box::new(|| true), Box::new(|_, _, _| {}));
        let h = &handles[0];
        h.set("key".to_string(), 42);
        // Give the set a moment to propagate through the mailbox.
        thread::sleep(Duration::from_millis(50));
        assert_eq!(h.get(&"key".to_string()), Some(42));
    }

    #[test]
    fn multiple_clients_independent() {
        let (handles, _driver) = cache::<String, i32>("test", 64, 3, Box::new(|| true), Box::new(|_, _, _| {}));

        // Each client sets and gets its own key.
        let threads: Vec<_> = handles
            .into_iter()
            .enumerate()
            .map(|(i, h)| {
                thread::spawn(move || {
                    let key = format!("client-{}", i);
                    let value = i as i32 * 100;
                    h.set(key.clone(), value);
                    thread::sleep(Duration::from_millis(50));
                    assert_eq!(h.get(&key), Some(value));
                })
            })
            .collect();

        for t in threads {
            t.join().unwrap();
        }
    }

    #[test]
    fn eviction_at_capacity() {
        let (handles, _driver) = cache::<i32, i32>("test", 2, 1, Box::new(|| true), Box::new(|_, _, _| {}));
        let h = &handles[0];

        h.set(1, 10);
        h.set(2, 20);
        thread::sleep(Duration::from_millis(50));

        // Both present.
        assert_eq!(h.get(&1), Some(10));
        assert_eq!(h.get(&2), Some(20));

        // Insert a third — should evict the oldest.
        // Key 1 was accessed most recently (by the get above), key 2 next.
        // After the gets: order is [2, 1] (2 was gotten first, then 1).
        // Wait: get(&1) moves 1 to back, get(&2) moves 2 to back.
        // So order is [1, 2]. Eviction removes front = 1.
        h.set(3, 30);
        thread::sleep(Duration::from_millis(50));

        assert_eq!(h.get(&1), None);
        assert_eq!(h.get(&2), Some(20));
        assert_eq!(h.get(&3), Some(30));
    }

    #[test]
    fn shutdown_all_handles_dropped_driver_exits() {
        let (handles, driver) = cache::<i32, i32>("test", 16, 2, Box::new(|| true), Box::new(|_, _, _| {}));

        // Drop all handles — driver should exit.
        drop(handles);

        // Driver join should return immediately — the cascade is
        // pressure-driven. Drop closes handles. The driver sees
        // disconnected. The driver exits. Join returns. If it
        // hangs, the test hangs — that IS the failure signal.
        driver.join();
    }

    #[test]
    fn shared_state_across_clients() {
        // One client sets, another client can read.
        let (handles, _driver) = cache::<String, i32>("test", 16, 2, Box::new(|| true), Box::new(|_, _, _| {}));
        let mut iter = handles.into_iter();
        let writer = iter.next().unwrap();
        let reader = iter.next().unwrap();

        writer.set("shared".to_string(), 99);
        thread::sleep(Duration::from_millis(50));
        assert_eq!(reader.get(&"shared".to_string()), Some(99));
    }
}
