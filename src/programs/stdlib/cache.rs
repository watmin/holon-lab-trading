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
    Get { client: usize, key: K },
    BatchGet { client: usize, keys: Vec<K> },
    Set { key: K, value: V },
    BatchSet { entries: Vec<(K, V)> },
}

/// Typed cache response. The client unwraps the variant it expects.
enum CacheResponse<V> {
    Get(Option<V>),
    BatchGet(Vec<Option<V>>),
}

/// A program's handle to the cache. Each program gets its own.
/// Not cloneable — one per program.
pub struct CacheHandle<K, V> {
    client_idx: usize,
    req_tx: QueueSender<CacheRequest<K, V>>,
    resp_rx: QueueReceiver<CacheResponse<V>>,
}

impl<K: Clone + Send, V: Send> CacheHandle<K, V> {
    /// Synchronous get: send key, block for response.
    /// Returns None on miss or if the driver has shut down.
    pub fn get(&self, key: &K) -> Option<V> {
        self.req_tx.send(CacheRequest::Get {
            client: self.client_idx,
            key: key.clone(),
        }).ok()?;
        match self.resp_rx.recv().ok()? {
            CacheResponse::Get(v) => v,
            _ => None,
        }
    }

    /// Synchronous batch get: send keys, block for responses.
    /// Returns positional Vec<Option<V>> — caller matches to its input.
    /// One round-trip. The driver does N hash lookups.
    pub fn batch_get(&self, keys: Vec<K>) -> Option<Vec<Option<V>>> {
        self.req_tx.send(CacheRequest::BatchGet {
            client: self.client_idx,
            keys,
        }).ok()?;
        match self.resp_rx.recv().ok()? {
            CacheResponse::BatchGet(v) => Some(v),
            _ => None,
        }
    }

    /// Fire-and-forget set.
    pub fn set(&self, key: K, value: V) {
        let _ = self.req_tx.send(CacheRequest::Set { key, value });
    }

