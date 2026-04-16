/// market_observer_program.rs — the observer thread body.
/// Compiled from wat/market-observer-program.wat.
///
/// Receives candles through a queue, encodes through a lens, predicts,
/// sends results, and learns from settlement signals through a mailbox.
/// On shutdown it drains remaining learn signals and returns the observer.
/// The learned state comes home.

use std::sync::Arc;

use holon::kernel::scalar::ScalarEncoder;
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

use crate::types::candle::Candle;
use crate::types::enums::Direction;
use crate::types::log_entry::LogEntry;
use crate::types::pivot::PhaseLabel;
use crate::domain::market_observer::MarketObserver;
use crate::domain::lens::market_rhythm_specs;
use crate::encoding::encode::encode;
use crate::encoding::rhythm::build_rhythm_asts;
use crate::encoding::thought_encoder::ThoughtAST;
use crate::programs::chain::MarketChain;
use crate::programs::stdlib::cache::CacheHandle;
use crate::programs::stdlib::console::ConsoleHandle;
use crate::services::queue::{QueueReceiver, QueueSender};
use crate::services::topic::TopicSender;
use crate::programs::telemetry::emit_metric;

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

/// An unconfirmed prediction. The market observer holds these until
/// a peak or valley confirms or denies the predicted direction.
/// The market teaches. The observer learns from its own history.
struct UnconfirmedPrediction {
    anomaly: Vector,       // what the reckoner predicted on
    direction: Direction,  // what it predicted
    entry_price: f64,      // close at prediction time
}

/// Grade unconfirmed predictions against a peak or valley.
/// Predictions confirmed correct learn the predicted direction.
/// Predictions confirmed wrong learn the opposite direction.
/// Returns the count of confirmed predictions.
fn grade_predictions(
    unconfirmed: &mut Vec<UnconfirmedPrediction>,
    current_price: f64,
    observer: &mut MarketObserver,
    recalib_interval: usize,
) -> usize {
    let mut confirmed = 0;
    unconfirmed.retain(|pred| {
        let price_went_up = current_price > pred.entry_price;
        let price_went_down = current_price < pred.entry_price;

        let verdict = match pred.direction {
            Direction::Up => {
                if price_went_up { Some(Direction::Up) }       // correct
                else if price_went_down { Some(Direction::Down) } // wrong
                else { None }                                    // flat, hold
            }
            Direction::Down => {
                if price_went_down { Some(Direction::Down) }   // correct
                else if price_went_up { Some(Direction::Up) }  // wrong
                else { None }                                    // flat, hold
            }
        };

        match verdict {
            Some(learned_direction) => {
                observer.resolve(&pred.anomaly, learned_direction, 1.0, recalib_interval);
                confirmed += 1;
                false // remove — confirmed
            }
            None => true, // keep — not clear yet
        }
    });
    confirmed
}

