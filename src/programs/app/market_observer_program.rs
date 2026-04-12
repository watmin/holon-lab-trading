/// market_observer_program.rs — the observer thread body.
/// Compiled from wat/market-observer-program.wat.
///
/// Receives candles through a queue, encodes through a lens, predicts,
/// sends results, and learns from settlement signals through a mailbox.
/// On shutdown it drains remaining learn signals and returns the observer.
/// The learned state comes home.

use std::collections::HashMap;
use std::sync::Arc;

use holon::kernel::vector::Vector;

use crate::types::candle::Candle;
use crate::types::enums::Direction;
use crate::types::log_entry::LogEntry;
use crate::domain::market_observer::MarketObserver;
use crate::post::market_lens_facts;
use crate::programs::chain::MarketChain;
use crate::programs::stdlib::cache::CacheHandle;
use crate::programs::stdlib::console::ConsoleHandle;
use crate::encoding::scale_tracker::ScaleTracker;
use crate::services::mailbox::MailboxReceiver;
use crate::services::queue::{QueueReceiver, QueueSender};
use crate::services::topic::TopicSender;
use crate::encoding::thought_encoder::{ThoughtAST, ThoughtEncoder};

/// Input to the observer: enriched candle, window snapshot, encode count.
pub struct ObsInput {
    pub candle: Candle,
    pub window: Arc<Vec<Candle>>,
    pub encode_count: usize,
}

/// Learn signal: thought vector, direction label, weight.
pub struct ObsLearn {
    pub thought: Vector,
    pub direction: Direction,
    pub weight: f64,
}

/// Encode with cache protocol: check → compute → install.
/// The cache is the lookup. The encoder is the computation.
fn encode_with_cache(
    ast: &ThoughtAST,
    cache: &CacheHandle<ThoughtAST, Vector>,
    encoder: &ThoughtEncoder,
) -> Vector {
    if let Some(cached) = cache.get(ast) {
        return cached;
    }
    let (vec, misses) = encoder.encode(ast);
    // Install the main AST
    cache.set(ast.clone(), vec.clone());
    // Install sub-tree misses too
    for (sub_ast, sub_vec) in misses {
        cache.set(sub_ast, sub_vec);
    }
    vec
}

/// Drain all pending learn signals. Non-blocking.
/// Each signal resolves the observer's reckoner with reality.
fn drain_learn(
    learn_rx: &MailboxReceiver<ObsLearn>,
    observer: &mut MarketObserver,
    recalib_interval: usize,
) {
    while let Ok(signal) = learn_rx.try_recv() {
        observer.resolve(&signal.thought, signal.direction, signal.weight, recalib_interval);
    }
}

/// Run the market observer program. Call this inside thread::spawn.
/// Output fans out to M exit observers via a topic.
/// Returns the trained MarketObserver when the candle source disconnects.
pub fn market_observer_program(
    candle_rx: QueueReceiver<ObsInput>,
    result_tx: TopicSender<MarketChain>,
    learn_rx: MailboxReceiver<ObsLearn>,
    cache: CacheHandle<ThoughtAST, Vector>,
    console: ConsoleHandle,
    db_tx: QueueSender<LogEntry>,
    mut observer: MarketObserver,
    encoder: Arc<ThoughtEncoder>,
    observer_idx: usize,
    recalib_interval: usize,
) -> MarketObserver {
    let mut candle_count = 0usize;
    let mut scales: HashMap<String, ScaleTracker> = HashMap::new();
    let lens = observer.lens;

    while let Ok(input) = candle_rx.recv() {
        candle_count += 1;

        // LEARN FIRST. Drain all pending signals before encoding.
        drain_learn(&learn_rx, &mut observer, recalib_interval);

        // Sample window size from observer's own time scale.
        let ws = observer.window_sampler.sample(candle_count);
        let full_len = input.window.len();
        let start = if full_len > ws { full_len - ws } else { 0 };
        let sliced: Vec<Candle> = input.window[start..].to_vec();

        // Collect facts through the lens.
        let facts = market_lens_facts(&lens, &input.candle, &sliced, &mut scales);
        let bundle_ast = ThoughtAST::Bundle(facts);

        // Encode via cache: check → compute → install.
        let thought = encode_with_cache(&bundle_ast, &cache, &encoder);

        // Observe: noise subspace learns, anomaly extracted, reckoner predicts.
        let result = observer.observe(thought, Vec::new());

        // Snapshot every 100 candles — into the DB.
        if candle_count % 100 == 0 {
            let _ = db_tx.send(LogEntry::ObserverSnapshot {
                candle: candle_count,
                observer_idx,
                lens: format!("{}", lens),
                disc_strength: observer.reckoner.last_disc_strength(),
                conviction: result.prediction.conviction,
                experience: observer.experience(),
                resolved: observer.resolved,
                recalib_count: observer.reckoner.recalib_count(),
                recalib_wins: observer.recalib_wins,
                recalib_total: observer.recalib_total,
                last_prediction: format!("{:?}", observer.last_prediction),
            });
        }

        // Diagnostic every 1000 candles — to console.
        if candle_count % 1000 == 0 {
            console.out(format!(
                "{}: disc={:.4} conv={:.4} exp={:.1}",
                lens,
                observer.reckoner.last_disc_strength(),
                result.prediction.conviction,
                observer.experience(),
            ));
        }

        // Send result.
        let _ = result_tx.send(MarketChain {
            candle: input.candle,
            window: input.window,
            encode_count: input.encode_count,
            market_raw: result.raw_thought,
            market_anomaly: result.anomaly,
            market_ast: bundle_ast,
            prediction: result.prediction,
            edge: result.edge,
        });
    }

    // GRACEFUL SHUTDOWN. Drain learn one last time.
    drain_learn(&learn_rx, &mut observer, recalib_interval);

    // Return the observer. The experience survives.
    observer
}