    /// Fire-and-forget batch set.
    pub fn batch_set(&self, entries: Vec<(K, V)>) {
        if !entries.is_empty() {
            let _ = self.req_tx.send(CacheRequest::BatchSet { entries });
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
        let (req_tx, req_rx) = queue::queue_unbounded::<CacheRequest<K, V>>();
        let (resp_tx, resp_rx) = queue::queue_unbounded::<CacheResponse<V>>();
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
    // Epoll-style: drain all pending requests, batch service, respond.
    let thread = thread::spawn(move || {
        let mut cache = LruCache::new(NonZeroUsize::new(capacity).unwrap());
        let mut stats = CacheStats::default();
        let mut closed = vec![false; num_clients];
        let mut batch: Vec<CacheRequest<K, V>> = Vec::new();

        loop {
            // Block until at least one queue has data.
            // select() across all live client queues.
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

            // Drain ALL pending requests from ALL queues.
            batch.clear();
            for i in 0..num_clients {
                if closed[i] { continue; }
                loop {
                    match req_rxs[i].try_recv() {
                        Ok(req) => batch.push(req),
                        Err(crossbeam::channel::TryRecvError::Empty) => break,
                        Err(crossbeam::channel::TryRecvError::Disconnected) => {
                            closed[i] = true;
                            break;
                        }
                    }
                }
            }

            if batch.is_empty() { continue; }

            // Partition: writes first, then reads.
            // Swap writes to the front so reads see fresh data.
            let mut write_end = 0;
            for i in 0..batch.len() {
                match &batch[i] {
                    CacheRequest::Set { .. } | CacheRequest::BatchSet { .. } => {
                        batch.swap(write_end, i);
                        write_end += 1;
                    }
                    _ => {}
                }
            }

            // Service writes.
            let t0 = std::time::Instant::now();
            for req in batch.drain(..write_end) {
                match req {
                    CacheRequest::Set { key, value } => {
                        let at_cap = cache.len() == capacity;
                        cache.put(key, value);
                        if at_cap { stats.evictions += 1; }
                        stats.sets_drained += 1;
                    }
                    CacheRequest::BatchSet { entries } => {
                        for (key, value) in entries {
                            let at_cap = cache.len() == capacity;
                            cache.put(key, value);
                            if at_cap { stats.evictions += 1; }
                            stats.sets_drained += 1;
                        }
                    }
                    _ => unreachable!(),
                }
            }
            stats.ns_sets += t0.elapsed().as_nanos() as u64;

            // Service reads.
            let t0 = std::time::Instant::now();
            for req in batch.drain(..) {
                match req {
                    CacheRequest::Get { client, key } => {
                        let result = cache.get(&key).cloned();
                        if result.is_some() {
                            hits_inner.fetch_add(1, Ordering::Relaxed);
                            stats.hits += 1;
                        } else {
                            misses_inner.fetch_add(1, Ordering::Relaxed);
                            stats.misses += 1;
                        }
                        let _ = resp_txs[client].send(CacheResponse::Get(result));
                        stats.gets_serviced += 1;
                    }
                    CacheRequest::BatchGet { client, keys } => {
                        let results: Vec<Option<V>> = keys.iter().map(|key| {
                            let result = cache.get(key).cloned();
                            if result.is_some() {
                                hits_inner.fetch_add(1, Ordering::Relaxed);
                                stats.hits += 1;
                            } else {
                                misses_inner.fetch_add(1, Ordering::Relaxed);
                                stats.misses += 1;
                            }
                            result
                        }).collect();
                        stats.gets_serviced += results.len();
                        let _ = resp_txs[client].send(CacheResponse::BatchGet(results));
                    }
                    _ => {} // writes already drained
                }
            }
            stats.ns_gets += t0.elapsed().as_nanos() as u64;

            // Gate check after each batch.
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
    use std::time::Duration;

    #[test]
    fn get_returns_none_on_miss() {
        let (handles, _driver) = cache::<String, String>("test", 16, 1, Box::new(|| true), Box::new(|_| {}));
        let h = &handles[0];
        assert_eq!(h.get(&"missing".to_string()), None);
    }

    #[test]
    fn set_then_get_returns_some() {
        let (handles, _driver) = cache::<String, i32>("test", 16, 1, Box::new(|| true), Box::new(|_| {}));
        let h = &handles[0];
        h.set("key".to_string(), 42);
        // Give the set a moment to propagate.
        thread::sleep(Duration::from_millis(50));
        assert_eq!(h.get(&"key".to_string()), Some(42));
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
        let (handles, _driver) = cache::<i32, i32>("test", 2, 1, Box::new(|| true), Box::new(|_| {}));
        let h = &handles[0];

        h.set(1, 10);
        h.set(2, 20);
        thread::sleep(Duration::from_millis(50));

        assert_eq!(h.get(&1), Some(10));
        assert_eq!(h.get(&2), Some(20));

        h.set(3, 30);
        thread::sleep(Duration::from_millis(50));

        assert_eq!(h.get(&1), None);
        assert_eq!(h.get(&2), Some(20));
        assert_eq!(h.get(&3), Some(30));
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

        writer.set("shared".to_string(), 99);
        thread::sleep(Duration::from_millis(50));
        assert_eq!(reader.get(&"shared".to_string()), Some(99));
    }

    #[test]
    fn batch_get_returns_positional() {
        let (handles, _driver) = cache::<String, i32>("test", 16, 1, Box::new(|| true), Box::new(|_| {}));
        let h = &handles[0];

        h.set("a".to_string(), 1);
        h.set("b".to_string(), 2);
        thread::sleep(Duration::from_millis(50));

        let results = h.batch_get(vec![
            "a".to_string(),
            "missing".to_string(),
            "b".to_string(),
        ]).unwrap();

        assert_eq!(results.len(), 3);
        assert_eq!(results[0], Some(1));
        assert_eq!(results[1], None);
        assert_eq!(results[2], Some(2));
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
        thread::sleep(Duration::from_millis(50));

        assert_eq!(h.get(&"x".to_string()), Some(10));
        assert_eq!(h.get(&"y".to_string()), Some(20));
        assert_eq!(h.get(&"z".to_string()), Some(30));
    }
}
