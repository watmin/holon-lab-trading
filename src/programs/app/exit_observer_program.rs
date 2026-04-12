/// exit_observer_program.rs — the exit observer thread body.
/// Compiled from wat/exit-observer-program.wat.
///
/// Receives MarketChains through N slots (one per market observer it pairs with).
/// Per candle round, processes all N slots sequentially. Composes market thoughts
/// with exit-specific facts. Learns from distance signals through a mailbox.
/// On shutdown it drains remaining learn signals and returns the observer.
/// The learned state comes home.

use std::collections::HashMap;
use std::sync::Arc;

use holon::kernel::vector::Vector;

use crate::candle::Candle;
use crate::distances::Distances;
use crate::exit_observer::ExitObserver;
use crate::log_entry::LogEntry;
use crate::post::{exit_lens_facts, exit_self_assessment_facts};
use crate::programs::stdlib::cache::CacheHandle;
use crate::programs::stdlib::console::ConsoleHandle;
use crate::scale_tracker::ScaleTracker;
use crate::services::mailbox::{MailboxReceiver, MailboxSender};
use crate::services::queue::{QueueReceiver, QueueSender};
use crate::thought_encoder::{collect_facts, extract, ThoughtAST, ThoughtEncoder};
use crate::to_f64;

/// Input from a market observer: the full chain of market computation.
#[derive(Clone)]
pub struct MarketChain {
    pub candle: Candle,
    pub window: Arc<Vec<Candle>>,
    pub encode_count: usize,
    pub market_raw: Vector,
    pub market_anomaly: Vector,
    pub market_ast: ThoughtAST,
    pub prediction: holon::memory::Prediction,
    pub edge: f64,
}

/// Output to broker: market + exit computation combined.
pub struct FullChain {
    pub candle: Candle,
    pub window: Arc<Vec<Candle>>,
    pub encode_count: usize,
    pub market_raw: Vector,
    pub market_anomaly: Vector,
    pub market_ast: ThoughtAST,
    pub market_prediction: holon::memory::Prediction,
    pub market_edge: f64,
    pub exit_raw: Vector,
    pub exit_anomaly: Vector,
    pub exit_ast: ThoughtAST,
}

/// Learn signal for exit observers: distance labels from broker propagation.
pub struct ExitLearn {
    pub exit_thought: Vector,
    pub optimal: Distances,
    pub weight: f64,
    pub is_grace: bool,
    pub residue: f64,
}

/// One slot: a (receiver, sender) pair connecting one market observer to one broker.
pub struct ExitSlot {
    pub input_rx: QueueReceiver<MarketChain>,
    pub output_tx: QueueSender<FullChain>,
}

/// Encode with cache protocol: check -> compute -> install.
fn encode_with_cache(
    ast: &ThoughtAST,
    cache: &CacheHandle<ThoughtAST, Vector>,
    encoder: &ThoughtEncoder,
) -> Vector {
    if let Some(cached) = cache.get(ast) {
        return cached;
    }
    let (vec, misses) = encoder.encode(ast);
    cache.set(ast.clone(), vec.clone());
    for (sub_ast, sub_vec) in misses {
        cache.set(sub_ast, sub_vec);
    }
    vec
}

/// Drain all pending exit learn signals. Non-blocking.
fn drain_exit_learn(
    learn_rx: &MailboxReceiver<ExitLearn>,
    exit_obs: &mut ExitObserver,
) {
    while let Ok(signal) = learn_rx.try_recv() {
        exit_obs.observe_distances(
            &signal.exit_thought,
            &signal.optimal,
            signal.weight,
            signal.is_grace,
            signal.residue,
        );
    }
}

/// Run the exit observer program. Call this inside thread::spawn.
/// Processes N slots per candle round, sequentially.
/// Returns the trained ExitObserver when all input slots disconnect.
pub fn exit_observer_program(
    slots: Vec<ExitSlot>,
    learn_rx: MailboxReceiver<ExitLearn>,
    cache: CacheHandle<ThoughtAST, Vector>,
    console: ConsoleHandle,
    db_tx: MailboxSender<LogEntry>,
    mut exit_obs: ExitObserver,
    encoder: Arc<ThoughtEncoder>,
    noise_floor: f64,
) -> ExitObserver {
    let mut candle_count = 0usize;
    let mut scales: HashMap<String, ScaleTracker> = HashMap::new();
    let lens = exit_obs.lens;

    'outer: loop {
        candle_count += 1;

        // LEARN FIRST. Drain all pending signals before encoding.
        drain_exit_learn(&learn_rx, &mut exit_obs);

        // Process each slot sequentially.
        for slot in &slots {
            let chain = match slot.input_rx.recv() {
                Ok(c) => c,
                Err(_) => break 'outer,
            };

            // Collect exit-specific facts through the lens.
            let mut slot_facts = exit_lens_facts(&exit_obs.lens, &chain.candle, &mut scales);
            let self_facts = exit_self_assessment_facts(
                exit_obs.grace_rate,
                exit_obs.avg_residue,
                &mut scales,
            );
            slot_facts.extend(self_facts);

            // Extract from market anomaly: unbind individual facts, keep those above noise floor.
            let market_facts = collect_facts(&chain.market_ast);
            let extracted_anomaly = extract(
                &chain.market_anomaly,
                &market_facts,
                |ast| encode_with_cache(ast, &cache, &encoder),
            );
            for (fact, presence) in extracted_anomaly {
                if presence.abs() > noise_floor {
                    slot_facts.push(ThoughtAST::Bind(
                        Box::new(ThoughtAST::Atom("market".into())),
                        Box::new(fact),
                    ));
                }
            }

            // Extract from market raw: same pattern, different source binding.
            let extracted_raw = extract(
                &chain.market_raw,
                &market_facts,
                |ast| encode_with_cache(ast, &cache, &encoder),
            );
            for (fact, presence) in extracted_raw {
                if presence.abs() > noise_floor {
                    slot_facts.push(ThoughtAST::Bind(
                        Box::new(ThoughtAST::Atom("market-raw".into())),
                        Box::new(fact),
                    ));
                }
            }

            // Encode the combined bundle.
            let exit_bundle = ThoughtAST::Bundle(slot_facts);
            let exit_raw = encode_with_cache(&exit_bundle, &cache, &encoder);

            // Noise subspace learns, then strip noise.
            exit_obs.noise_subspace.update(&to_f64(&exit_raw));
            let exit_anomaly = exit_obs.strip_noise(&exit_raw);

            // Send FullChain downstream.
            let full = FullChain {
                candle: chain.candle,
                window: chain.window,
                encode_count: chain.encode_count,
                market_raw: chain.market_raw,
                market_anomaly: chain.market_anomaly,
                market_ast: chain.market_ast,
                market_prediction: chain.prediction,
                market_edge: chain.edge,
                exit_raw,
                exit_anomaly,
                exit_ast: exit_bundle,
            };
            if slot.output_tx.send(full).is_err() {
                break 'outer;
            }
        }

        // Diagnostic every 1000 candles.
        if candle_count % 1000 == 0 {
            console.out(format!(
                "exit-{}: grace_rate={:.3} avg_residue={:.4} candles={}",
                lens, exit_obs.grace_rate, exit_obs.avg_residue, candle_count,
            ));
        }
    }

    // GRACEFUL SHUTDOWN. Drain learn one last time.
    drain_exit_learn(&learn_rx, &mut exit_obs);

    let _ = db_tx;
    exit_obs
}
