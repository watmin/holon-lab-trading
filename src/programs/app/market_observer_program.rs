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
use crate::encoding::encode::{encode, take_encode_metrics, EncodeState, DEFAULT_L1_CAPACITY};
use crate::encoding::rhythm::build_rhythm_asts;
use crate::encoding::thought_encoder::{ThoughtAST, ThoughtASTKind};
use crate::vocab::shared::time::time_facts;
use crate::programs::chain::MarketChain;
use crate::programs::stdlib::cache::CacheHandle;
use crate::programs::stdlib::console::ConsoleHandle;
use crate::programs::stdlib::database::DatabaseHandle;
use crate::services::queue::QueueReceiver;
use crate::services::topic::TopicSender;
use crate::programs::telemetry::{emit_metric, flush_metrics};

/// Input to the observer: enriched candle, window snapshot, encode count.
pub struct ObsInput {
    pub candle: Candle,
    pub window: Arc<Vec<Candle>>,
    pub encode_count: usize,
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

/// Output of `build_market_thought` — both the chain-bound AST (rhythms only,
/// flows downstream) and the observer's own encoding thought (rhythms + time).
struct MarketThought {
    pub chain_ast: ThoughtAST,   // what flows downstream — rhythms only
    pub own_thought: ThoughtAST, // what the observer encodes — rhythms + time
    pub fact_count: f64,
}

/// Build indicator rhythms through the lens — the thought IS the movie.
/// Rhythms ONLY — time is added to the market observer's own thought,
/// not to chain_ast. This prevents double-counting when the broker
/// composes chain_ast + its own time_facts.
fn build_market_thought(
    sliced_window: &[crate::types::candle::Candle],
    specs: &[crate::encoding::rhythm::IndicatorSpec],
    candle: &crate::types::candle::Candle,
) -> MarketThought {
    let rhythm_asts = build_rhythm_asts(sliced_window, specs);
    let fact_count = rhythm_asts.len() as f64;
    // chain_ast: what flows downstream — rhythms only, no time.
    let chain_ast = ThoughtAST::new(ThoughtASTKind::Bundle(rhythm_asts.clone()));
    // own_thought: what this observer learns/predicts from —
    // rhythms + full time vocabulary (5 leaves + 3 compositions).
    let mut own_facts = rhythm_asts;
    own_facts.extend(time_facts(candle));
    let own_thought = ThoughtAST::new(ThoughtASTKind::Bundle(own_facts));
    MarketThought {
        chain_ast,
        own_thought,
        fact_count,
    }
}

/// Per-candle metrics collected in the observer loop.
/// Bundled so `emit_observer_telemetry` has one structured argument.
struct ObserverCandleMetrics {
    pub ns_drain: f64,
    pub ns_collect: f64,
    pub ns_encode: f64,
    pub ns_observe: f64,
    pub ns_send: f64,
    pub ns_total: f64,
    pub facts_count: f64,
    pub self_graded: usize,
    pub unconfirmed_count: usize,
    pub enc_metrics: crate::encoding::encode::EncodeMetrics,
}

/// Push all per-candle telemetry log entries onto `pending`.
/// Preserves the exact metric names emitted by the observer loop.
fn emit_observer_telemetry(
    pending: &mut Vec<crate::types::log_entry::LogEntry>,
    ns: std::sync::Arc<str>,
    id: std::sync::Arc<str>,
    dims: std::sync::Arc<str>,
    batch_ts: u64,
    m: &ObserverCandleMetrics,
) {
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "drain_learn", m.ns_drain, "Nanoseconds");
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "collect_facts", m.ns_collect, "Nanoseconds");
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "facts_count", m.facts_count, "Count");
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "encode", m.ns_encode, "Nanoseconds");
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "enc_nodes", m.enc_metrics.nodes_walked as f64, "Count");
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "enc_hits", m.enc_metrics.cache_hits as f64, "Count");
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "enc_misses", m.enc_metrics.cache_misses as f64, "Count");
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "enc_ns_batch_get", m.enc_metrics.ns_batch_get as f64, "Nanoseconds");
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "enc_batch_rounds", m.enc_metrics.batch_rounds as f64, "Count");
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "enc_l1_hits", m.enc_metrics.l1_hits as f64, "Count");
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "enc_l1_misses", m.enc_metrics.l1_misses as f64, "Count");
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "enc_ns_compute", m.enc_metrics.ns_compute as f64, "Nanoseconds");
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "enc_forms_computed", m.enc_metrics.forms_computed as f64, "Count");
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "enc_ns_cache_set", m.enc_metrics.ns_cache_set as f64, "Nanoseconds");
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "observe", m.ns_observe, "Nanoseconds");
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "send", m.ns_send, "Nanoseconds");
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "total", m.ns_total, "Nanoseconds");
    emit_metric(pending, ns.clone(), id.clone(), dims.clone(), batch_ts, "self_graded", m.self_graded as f64, "Count");
    emit_metric(pending, ns, id, dims, batch_ts, "unconfirmed", m.unconfirmed_count as f64, "Count");
}

