//! Cache — generic key-value store with LRU eviction. A program, not a service.
//! Composed of queues and a mailbox from core services.
//! Each program gets its OWN handles (contention-free).
//! Gets are request-response pairs. Sets are fire-and-forget
//! into a shared mailbox.

use std::hash::Hash;
use std::num::NonZeroUsize;
use std::thread;

use lru::LruCache;

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
/// No Drop impl on the handle — drop order is unspecified, so joining
/// in Drop would deadlock if senders are still alive. The cascade IS
/// the shutdown guarantee: senders drop → driver drains → driver exits.
/// Call join() explicitly when you need to wait for the driver to finish.
pub fn cache<K, V>(
    name: &str, // the cache's identity — used for diagnostics and logging
    capacity: usize,
    num_clients: usize,
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
                        let _ = alive_resp_txs[i].send(result);
                    }
                    Err(crossbeam::channel::TryRecvError::Empty) => {}
                    Err(crossbeam::channel::TryRecvError::Disconnected) => {
                        closed[i] = true;
                    }
                }
            }

            // Exit when all get clients disconnected AND sets are done.
            if all_closed && !set_alive {
                break;
            }
            if all_closed {
                // No get clients left but sets still alive — just drain sets.
                match set_rx.recv() {
                    Ok((key, value)) => { cache.put(key, value); }
                    Err(_) => break,
                }
                continue;
            }

            // Phase 3: block until ANY channel has data.
            // ready() wakes without consuming — next iteration picks up.
            let mut sel = crossbeam::channel::Select::new();
            for i in 0..alive_get_rxs.len() {
                if !closed[i] {
                    sel.recv(alive_get_rxs[i].inner());
                }
            }
            if set_alive {
                sel.recv(set_rx.inner());
            }
            let _ = sel.ready();
        }
    });

    (
        handles,
        CacheDriverHandle {
            name: name.to_string(),
            thread: Some(thread),
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
        let (handles, _driver) = cache::<String, String>("test", 16, 1);
        let h = &handles[0];
        assert_eq!(h.get(&"missing".to_string()), None);
    }

    #[test]
    fn set_then_get_returns_some() {
        let (handles, _driver) = cache::<String, i32>("test", 16, 1);
        let h = &handles[0];
        h.set("key".to_string(), 42);
        // Give the set a moment to propagate through the mailbox.
        thread::sleep(Duration::from_millis(50));
        assert_eq!(h.get(&"key".to_string()), Some(42));
    }

    #[test]
    fn multiple_clients_independent() {
        let (handles, _driver) = cache::<String, i32>("test", 64, 3);

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
        let (handles, _driver) = cache::<i32, i32>("test", 2, 1);
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
        let (handles, driver) = cache::<i32, i32>("test", 16, 2);

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
        let (handles, _driver) = cache::<String, i32>("test", 16, 2);
        let mut iter = handles.into_iter();
        let writer = iter.next().unwrap();
        let reader = iter.next().unwrap();

        writer.set("shared".to_string(), 99);
        thread::sleep(Duration::from_millis(50));
        assert_eq!(reader.get(&"shared".to_string()), Some(99));
    }
}
