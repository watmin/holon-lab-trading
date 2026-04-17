//! Cache — generic key-value store with LRU eviction. A program, not a service.
//! One request queue per client. The driver polls all queues directly —
//! no mailbox, no fan-in thread. Batched dispatch: drain all pending
//! requests, service writes, service reads, respond to all at once.
//! Clients block on response. They all wake together.

use std::hash::Hash;
use std::num::NonZeroUsize;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;

use lru::LruCache;

use crate::services::queue::{self, QueueReceiver, QueueSender};

/// Typed cache request. Carries the client index so the driver
/// knows which response channel to use.
enum CacheRequest<K, V> {
    BatchGet { client: usize, keys: Vec<K> },
    BatchSet { client: usize, entries: Vec<(K, V)> },
}

/// Typed cache response. The client unwraps the variant it expects.
enum CacheResponse<K, V> {
    BatchGet(Vec<(K, Option<V>)>),
    BatchSetAck,
}

/// A program's handle to the cache. Each program gets its own.
/// Not cloneable — one per program.
pub struct CacheHandle<K, V> {
    client_idx: usize,
    req_tx: QueueSender<CacheRequest<K, V>>,
    resp_rx: QueueReceiver<CacheResponse<K, V>>,
}

impl<K: Clone + Send, V: Send> CacheHandle<K, V> {
    /// Synchronous batch get: send keys, block for responses.
    /// Returns Vec<(K, Option<V>)> — the driver pairs each key with its
    /// lookup result so the caller doesn't need to keep a copy of the
    /// input keys. One round-trip. The driver does N hash lookups.
    pub fn batch_get(&self, keys: Vec<K>) -> Option<Vec<(K, Option<V>)>> {
        self.req_tx.send(CacheRequest::BatchGet {
            client: self.client_idx,
            keys,
        }).ok()?;
        match self.resp_rx.recv().ok()? {
            CacheResponse::BatchGet(v) => Some(v),
            _ => None,
        }
    }

