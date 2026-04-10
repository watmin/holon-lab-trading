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
/// The caller sends ASTs, receives Option<Vector>.
#[derive(Clone)]
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

    /// Fire and forget. The cache learns.
    pub fn set(&self, ast: ThoughtAST, vec: Vector) {
        let _ = self.set_tx.send((ast, vec));
    }
}

/// The encoder service. Spawn it, get handles, shut it down.
pub struct EncoderService {
    /// Shared set channel sender — cloned into each handle
    set_tx: Sender<(ThoughtAST, Vector)>,
    /// All get request receivers — the encoder thread reads from these
    /// (stored here so we can drop them at shutdown)
    get_txs: Vec<Sender<ThoughtAST>>,
    /// The thread
    handle: Option<JoinHandle<()>>,
    /// Stats
    pub hits: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    pub misses: std::sync::Arc<std::sync::atomic::AtomicUsize>,
}

impl EncoderService {
    /// Spawn the encoder thread. Returns the service + N handles (one per caller).
    pub fn spawn(n_callers: usize, cache_capacity: usize) -> (Self, Vec<EncoderHandle>) {
        let (set_tx, set_rx) = channel::unbounded::<(ThoughtAST, Vector)>();

        let mut handles = Vec::with_capacity(n_callers);
        let mut get_rxs_for_thread: Vec<Receiver<ThoughtAST>> = Vec::new();
        let mut resp_txs_for_thread: Vec<Sender<Option<Vector>>> = Vec::new();
        let mut get_txs = Vec::new();

        for _ in 0..n_callers {
            let (get_tx, get_rx) = channel::bounded::<ThoughtAST>(1); // bounded(1) — lock step
            let (resp_tx, resp_rx) = channel::bounded::<Option<Vector>>(1);

            handles.push(EncoderHandle {
                get_tx: get_tx.clone(),
                get_rx: resp_rx,
                set_tx: set_tx.clone(),
            });

            get_txs.push(get_tx);
            get_rxs_for_thread.push(get_rx);
            resp_txs_for_thread.push(resp_tx);
        }

        let hits = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let misses_arc = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let hits_clone = hits.clone();
        let misses_clone = misses_arc.clone();

        let handle = thread::spawn(move || {
            let mut cache: LruCache<ThoughtAST, Vector> =
                LruCache::new(NonZeroUsize::new(cache_capacity).unwrap());

            loop {
                // Drain ALL pending sets first — make them available for gets
                loop {
                    match set_rx.try_recv() {
                        Ok((ast, vec)) => { cache.put(ast, vec); }
                        Err(_) => break,
                    }
                }

                // Build the select dynamically over all get channels + set channel
                // We use crossbeam::select! macro but it needs static arms.
                // For dynamic N, we use crossbeam::Select directly.
                let mut sel = crossbeam::channel::Select::new();

                // Register all get receivers
                for rx in &get_rxs_for_thread {
                    sel.recv(rx);
                }
                // Register the set receiver as the last one
                let set_idx = sel.recv(&set_rx);

                // Block until any channel is ready
                let oper = sel.select();
                let idx = oper.index();

                if idx == set_idx {
                    // Set operation — install into cache
                    if let Ok((ast, vec)) = oper.recv(&set_rx) {
                        cache.put(ast, vec);
                    } else {
                        // Set channel closed — continue servicing gets
                    }
                } else if idx < get_rxs_for_thread.len() {
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
                        Err(_) => {
                            // This caller's channel closed — they're done
                        }
                    }
                }

                // Check if all get channels are disconnected — shutdown
                let all_closed = get_rxs_for_thread.iter().all(|rx| rx.is_empty() && {
                    // Peek to see if disconnected
                    matches!(rx.try_recv(), Err(crossbeam::channel::TryRecvError::Disconnected))
                });
                if all_closed {
                    break;
                }
            }
        });

        (
            EncoderService {
                set_tx,
                get_txs,
                handle: Some(handle),
                hits,
                misses: misses_arc,
            },
            handles,
        )
    }

    /// Shutdown. Drop all senders, join the thread.
    pub fn shutdown(mut self) {
        drop(self.set_tx);
        drop(self.get_txs);
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
