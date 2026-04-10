/// encoder_service.rs — ThoughtEncoder as a single-threaded cache with pipes.
///
/// The encoder holds a cache. It never computes vectors. Callers compute.
///
/// Contract:
///   get(AST) → Option<Vector>   // blocking for caller. Hit or miss.
///   set(AST, Vector) → ()       // fire and forget. Cache learns.
///
/// The encoder is a single-threaded loop with N get pipes + 1 set pipe.
/// crossbeam::select! services whoever is ready. No mutex. No lock.
/// The distributed computation is outside. The cache is inside.

use std::num::NonZeroUsize;
use std::thread::{self, JoinHandle};

use crossbeam::channel::{self, Receiver, Sender};
use crossbeam::select;
use lru::LruCache;

use holon::kernel::vector::Vector;

use crate::thought_encoder::ThoughtAST;

/// A caller's handle to the encoder service. One per thread.
/// Each caller has their OWN get pipe AND their OWN set pipe.
/// No sharing. No contention. The encoder selects over all of them.
pub struct EncoderHandle {
    get_tx: Sender<ThoughtAST>,
    get_rx: Receiver<Option<Vector>>,
    set_tx: Sender<(ThoughtAST, Vector)>,
}

impl EncoderHandle {
    /// Blocking get. Returns Some(Vector) on cache hit, None on miss.
    pub fn get(&self, ast: &ThoughtAST) -> Option<Vector> {
        let _ = self.get_tx.send(ast.clone());
        self.get_rx.recv().unwrap()
    }

    /// Fire and forget. The cache learns. Own pipe — no contention.
    pub fn set(&self, ast: ThoughtAST, vec: Vector) {
        let _ = self.set_tx.send((ast, vec));
    }
}

/// The encoder service. Spawn it, get handles, shut it down.
pub struct EncoderService {
    /// Caller-side senders — drop these to close channels at shutdown
    get_txs: Vec<Sender<ThoughtAST>>,
    set_txs: Vec<Sender<(ThoughtAST, Vector)>>,
    /// The thread
    handle: Option<JoinHandle<()>>,
    /// Stats
    pub hits: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    pub misses: std::sync::Arc<std::sync::atomic::AtomicUsize>,
}

impl EncoderService {
    /// Spawn the encoder thread. Returns the service + N handles (one per caller).
    /// Each caller gets their OWN get pipe AND their OWN set pipe. No sharing.
    pub fn spawn(n_callers: usize, cache_capacity: usize) -> (Self, Vec<EncoderHandle>) {
        let mut handles = Vec::with_capacity(n_callers);
        let mut get_rxs_for_thread: Vec<Receiver<ThoughtAST>> = Vec::new();
        let mut resp_txs_for_thread: Vec<Sender<Option<Vector>>> = Vec::new();
        let mut set_rxs_for_thread: Vec<Receiver<(ThoughtAST, Vector)>> = Vec::new();
        let mut get_txs = Vec::new();
        let mut set_txs = Vec::new();

        for _ in 0..n_callers {
            let (get_tx, get_rx) = channel::bounded::<ThoughtAST>(1);
            let (resp_tx, resp_rx) = channel::bounded::<Option<Vector>>(1);
            let (set_tx, set_rx) = channel::unbounded::<(ThoughtAST, Vector)>();

            handles.push(EncoderHandle {
                get_tx: get_tx.clone(),
                get_rx: resp_rx,
                set_tx: set_tx.clone(),
            });

            get_txs.push(get_tx);
            set_txs.push(set_tx);
            get_rxs_for_thread.push(get_rx);
            resp_txs_for_thread.push(resp_tx);
            set_rxs_for_thread.push(set_rx);
        }

        let hits = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let misses_arc = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let hits_clone = hits.clone();
        let misses_clone = misses_arc.clone();

        let n = n_callers;

        let handle = thread::spawn(move || {
            let mut cache: LruCache<ThoughtAST, Vector> =
                LruCache::new(NonZeroUsize::new(cache_capacity).unwrap());

            loop {
                // Drain ALL set pipes first — make all pending writes visible
                for set_rx in &set_rxs_for_thread {
                    while let Ok((ast, vec)) = set_rx.try_recv() {
                        cache.put(ast, vec);
                    }
                }

                // Select over all get pipes + all set pipes
                // get pipes: indices 0..n
                // set pipes: indices n..2n
                let mut sel = crossbeam::channel::Select::new();
                for rx in &get_rxs_for_thread {
                    sel.recv(rx);
                }
                for rx in &set_rxs_for_thread {
                    sel.recv(rx);
                }

                // Block until any channel is ready
                let oper = sel.select();
                let idx = oper.index();

                if idx < n {
                    // Get operation — check cache, respond
                    match oper.recv(&get_rxs_for_thread[idx]) {
                        Ok(ast) => {
                            let result = cache.get(&ast).cloned();
                            if result.is_some() {
                                hits_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                            } else {
                                misses_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                            }
                            let _ = resp_txs_for_thread[idx].send(result);
                        }
                        Err(_) => {} // Caller closed
                    }
                } else {
                    // Set operation — install into cache
                    let set_idx = idx - n;
                    match oper.recv(&set_rxs_for_thread[set_idx]) {
                        Ok((ast, vec)) => { cache.put(ast, vec); }
                        Err(_) => {} // Caller closed
                    }
                }

                // Shutdown: all get channels disconnected
                let all_closed = get_rxs_for_thread.iter().all(|rx| {
                    matches!(rx.try_recv(), Err(crossbeam::channel::TryRecvError::Disconnected))
                });
                if all_closed { break; }
            }
        });

        (
            EncoderService {
                get_txs,
                set_txs,
                handle: Some(handle),
                hits,
                misses: misses_arc,
            },
            handles,
        )
    }

    /// Shutdown. Drop all senders, join the thread.
    pub fn shutdown(mut self) {
        drop(self.get_txs);
        drop(self.set_txs);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }

    /// Cache hit count.
    pub fn hit_count(&self) -> usize {
        self.hits.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Cache miss count.
    pub fn miss_count(&self) -> usize {
        self.misses.load(std::sync::atomic::Ordering::Relaxed)
    }
}