/// Run the market observer program. Call this inside thread::spawn.
/// The observer teaches itself from the phase labeler — no broker propagation.
/// Output fans out to M regime observers via a topic.
/// Returns the trained MarketObserver when the candle source disconnects.
pub fn market_observer_program(
    candle_rx: QueueReceiver<ObsInput>,
    result_tx: TopicSender<MarketChain>,
    cache: CacheHandle<ThoughtAST, Vector>,
    vm: VectorManager,
    scalar: Arc<ScalarEncoder>,
    console: ConsoleHandle,
    db_tx: QueueSender<LogEntry>,
    mut observer: MarketObserver,
    observer_idx: usize,
    recalib_interval: usize,
) -> MarketObserver {
    let mut candle_count = 0usize;
    let lens = observer.lens;
    let mut unconfirmed: Vec<UnconfirmedPrediction> = Vec::new();

    while let Ok(input) = candle_rx.recv() {
        let t_total = std::time::Instant::now();
        let batch_ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64;
        candle_count += 1;

        let ns = "market-observer";
        let id = format!("market:{}:{}", lens, candle_count);
        let metric_dims = format!("{{\"lens\":\"{}\"}}", lens);

        // LEARN FIRST — self-grade at peaks and valleys.
        // The market teaches. The observer learns from its own predictions.
        let t0 = std::time::Instant::now();
        let self_graded = match input.candle.phase_label {
            PhaseLabel::Peak | PhaseLabel::Valley => {
                grade_predictions(
                    &mut unconfirmed,
                    input.candle.close,
                    &mut observer,
                    recalib_interval,
                )
            }
            PhaseLabel::Transition => 0,
        };

        let ns_drain = t0.elapsed().as_nanos() as f64;

        // Sample window size from observer's own time scale.
        let ws = observer.window_sampler.sample(candle_count);
        let full_len = input.window.len();
        let start = if full_len > ws { full_len - ws } else { 0 };
        let sliced = &input.window[start..];

        // Build indicator rhythms through the lens — the thought IS the movie.
        let t0 = std::time::Instant::now();
        let (indicator_specs, circular_specs) = market_rhythm_specs(&lens);
        let rhythm_asts = build_rhythm_asts(sliced, &indicator_specs, &circular_specs);
        let fact_count = rhythm_asts.len() as f64;
        let bundle_ast = ThoughtAST::Bundle(rhythm_asts);
        // rune:temper(intentional) — being blind is being incapable. Full thought logging every candle.
        let snapshot_edn = bundle_ast.to_edn();
        let ns_collect = t0.elapsed().as_nanos() as f64;

        // Encode via cache: the AST tree is walked, every node cached.
        let t0 = std::time::Instant::now();
        let thought = encode(&cache, &bundle_ast, &vm, &scalar);
        let ns_encode = t0.elapsed().as_nanos() as f64;

        // Observe: noise subspace learns, anomaly extracted, reckoner predicts.
        let t0 = std::time::Instant::now();
        let result = observer.observe(thought);
        let ns_observe = t0.elapsed().as_nanos() as f64;

        // Capture conviction before prediction is moved.
        let conviction = result.prediction.conviction;

        // Record this prediction for self-grading at a future peak or valley.
        // Use last_prediction — always set, even before the reckoner calibrates.
        // The observer's best guess is honest at every candle.
        unconfirmed.push(UnconfirmedPrediction {
            anomaly: result.anomaly.clone(),
            direction: observer.last_prediction,
            entry_price: input.candle.close,
        });

        // Send the chain — bounded(1), blocks until exit takes it.
        let t0 = std::time::Instant::now();
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
        let ns_send = t0.elapsed().as_nanos() as f64;

        let ns_total = t_total.elapsed().as_nanos() as f64;

        // Emit telemetry.
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "drain_learn", ns_drain, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "collect_facts", ns_collect, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "facts_count", fact_count, "Count");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "encode", ns_encode, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "observe", ns_observe, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "send", ns_send, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "total", ns_total, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "self_graded", self_graded as f64, "Count");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "unconfirmed", unconfirmed.len() as f64, "Count");

        let us_elapsed = (ns_total / 1000.0) as u64;

        // Snapshot every candle.
        {
            let _ = db_tx.send(LogEntry::ObserverSnapshot {
                candle: candle_count,
                observer_idx,
                lens: format!("{}", lens),
                disc_strength: observer.reckoner.last_disc_strength(),
                conviction,
                experience: observer.experience(),
                resolved: observer.resolved,
                recalib_count: observer.reckoner.recalib_count(),
                recalib_wins: observer.recalib_wins,
                recalib_total: observer.recalib_total,
                last_prediction: format!("{:?}", observer.last_prediction),
                us_elapsed,
                thought_ast: snapshot_edn.clone(),
                fact_count: fact_count as usize,
            });
        }

        // Diagnostic every 1000 candles — to console.
        if candle_count % 1000 == 0 {
            console.out(format!(
                "{}: disc={:.4} conv={:.4} exp={:.1}",
                lens,
                observer.reckoner.last_disc_strength(),
                conviction,
                observer.experience(),
            ));
        }
    }

    // Return the observer. The experience survives.
    observer
}