    /// Confirmed batch set. Blocks until the driver has processed all entries.
    pub fn batch_set(&self, entries: Vec<(K, V)>) {
        if !entries.is_empty() {
            let _ = self.req_tx.send(CacheRequest::BatchSet {
                client: self.client_idx,
                entries,
            });
            let _ = self.resp_rx.recv(); // block until ack
        }
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

/// Cache telemetry emitted through the gate pattern.
#[derive(Clone, Debug, Default)]
pub struct CacheStats {
    pub hits: usize,
    pub misses: usize,
    pub cache_size: usize,
    pub ns_gets: u64,
    pub ns_sets: u64,
    pub gets_serviced: usize,
    pub sets_drained: usize,
    pub evictions: usize,
}

/// Create a cache with the given capacity and number of client programs.
///
/// Returns N CacheHandles (one per program) and a CacheDriverHandle.
/// The driver thread exits when all client handles are dropped.
///
/// The driver polls client queues directly — no mailbox, no fan-in.
/// Batched dispatch: drain all pending requests from all clients,
/// service writes first (freshest data for reads), then service reads,
/// respond to all. Clients wake together, compute in parallel.
pub fn cache<K, V>(
    name: &str,
    capacity: usize,
    num_clients: usize,
    can_emit: Box<dyn Fn() -> bool + Send>,
    emit: Box<dyn Fn(CacheStats) + Send>,
) -> (Vec<CacheHandle<K, V>>, CacheDriverHandle)
where
    K: Send + Clone + Hash + Eq + 'static,
    V: Send + Clone + 'static,
{
    assert!(num_clients > 0, "cache requires at least one client");
    assert!(capacity > 0, "cache requires non-zero capacity");

    let mut handles = Vec::with_capacity(num_clients);
    let mut req_rxs = Vec::with_capacity(num_clients);
    let mut resp_txs = Vec::with_capacity(num_clients);

    for i in 0..num_clients {
        let (req_tx, req_rx) = queue::queue_bounded::<CacheRequest<K, V>>(1);
        let (resp_tx, resp_rx) = queue::queue_bounded::<CacheResponse<K, V>>(1);
        req_rxs.push(req_rx);
        resp_txs.push(resp_tx);
        handles.push(CacheHandle {
            client_idx: i,
            req_tx,
            resp_rx,
        });
    }

    let hits = Arc::new(AtomicUsize::new(0));
    let misses = Arc::new(AtomicUsize::new(0));
    let hits_inner = Arc::clone(&hits);
    let misses_inner = Arc::clone(&misses);

    // The driver thread: owns the LRU, polls client queues directly.
    // Select wakes us. Drain every pending request. Writes first, reads
    // second. Respond inline. Loop.
    let thread = thread::spawn(move || {
        let mut cache = LruCache::new(NonZeroUsize::new(capacity).unwrap());
        let mut stats = CacheStats::default();
        let mut closed = vec![false; num_clients];

        // Pending requests grouped by type. Reused across iterations.
        let mut writes: Vec<CacheRequest<K, V>> = Vec::new();
        let mut reads: Vec<CacheRequest<K, V>> = Vec::new();

        loop {
            // Block until at least one queue has data.
            let mut sel = crossbeam::channel::Select::new();
            let mut has_live = false;
            for i in 0..num_clients {
                sel.recv(req_rxs[i].inner());
                if !closed[i] { has_live = true; }
            }
            if !has_live {
                if stats.hits > 0 || stats.misses > 0 || stats.sets_drained > 0 {
                    stats.cache_size = cache.len();
                    emit(stats.clone());
                }
                break;
            }
            let _ = sel.ready();

            // Drain every pending request, grouped by type.
            writes.clear();
            reads.clear();
            for i in 0..num_clients {
                if closed[i] { continue; }
                loop {
                    match req_rxs[i].try_recv() {
                        Ok(req) => match &req {
                            CacheRequest::BatchSet { .. } => writes.push(req),
                            _ => reads.push(req),
                        },
                        Err(crossbeam::channel::TryRecvError::Empty) => break,
                        Err(crossbeam::channel::TryRecvError::Disconnected) => {
                            closed[i] = true;
                            break;
                        }
                    }
                }
            }

            // Process writes. Reads see fresh data.
            let t0 = std::time::Instant::now();
            for req in writes.drain(..) {
                match req {
                    CacheRequest::BatchSet { client, entries } => {
                        for (key, value) in entries {
                            let at_cap = cache.len() == capacity;
                            cache.put(key, value);
                            if at_cap { stats.evictions += 1; }
                            stats.sets_drained += 1;
                        }
                        let _ = resp_txs[client].send(CacheResponse::BatchSetAck);
                    }
                    _ => unreachable!(),
                }
            }
            stats.ns_sets += t0.elapsed().as_nanos() as u64;

            // Process reads.
            let t0 = std::time::Instant::now();
            for req in reads.drain(..) {
                match req {
                    CacheRequest::BatchGet { client, keys } => {
                        // Move keys into the response paired with results —
                        // the caller gets back (key, Option<value>) pairs
                        // without needing to keep a copy of the input.
                        let mut batch_hits = 0usize;
                        let mut batch_misses = 0usize;
                        let results: Vec<(K, Option<V>)> = keys.into_iter().map(|key| {
                            let result = cache.get(&key).cloned();
                            if result.is_some() {
                                batch_hits += 1;
                            } else {
                                batch_misses += 1;
                            }
                            (key, result)
                        }).collect();
                        // One atomic per batch, not one per key.
                        if batch_hits > 0 { hits_inner.fetch_add(batch_hits, Ordering::Relaxed); }
                        if batch_misses > 0 { misses_inner.fetch_add(batch_misses, Ordering::Relaxed); }
                        stats.hits += batch_hits;
                        stats.misses += batch_misses;
                        stats.gets_serviced += results.len();
                        let _ = resp_txs[client].send(CacheResponse::BatchGet(results));
                    }
                    _ => {}
                }
            }
            stats.ns_gets += t0.elapsed().as_nanos() as u64;

            // Gate check.
            if can_emit() {
                stats.cache_size = cache.len();
                emit(stats.clone());
                stats = CacheStats::default();
            }
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

    /// Test helper: single-key lookup via batch_get.
    fn get_one<K: Clone + Send + std::hash::Hash + Eq + 'static, V: Send + Clone + 'static>(
        h: &CacheHandle<K, V>,
        key: K,
    ) -> Option<V> {
        h.batch_get(vec![key]).and_then(|mut v| v.pop()).and_then(|(_, value)| value)
    }

    #[test]
    fn get_returns_none_on_miss() {
        let (handles, _driver) = cache::<String, String>("test", 16, 1, Box::new(|| true), Box::new(|_| {}));
        let h = &handles[0];
        assert_eq!(get_one(h, "missing".to_string()), None);
    }

    #[test]
    fn set_then_get_returns_some() {
        let (handles, _driver) = cache::<String, i32>("test", 16, 1, Box::new(|| true), Box::new(|_| {}));
        let h = &handles[0];
        h.batch_set(vec![("key".to_string(), 42)]);
        assert_eq!(get_one(h, "key".to_string()), Some(42));
    }

    #[test]
    fn multiple_clients_independent() {
        let (handles, _driver) = cache::<String, i32>("test", 64, 3, Box::new(|| true), Box::new(|_| {}));

        let threads: Vec<_> = handles
            .into_iter()
            .enumerate()
            .map(|(i, h)| {
                thread::spawn(move || {
                    let key = format!("client-{}", i);
                    let value = i as i32 * 100;
                    h.batch_set(vec![(key.clone(), value)]);
                    assert_eq!(get_one(&h, key.clone()), Some(value));
                })
            })
            .collect();

        for t in threads {
            t.join().unwrap();
        }
    }

    #[test]
    fn eviction_at_capacity() {
        let (handles, _driver) = cache::<i32, i32>("test", 2, 1, Box::new(|| true), Box::new(|_| {}));
        let h = &handles[0];

        h.batch_set(vec![(1, 10)]);
        h.batch_set(vec![(2, 20)]);

        assert_eq!(get_one(h, 1), Some(10));
        assert_eq!(get_one(h, 2), Some(20));

        h.batch_set(vec![(3, 30)]);

        assert_eq!(get_one(h, 1), None);
        assert_eq!(get_one(h, 2), Some(20));
        assert_eq!(get_one(h, 3), Some(30));
    }

    #[test]
    fn shutdown_all_handles_dropped_driver_exits() {
        let (handles, driver) = cache::<i32, i32>("test", 16, 2, Box::new(|| true), Box::new(|_| {}));
        drop(handles);
        driver.join();
    }

    #[test]
    fn shared_state_across_clients() {
        let (handles, _driver) = cache::<String, i32>("test", 16, 2, Box::new(|| true), Box::new(|_| {}));
        let mut iter = handles.into_iter();
        let writer = iter.next().unwrap();
        let reader = iter.next().unwrap();

        writer.batch_set(vec![("shared".to_string(), 99)]);
        assert_eq!(get_one(&reader, "shared".to_string()), Some(99));
    }

    #[test]
    fn batch_get_returns_positional() {
        let (handles, _driver) = cache::<String, i32>("test", 16, 1, Box::new(|| true), Box::new(|_| {}));
        let h = &handles[0];

        h.batch_set(vec![("a".to_string(), 1), ("b".to_string(), 2)]);

        let results = h.batch_get(vec![
            "a".to_string(),
            "missing".to_string(),
            "b".to_string(),
        ]).unwrap();

        assert_eq!(results.len(), 3);
        assert_eq!(results[0].0, "a");
        assert_eq!(results[0].1, Some(1));
        assert_eq!(results[1].0, "missing");
        assert_eq!(results[1].1, None);
        assert_eq!(results[2].0, "b");
        assert_eq!(results[2].1, Some(2));
    }

    #[test]
    fn batch_set_installs_all() {
        let (handles, _driver) = cache::<String, i32>("test", 16, 1, Box::new(|| true), Box::new(|_| {}));
        let h = &handles[0];

        h.batch_set(vec![
            ("x".to_string(), 10),
            ("y".to_string(), 20),
            ("z".to_string(), 30),
        ]);

        assert_eq!(get_one(h, "x".to_string()), Some(10));
        assert_eq!(get_one(h, "y".to_string()), Some(20));
        assert_eq!(get_one(h, "z".to_string()), Some(30));
    }
}
