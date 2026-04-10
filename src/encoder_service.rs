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
    lookup: Sender<ThoughtAST>,
    answer: Receiver<Option<Vector>>,
    install: Sender<(ThoughtAST, Vector)>,
}

impl EncoderHandle {
    /// Blocking lookup. Sends AST, waits for Some(Vector) or None.
    pub fn get(&self, ast: &ThoughtAST) -> Option<Vector> {
        let _ = self.lookup.send(ast.clone());
        self.answer.recv().unwrap()
    }

    /// Fire and forget. Cache learns.
    pub fn set(&self, ast: ThoughtAST, vec: Vector) {
        let _ = self.install.send((ast, vec));
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
            let (lookup_send, lookup_recv) = channel::bounded::<ThoughtAST>(1);
            let (answer_send, answer_recv) = channel::bounded::<Option<Vector>>(1);
            let (install_send, install_recv) = channel::unbounded::<(ThoughtAST, Vector)>();

            handles.push(EncoderHandle {
                lookup: lookup_send,
                answer: answer_recv,
                install: install_send,
            });

            get_rxs.push(lookup_recv);
            resp_txs.push(answer_send);
            set_rxs.push(install_recv);
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
                // Pass 1: drain ALL set pipes. Install into cache.
                for set_rx in &set_rxs {
                    while let Ok((ast, vec)) = set_rx.try_recv() {
                        cache.put(ast, vec);
                    }
                }

                // Pass 2: service ALL pending get pipes.
                for i in 0..n {
                    if closed[i] { continue; }
                    match get_rxs[i].try_recv() {
                        Ok(ast) => {
                            let result = cache.get(&ast).cloned();
                            if result.is_some() {
                                hits_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                            } else {
                                misses_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                            }
                            let _ = resp_txs[i].send(result);
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

                // Block until ANY channel has data. Zero CPU when idle.
                // Instant wake when a request arrives. No sleep. No poll.
                let mut sel = crossbeam::channel::Select::new();
                for i in 0..n {
                    if !closed[i] { sel.recv(&get_rxs[i]); }
                }
                for set_rx in &set_rxs {
                    sel.recv(set_rx);
                }
                // Block. Wakes when any channel has data.
                // We don't consume the message here — the next iteration's
                // try_recv passes will pick it up.
                let _ = sel.ready();
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
