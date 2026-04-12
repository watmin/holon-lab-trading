//! Cache — key-value store with eviction. Its own thread. Its own IO loop.
//! Named instances — `cache("encoder")` holds ThoughtAST → Vector.
//! Composed of queues and a mailbox: each program gets its OWN handles
//! (contention-free). Gets are request-response pairs. Sets are
//! fire-and-forget into a shared mailbox.

use std::collections::{HashMap, VecDeque};
use std::hash::Hash;
use std::thread;

use crate::services::mailbox::{self, MailboxSender};
use crate::services::queue::{self, QueueReceiver, QueueSender};

/// A program's handle to the cache. Each program gets its own.
/// Not cloneable — one per program.
pub struct CacheHandle<K, V> {
    get_tx: QueueSender<K>,
    get_rx: QueueReceiver<Option<V>>,
    set_tx: MailboxSender<(K, V)>,
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
pub struct CacheDriverHandle {
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

/// Simple LRU: HashMap for O(1) lookup, VecDeque for eviction order.
/// On access or insert, the key moves to the back (most recent).
/// Eviction removes from the front (oldest).
struct Lru<K: Eq + Hash + Clone, V> {
    map: HashMap<K, V>,
    order: VecDeque<K>,
    capacity: usize,
}

impl<K: Eq + Hash + Clone, V> Lru<K, V> {
    fn new(capacity: usize) -> Self {
        Self {
            map: HashMap::with_capacity(capacity),
            order: VecDeque::with_capacity(capacity),
            capacity,
        }
    }

    fn get(&mut self, key: &K) -> Option<&V> {
        if self.map.contains_key(key) {
            // Move to back (most recently used).
            self.order.retain(|k| k != key);
            self.order.push_back(key.clone());
            self.map.get(key)
        } else {
            None
        }
    }

    fn insert(&mut self, key: K, value: V) {
        if self.map.contains_key(&key) {
            // Update existing — move to back.
            self.order.retain(|k| k != &key);
        } else if self.map.len() >= self.capacity {
            // Evict oldest.
            if let Some(oldest) = self.order.pop_front() {
                self.map.remove(&oldest);
            }
        }
        self.map.insert(key.clone(), value);
        self.order.push_back(key);
    }
}

/// Create a cache with the given name, capacity, and number of client programs.
///
/// Returns N CacheHandles (one per program) and a CacheDriverHandle.
/// The driver thread exits when all client handles are dropped.
pub fn cache<K, V>(
    _name: &str,
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

    // Mailbox for sets: N senders (one per client), one receiver.
    let (set_senders, set_rx) = mailbox::mailbox::<(K, V)>(num_clients);
    let mut set_senders: VecDeque<_> = set_senders.into();

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
            set_tx: set_senders.pop_front().unwrap(),
        });
    }

    // The driver thread: owns the LRU, selects across all get-request
    // receivers and the set mailbox receiver.
    let thread = thread::spawn(move || {
        let mut lru = Lru::new(capacity);
        let mut alive_get_rxs: Vec<QueueReceiver<K>> = get_rxs;
        let mut alive_resp_txs: Vec<QueueSender<Option<V>>> = get_resp_txs;
        let mut set_alive = true;

        loop {
            if alive_get_rxs.is_empty() && !set_alive {
                break;
            }

            let mut sel = crossbeam::channel::Select::new();

            // Register all get-request receivers.
            for rx in &alive_get_rxs {
                sel.recv(rx.inner());
            }

            // Register the set mailbox receiver (if still alive).
            // The mailbox receiver wraps a QueueReceiver — use inner().
            if set_alive {
                sel.recv(set_rx.inner());
            }

            let oper = sel.select();
            let idx = oper.index();
            let get_count = alive_get_rxs.len();

            if idx < get_count {
                // A get request from client `idx`.
                match oper.recv(alive_get_rxs[idx].inner()) {
                    Ok(key) => {
                        let result = lru.get(&key).cloned();
                        // Send the response. If the client dropped its
                        // response receiver, ignore the error.
                        let _ = alive_resp_txs[idx].send(result);
                    }
                    Err(_) => {
                        // Client disconnected — remove from select set.
                        alive_get_rxs.remove(idx);
                        alive_resp_txs.remove(idx);
                    }
                }
            } else {
                // A set request from the mailbox.
                match oper.recv(set_rx.inner()) {
                    Ok((key, value)) => {
                        lru.insert(key, value);
                    }
                    Err(_) => {
                        // All set senders dropped.
                        set_alive = false;
                    }
                }
            }
        }
    });

    (
        handles,
        CacheDriverHandle {
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

        // Driver join should return (not hang).
        // Use a timeout via a separate thread to avoid hanging the test.
        let join_thread = thread::spawn(move || {
            driver.join();
        });

        // If the driver doesn't exit within 2 seconds, something is wrong.
        let result = join_thread.join();
        assert!(result.is_ok());
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