/// Run the market observer program. Call this inside thread::spawn.
/// The observer teaches itself from the phase labeler — no broker propagation.
/// Output fans out to M regime observers via a topic.
/// Returns the trained MarketObserver when the candle source disconnects.
pub fn market_observer_program(
    candle_rx: QueueReceiver<ObsInput>,
    result_tx: TopicSender<MarketChain>,
    cache: CacheHandle<u64, Vector>,
    vm: VectorManager,
    scalar: Arc<ScalarEncoder>,
    console: ConsoleHandle,
    db_tx: DatabaseHandle<LogEntry>,
    mut observer: MarketObserver,
    observer_idx: usize,
    recalib_interval: usize,
) -> MarketObserver {
    let mut candle_count = 0usize;
    let lens = observer.lens;
    let mut unconfirmed: Vec<UnconfirmedPrediction> = Vec::new();
    let mut encode_state = EncodeState::new(DEFAULT_L1_CAPACITY);
    // Lens is fixed for the observer's lifetime; specs never change.
    let specs = market_rhythm_specs(&lens);

    while let Ok(input) = candle_rx.recv() {
        let t_total = std::time::Instant::now();
        let batch_ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64;
        candle_count += 1;

        // Per-candle Arc<str> — built once, cloned (refcount++) for each emit.
        let ns: Arc<str> = Arc::from("market-observer");
        let id: Arc<str> = Arc::from(format!("market:{}:{}", lens, candle_count));
        let metric_dims: Arc<str> = Arc::from(format!("{{\"lens\":\"{}\"}}", lens));

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
        let built = build_market_thought(sliced, &specs, &input.candle);
        let market_ast = built.chain_ast;
        let market_thought = built.own_thought;
        let fact_count = built.fact_count;
        // rune:temper(disabled) — rhythm ASTs are multi-MB EDN strings.
        // Logging every candle produced 6.5GB in 312 candles. Disabled
        // until we implement summary logging or sampled snapshots.
        // let snapshot_edn = market_thought.to_edn();
        let snapshot_edn = String::from("disabled:rhythm-ast-too-large");
        let ns_collect = t0.elapsed().as_nanos() as f64;

        // Encode via cache: the AST tree is walked, every node cached.
        let t0 = std::time::Instant::now();
        let thought = encode(&mut encode_state, &cache, &market_thought, &vm, &scalar);
        let enc_metrics = take_encode_metrics();
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
            market_ast,
            prediction: result.prediction,
            edge: result.edge,
        });
        let ns_send = t0.elapsed().as_nanos() as f64;

        let ns_total = t_total.elapsed().as_nanos() as f64;

        // Collect all log entries into a pending vec, flush once.
        let mut pending = Vec::new();

        emit_observer_telemetry(
            &mut pending,
            ns,
            id,
            metric_dims,
            batch_ts,
            &ObserverCandleMetrics {
                ns_drain,
                ns_collect,
                ns_encode,
                ns_observe,
                ns_send,
                ns_total,
                facts_count: fact_count,
                self_graded,
                unconfirmed_count: unconfirmed.len(),
                enc_metrics,
            },
        );

        let us_elapsed = (ns_total / 1000.0) as u64;

        // Snapshot every candle.
        pending.push(LogEntry::ObserverSnapshot {
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

        // One batch send per candle.
        flush_metrics(&db_tx, &mut pending);

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
