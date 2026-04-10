/// encoder_service.rs — ThoughtEncoder cache as a single-threaded pipe loop.
///
/// The encoder holds an LRU cache. Callers have their own pipe sets.
/// The loop iterates all pipes once per iteration. No select. No mutex.
///
/// Protocol:
///   Caller: write AST to get-request pipe → block on get-response pipe → receive Some/None
///   Caller: if None, compute, write to set pipe (fire and forget)
///   Encoder: one pass per iteration — drain sets, service gets, sleep, repeat.

use std::num::NonZeroUsize;
use std::thread::{self, JoinHandle};

use crossbeam::channel::{self, Receiver, Sender, TryRecvError};
use lru::LruCache;

use holon::kernel::vector::Vector;

use crate::thought_encoder::ThoughtAST;

/// A caller's pipe set. One per thread. Moved into the thread.
pub struct EncoderHandle {
    get_tx: Sender<ThoughtAST>,
    get_rx: Receiver<Option<Vector>>,
    set_tx: Sender<(ThoughtAST, Vector)>,
}

impl EncoderHandle {
    /// Blocking get. Sends AST, waits for Some(Vector) or None.
    pub fn get(&self, ast: &ThoughtAST) -> Option<Vector> {
        let _ = self.get_tx.send(ast.clone());
        self.get_rx.recv().unwrap()
    }

    /// Fire and forget. Cache learns.
    pub fn set(&self, ast: ThoughtAST, vec: Vector) {
        let _ = self.set_tx.send((ast, vec));
    }
}

/// The service. Owns the thread. Reports stats.
/// Does NOT hold sender copies — the handles ARE the senders.
/// When all handles drop, the channels close, the cascade flows,
/// the encoder thread exits.
pub struct EncoderService {
    handle: Option<JoinHandle<()>>,
    pub hits: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    pub misses: std::sync::Arc<std::sync::atomic::AtomicUsize>,
}

impl EncoderService {
    /// Spawn the encoder thread. Returns the service + N handles.
    pub fn spawn(n_callers: usize, cache_capacity: usize) -> (Self, Vec<EncoderHandle>) {
        let mut handles = Vec::with_capacity(n_callers);
        let mut get_rxs: Vec<Receiver<ThoughtAST>> = Vec::new();
        let mut resp_txs: Vec<Sender<Option<Vector>>> = Vec::new();
        let mut set_rxs: Vec<Receiver<(ThoughtAST, Vector)>> = Vec::new();
        // No backup senders. The handles ARE the only senders.
        // When handles drop, channels close, cascade flows.

        for _ in 0..n_callers {
            let (get_tx, get_rx) = channel::bounded::<ThoughtAST>(1);
            let (resp_tx, resp_rx) = channel::bounded::<Option<Vector>>(1);
            let (set_tx, set_rx) = channel::unbounded::<(ThoughtAST, Vector)>();

            handles.push(EncoderHandle {
                get_tx,
                get_rx: resp_rx,
                set_tx,
            });

            get_rxs.push(get_rx);
            resp_txs.push(resp_tx);
            set_rxs.push(set_rx);
        }

        let hits = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let misses = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let hits_clone = hits.clone();
        let misses_clone = misses.clone();

        let handle = thread::spawn(move || {
            let mut cache: LruCache<ThoughtAST, Vector> =
                LruCache::new(NonZeroUsize::new(cache_capacity).unwrap());
            let n = get_rxs.len();
            let mut closed = vec![false; n];

            loop {
                let mut did_work = false;

                // Pass 1: drain ALL set pipes. Install into cache.
                for set_rx in &set_rxs {
                    while let Ok((ast, vec)) = set_rx.try_recv() {
                        cache.put(ast, vec);
                        did_work = true;
                    }
                }

                // Pass 2: service ALL get pipes. One message per pipe per iteration.
                for i in 0..n {
                    if closed[i] { continue; } // Already closed — skip
                    match get_rxs[i].try_recv() {
                        Ok(ast) => {
                            let result = cache.get(&ast).cloned();
                            if result.is_some() {
                                hits_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                            } else {
                                misses_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                            }
                            let _ = resp_txs[i].send(result);
                            did_work = true;
                        }
                        Err(TryRecvError::Empty) => {}
                        Err(TryRecvError::Disconnected) => {
                            closed[i] = true;
                        }
                    }
                }

                // Shutdown: all get pipes closed
                if closed.iter().all(|&c| c) {
                    break;
                }

                // Yield if no work — prevent busy-spin
                if !did_work {
                    std::thread::sleep(std::time::Duration::from_micros(100));
                }
            }
        });

        (
            EncoderService {
                handle: Some(handle),
                hits,
                misses,
            },
            handles,
        )
    }

    /// Wait for the encoder thread to exit. The cascade must have already
    /// closed all handles (callers dropped their EncoderHandles).
    /// The encoder thread exits when all get pipes are Disconnected.
    pub fn shutdown(mut self) {
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }

    pub fn hit_count(&self) -> usize {
        self.hits.load(std::sync::atomic::Ordering::Relaxed)
    }

    pub fn miss_count(&self) -> usize {
        self.misses.load(std::sync::atomic::Ordering::Relaxed)
    }
}
