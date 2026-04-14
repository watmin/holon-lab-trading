/// wat-vm — the second heartbeat. Reads candles, enriches them, feeds observers.
///
/// Candles flow to N market observers. Each observer encodes through its lens,
/// learns the noise subspace, predicts direction. Position observers compose market
/// thoughts with position facts. Brokers bind (market, position) pairs — they register
/// paper trades, resolve them, and teach both observers through learn queues.
/// The observers come home with experience.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use clap::Parser;

use holon::kernel::scalar::ScalarEncoder;
use holon::kernel::vector_manager::VectorManager;

use enterprise::domain::broker::Broker;
use enterprise::domain::candle_stream::CandleStream;
use enterprise::domain::position_observer::PositionObserver;
use enterprise::domain::indicator_bank::IndicatorBank;
use enterprise::domain::ledger;
use enterprise::domain::config;
use enterprise::domain::market_observer::MarketObserver;
use enterprise::kernel::handle_pool::HandlePool;
use enterprise::encoding::thought_encoder::ThoughtEncoder;
use enterprise::programs::app::broker_program::broker_program;
use enterprise::programs::app::position_observer_program::{PositionLearn, PositionSlot, TradeUpdate};
use enterprise::programs::app::position_observer_program::position_observer_program;
use enterprise::programs::app::market_observer_program::{ObsInput, ObsLearn};
use enterprise::programs::app::market_observer_program::market_observer_program;
use enterprise::programs::chain::MarketPositionChain;
use enterprise::programs::stdlib::cache::{EncodingCacheHandle, encoding_cache};
use enterprise::programs::stdlib::console::console;
use enterprise::programs::stdlib::database::database;
use enterprise::services::mailbox::mailbox;
use enterprise::services::queue::{queue_bounded, queue_unbounded, QueueReceiver, QueueSender};
use enterprise::services::topic::topic;
use enterprise::types::log_entry::LogEntry;
use enterprise::programs::chain::MarketChain;

// ─── Signal handling ────────────────────────────────────────────────────────

/// One static bool. The handler writes. The loop reads. Nothing else.
static STOP: AtomicBool = AtomicBool::new(false);

extern "C" fn signal_handler(_sig: libc::c_int) {
    STOP.store(true, Ordering::SeqCst);
}

// ─── CLI ────────────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "wat-vm", about = "Candles in, observers learn, results discarded")]
struct Args {
    /// Candle streams. Format: SOURCE:TARGET:PATH. Repeatable.
    #[arg(long = "stream", required = true)]
    streams: Vec<String>,

    /// Max candles per stream. Each pipeline owns its limit.
    #[arg(long)]
    max_candles: usize,

    /// Vector dimension.
    #[arg(long, default_value_t = 10000)]
    dims: usize,

    /// Observations between recalibrations.
    #[arg(long, default_value_t = 500)]
    recalib_interval: usize,

    /// Venue swap fee as a fraction (e.g. 0.0010 = 10 bps).
    #[arg(long, default_value_t = 0.0010)]
    swap_fee: f64,
}

// ─── Pipeline ───────────────────────────────────────────────────────────────

struct Pipeline {
    source: String,
    target: String,
    stream: CandleStream,
    bank: IndicatorBank,
    count: usize,
}

// ─── Wiring ────────────────────────────────────────────────────────────────

struct WiredMarketObservers {
    /// Senders to feed candles to each observer
    candle_txs: Vec<QueueSender<ObsInput>>,
    /// Thread handles — join to get trained observers back
    join_handles: Vec<std::thread::JoinHandle<MarketObserver>>,
    /// Topic handles — must live until shutdown
    topic_handles: Vec<enterprise::services::topic::TopicHandle>,
    /// Position slot receivers: position_queue_rxs[mi][ei] — market observer mi, position observer ei
    position_queue_rxs: Vec<Vec<enterprise::services::queue::QueueReceiver<MarketChain>>>,
}

fn wire_market_observers(
    observers: Vec<MarketObserver>,
    num_position_observers: usize,
    learn_mailboxes: Vec<enterprise::services::mailbox::MailboxReceiver<ObsLearn>>,
    mut cache_pool: HandlePool<EncodingCacheHandle>,
    mut console_pool: HandlePool<enterprise::programs::stdlib::console::ConsoleHandle>,
    mut db_pool: HandlePool<enterprise::services::queue::QueueSender<LogEntry>>,
    recalib_interval: usize,
) -> WiredMarketObservers {
    let num_observers = observers.len();
    let mut candle_txs: Vec<QueueSender<ObsInput>> = Vec::with_capacity(num_observers);
    let mut join_handles: Vec<std::thread::JoinHandle<MarketObserver>> =
        Vec::with_capacity(num_observers);
    let mut topic_handles = Vec::with_capacity(num_observers);
    let mut position_queue_rxs: Vec<Vec<enterprise::services::queue::QueueReceiver<MarketChain>>> =
        Vec::with_capacity(num_observers);

    for (i, (observer, learn_rx)) in observers.into_iter().zip(learn_mailboxes).enumerate() {
        // Candle input queue
        let (candle_tx, candle_rx) = queue_bounded::<ObsInput>(1);
        candle_txs.push(candle_tx);

        // Create M queues for fan-out to position observers
        let mut position_txs = Vec::with_capacity(num_position_observers);
        let mut position_rxs = Vec::with_capacity(num_position_observers);
        for _ in 0..num_position_observers {
            let (tx, rx) = queue_bounded::<MarketChain>(1);
            position_txs.push(tx);
            position_rxs.push(rx);
        }
        position_queue_rxs.push(position_rxs);

        // Output topic with M consumers — fan out to position observers
        let (result_tx, topic_handle) = topic::<MarketChain>(1, position_txs);
        topic_handles.push(topic_handle);

        // Cache handle for this observer
        let obs_cache = cache_pool.pop();

        // Console handle for this observer
        let obs_console = console_pool.pop();

        // DB sender — real database
        let db_tx = db_pool.pop();

        let jh = std::thread::spawn(move || {
            market_observer_program(
                candle_rx,
                result_tx,
                learn_rx,
                obs_cache,
                obs_console,
                db_tx,
                observer,
                i,
                recalib_interval,
            )
        });
        join_handles.push(jh);
    }

    // Assert all pooled handles were claimed — orphans cause deadlocks.
    console_pool.finish();
    cache_pool.finish();
    db_pool.finish();

    WiredMarketObservers {
        candle_txs,
        join_handles,
        topic_handles,
        position_queue_rxs,
    }
}

// ─── Position observer wiring ──────────────────────────────────────────────────

struct WiredPositionObservers {
    /// Thread handles — join to get trained position observers back
    join_handles: Vec<std::thread::JoinHandle<PositionObserver>>,
    /// Output receivers — one per (mi, ei) slot. The broker consumes these.
    /// Layout: flat vec of N*M, index = mi * num_position + ei
    output_rxs: Vec<QueueReceiver<MarketPositionChain>>,
}

fn wire_position_observers(
    position_observers: Vec<PositionObserver>,
    position_queue_rxs: Vec<Vec<enterprise::services::queue::QueueReceiver<MarketChain>>>,
    learn_mailboxes: Vec<enterprise::services::mailbox::MailboxReceiver<PositionLearn>>,
    trade_mailboxes: Vec<enterprise::services::mailbox::MailboxReceiver<TradeUpdate>>,
    mut cache_pool: HandlePool<EncodingCacheHandle>,
    mut console_pool: HandlePool<enterprise::programs::stdlib::console::ConsoleHandle>,
    mut db_pool: HandlePool<enterprise::services::queue::QueueSender<LogEntry>>,
    noise_floor: f64,
) -> WiredPositionObservers {
    let num_market = position_queue_rxs.len();
    let num_position = position_observers.len();
    let mut join_handles: Vec<std::thread::JoinHandle<PositionObserver>> =
        Vec::with_capacity(num_position);

    // Output receivers: indexed [mi * num_position + ei]
    // We'll fill them in slot order as we wire each position observer.
    let mut output_rxs_by_slot: Vec<Option<QueueReceiver<MarketPositionChain>>> =
        (0..num_market * num_position).map(|_| None).collect();

    // Transpose: position_queue_rxs[mi][ei] → slots[ei][mi]
    // We need to move receivers out, so consume the outer vec.
    let mut transposed: Vec<Vec<Option<enterprise::services::queue::QueueReceiver<MarketChain>>>> =
        Vec::with_capacity(num_position);
    for _ in 0..num_position {
        transposed.push(Vec::with_capacity(num_market));
    }
    for mi_rxs in position_queue_rxs {
        for (ei, rx) in mi_rxs.into_iter().enumerate() {
            transposed[ei].push(Some(rx));
        }
    }

    for (ei, ((position_obs, learn_rx), trade_rx)) in position_observers.into_iter().zip(learn_mailboxes).zip(trade_mailboxes).enumerate() {
        // Build N slots for this position observer
        let slot_rxs: Vec<enterprise::services::queue::QueueReceiver<MarketChain>> = transposed[ei]
            .iter_mut()
            .map(|opt| opt.take().expect("each rx used exactly once"))
            .collect();

        let mut slots = Vec::with_capacity(num_market);
        for (mi, rx) in slot_rxs.into_iter().enumerate() {
            // Output queue — broker consumes the receiver
            let (output_tx, output_rx) = queue_unbounded();
            let slot_idx = mi * num_position + ei;
            output_rxs_by_slot[slot_idx] = Some(output_rx);
            slots.push(PositionSlot {
                input_rx: rx,
                output_tx,
            });
        }

        let obs_cache = cache_pool.pop();
        let obs_console = console_pool.pop();
        let db_tx = db_pool.pop();

        let jh = std::thread::spawn(move || {
            position_observer_program(
                slots,
                learn_rx,
                trade_rx,
                obs_cache,
                obs_console,
                db_tx,
                position_obs,
                noise_floor,
                ei,
            )
        });
        join_handles.push(jh);
    }

    cache_pool.finish();
    console_pool.finish();
    db_pool.finish();

    let output_rxs: Vec<QueueReceiver<MarketPositionChain>> = output_rxs_by_slot
        .into_iter()
        .map(|opt| opt.expect("every slot must have an output receiver"))
        .collect();

    WiredPositionObservers {
        join_handles,
        output_rxs,
    }
}

// ─── Broker wiring ────────────────────────────────────────────────────────

struct WiredBrokers {
    /// Thread handles — join to get trained brokers back
    join_handles: Vec<std::thread::JoinHandle<Broker>>,
}

fn wire_brokers(
    brokers: Vec<Broker>,
    output_rxs: Vec<QueueReceiver<MarketPositionChain>>,
    market_learn_txs: Vec<Vec<QueueSender<ObsLearn>>>,
    position_learn_txs: Vec<Vec<QueueSender<PositionLearn>>>,
    trade_txs: Vec<Option<QueueSender<TradeUpdate>>>,
    mut cache_pool: HandlePool<EncodingCacheHandle>,
    mut console_pool: HandlePool<enterprise::programs::stdlib::console::ConsoleHandle>,
    mut db_pool: HandlePool<enterprise::services::queue::QueueSender<LogEntry>>,
    scalar_encoder: Arc<ScalarEncoder>,
    swap_fee: f64,
    num_position: usize,
) -> WiredBrokers {
    let num_brokers = brokers.len();
    let mut join_handles: Vec<std::thread::JoinHandle<Broker>> = Vec::with_capacity(num_brokers);

    // Flatten the 2D learn tx vecs into per-broker assignments.
    // market_learn_txs[mi][ei] — broker at slot mi*num_position+ei gets market_learn_txs[mi][ei]
    // position_learn_txs[ei][mi] — broker at slot mi*num_position+ei gets position_learn_txs[ei][mi]
    let mut market_learn_flat: Vec<Option<QueueSender<ObsLearn>>> = Vec::with_capacity(num_brokers);
    for mi_txs in market_learn_txs {
        for tx in mi_txs {
            market_learn_flat.push(Some(tx));
        }
    }

    let mut position_learn_flat: Vec<Option<QueueSender<PositionLearn>>> =
        (0..num_brokers).map(|_| None).collect();
    for (ei, ei_txs) in position_learn_txs.into_iter().enumerate() {
        for (mi, tx) in ei_txs.into_iter().enumerate() {
            let slot_idx = mi * num_position + ei;
            position_learn_flat[slot_idx] = Some(tx);
        }
    }

    for (slot_idx, (((broker, chain_rx), (mlt, elt)), ttx)) in brokers
        .into_iter()
        .zip(output_rxs.into_iter())
        .zip(
            market_learn_flat
                .into_iter()
                .zip(position_learn_flat.into_iter()),
        )
        .zip(trade_txs.into_iter())
        .enumerate()
    {
        let market_learn_tx = mlt.unwrap_or_else(|| panic!("missing market learn tx for slot {}", slot_idx));
        let position_learn_tx = elt.unwrap_or_else(|| panic!("missing position learn tx for slot {}", slot_idx));
        let trade_tx = ttx.unwrap_or_else(|| panic!("missing trade tx for slot {}", slot_idx));
        let broker_cache = cache_pool.pop();
        let broker_console = console_pool.pop();
        let broker_db = db_pool.pop();
        let se = Arc::clone(&scalar_encoder);

        let jh = std::thread::spawn(move || {
            broker_program(
                chain_rx,
                market_learn_tx,
                position_learn_tx,
                trade_tx,
                broker_cache,
                broker_console,
                broker_db,
                broker,
                se,
                swap_fee,
            )
        });
        join_handles.push(jh);
    }

    cache_pool.finish();
    console_pool.finish();
    db_pool.finish();

    WiredBrokers { join_handles }
}

// ─── Main ───────────────────────────────────────────────────────────────────

fn main() {
    let args = Args::parse();
    let num_market = config::MARKET_LENSES.len();
    let num_position = config::POSITION_LENSES.len();
    let dims = args.dims;
    let recalib_interval = args.recalib_interval;
    let noise_floor = 5.0 / (dims as f64).sqrt();

    // Install signal handlers. One write on signal. One read per candle.
    unsafe {
        libc::signal(libc::SIGINT, signal_handler as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, signal_handler as *const () as libc::sighandler_t);
    }

    // Parse --stream flags
    let mut parsed: Vec<(String, String, String)> = Vec::new();
    for raw in &args.streams {
        let parts: Vec<&str> = raw.splitn(3, ':').collect();
        assert!(
            parts.len() == 3,
            "invalid --stream format '{}': expected SOURCE:TARGET:PATH",
            raw
        );
        parsed.push((
            parts[0].to_string(),
            parts[1].to_string(),
            parts[2].to_string(),
        ));
    }

    let num_brokers = num_market * num_position;

    // Console: streams + market + position + brokers + main
    let num_console = parsed.len() + num_market + num_position + num_brokers + 1;
    let (handles, console_driver) = console(num_console);
    let mut console_pool = HandlePool::new("console", handles);

    // Main handle — first claim
    let main_handle = console_pool.pop();

    // Stream handles — one per pipeline
    let mut stream_handles = Vec::with_capacity(parsed.len());
    for _ in 0..parsed.len() {
        stream_handles.push(console_pool.pop());
    }

    // ─── Database ───────────────────────────────────────────────────────────
    std::fs::create_dir_all("runs").ok();
    let db_path = format!(
        "runs/wat-vm_{}.db",
        chrono::Local::now().format("%Y%m%d_%H%M%S")
    );

    // All wires before any work. The kernel creates all queues, builds the
    // mailbox, then spawns the database. +1 self-telemetry, +1 cache telemetry.
    let num_db_producers = num_market + num_position + num_brokers;
    let num_db_total = num_db_producers + 1; // +1 cache telemetry
    let mut db_txs = Vec::with_capacity(num_db_total);
    let mut db_rxs = Vec::with_capacity(num_db_total);
    for _ in 0..num_db_total {
        let (tx, rx) = queue_unbounded::<LogEntry>();
        db_txs.push(tx);
        db_rxs.push(rx);
    }
    let db_mailbox_rx = mailbox(db_rxs);

    // Cache telemetry sender — the cache driver emits metrics through this
    let cache_telemetry_tx = db_txs.pop().unwrap();

    // Database gate: emit accumulated telemetry every 5 seconds.
    // The database writes its own telemetry directly — no pipe to itself.
    // A self-pipe through the mailbox creates a circular dependency (deadlock).
    let db_gate = enterprise::programs::telemetry::make_rate_gate(
        std::time::Duration::from_secs(5),
    );
    let db_emit = {
        let seq = std::sync::atomic::AtomicUsize::new(0);
        move |conn: &rusqlite::Connection, flush_count: usize, total_rows: usize, flush_ns: u64| {
            let s = seq.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let ts = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos() as u64;
            let id = format!("db:emit:{}", s);
            let dims = "{}";
            for (name, value, unit) in [
                ("flush_count", flush_count as f64, "Count"),
                ("total_rows", total_rows as f64, "Count"),
                ("total_flush_ns", flush_ns as f64, "Nanoseconds"),
            ] {
                conn.execute(
                    "INSERT INTO telemetry VALUES (?,?,?,?,?,?,?)",
                    rusqlite::params!["database", &id, dims, ts, name, value, unit],
                ).ok();
            }
        }
    };
    let db_driver = database::<LogEntry>(
        &db_path,
        db_mailbox_rx,
        100,
        ledger::ledger_setup,
        ledger::ledger_insert,
        Box::new(db_gate),
        Box::new(db_emit),
    );

    let mut db_pool = HandlePool::new("db", db_txs);

    main_handle.out(format!("db: {}", db_path));

    // ─── ThoughtEncoder + Cache ────────────────────────────────────────────
    // The ThoughtEncoder is constructed ONCE and immediately consumed by the
    // encoding cache. It moves into the cache driver thread. No Arc. No sharing.
    // Programs encode through EncodingCacheHandle::encode() — opaque, hit or miss invisible.
    let vm = VectorManager::new(dims);
    let encoder = ThoughtEncoder::new(vm);

    let cache_gate = enterprise::programs::telemetry::make_rate_gate(
        std::time::Duration::from_secs(5),
    );
    let cache_emit = {
        let tx = cache_telemetry_tx;
        let seq = std::sync::atomic::AtomicUsize::new(0);
        move |hits: usize, misses: usize, size: usize| {
            let s = seq.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let id = format!("cache:emit:{}", s);
            let ts = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos() as u64;
            let dims = "{\"name\":\"encoder\"}";
            enterprise::programs::telemetry::emit_metric(
                &tx, "cache", &id, dims, ts, "hits", hits as f64, "Count",
            );
            enterprise::programs::telemetry::emit_metric(
                &tx, "cache", &id, dims, ts, "misses", misses as f64, "Count",
            );
            enterprise::programs::telemetry::emit_metric(
                &tx, "cache", &id, dims, ts, "cache_size", size as f64, "Count",
            );
            let hit_rate = if hits + misses > 0 {
                hits as f64 / (hits + misses) as f64
            } else {
                0.0
            };
            enterprise::programs::telemetry::emit_metric(
                &tx, "cache", &id, dims, ts, "hit_rate", hit_rate, "Count",
            );
        }
    };
    let (cache_handles, cache_driver) = encoding_cache(
        "encoder",
        encoder, // CONSUMED — moved into the cache thread
        65536,
        num_market + num_position + num_brokers,
        Box::new(cache_gate),
        Box::new(cache_emit),
    );
    let mut cache_pool = HandlePool::new("cache", cache_handles);

    // ─── Reserve handles for position observers and brokers ──────────────────
    // Pop position + broker handles first so market observer wiring gets the rest.
    let mut position_console_handles = Vec::with_capacity(num_position);
    let mut position_cache_handles = Vec::with_capacity(num_position);
    let mut position_db_handles = Vec::with_capacity(num_position);
    for _ in 0..num_position {
        position_console_handles.push(console_pool.pop());
        position_cache_handles.push(cache_pool.pop());
        position_db_handles.push(db_pool.pop());
    }
    let mut broker_cache_handles = Vec::with_capacity(num_brokers);
    let mut broker_console_handles = Vec::with_capacity(num_brokers);
    let mut broker_db_handles = Vec::with_capacity(num_brokers);
    for _ in 0..num_brokers {
        broker_cache_handles.push(cache_pool.pop());
        broker_console_handles.push(console_pool.pop());
        broker_db_handles.push(db_pool.pop());
    }

    // ─── Learn queues ──────────────────────────────────────────────────────
    // Created BEFORE observers so the mailbox receivers exist at wire time.

    // Market learn queues: market_learn_txs[mi][ei], market_learn_rxs[mi] = Vec<QueueReceiver>
    let mut market_learn_txs: Vec<Vec<QueueSender<ObsLearn>>> = Vec::with_capacity(num_market);
    let mut market_learn_rxs: Vec<Vec<QueueReceiver<ObsLearn>>> = Vec::with_capacity(num_market);
    for _ in 0..num_market {
        let mut txs = Vec::with_capacity(num_position);
        let mut rxs = Vec::with_capacity(num_position);
        for _ in 0..num_position {
            let (tx, rx) = queue_unbounded::<ObsLearn>();
            txs.push(tx);
            rxs.push(rx);
        }
        market_learn_txs.push(txs);
        market_learn_rxs.push(rxs);
    }

    // Position learn queues: position_learn_txs[ei][mi], position_learn_rxs[ei] = Vec<QueueReceiver>
    let mut position_learn_txs: Vec<Vec<QueueSender<PositionLearn>>> = Vec::with_capacity(num_position);
    let mut position_learn_rxs: Vec<Vec<QueueReceiver<PositionLearn>>> = Vec::with_capacity(num_position);
    for _ in 0..num_position {
        let mut txs = Vec::with_capacity(num_market);
        let mut rxs = Vec::with_capacity(num_market);
        for _ in 0..num_market {
            let (tx, rx) = queue_unbounded::<PositionLearn>();
            txs.push(tx);
            rxs.push(rx);
        }
        position_learn_txs.push(txs);
        position_learn_rxs.push(rxs);
    }

    // Build mailbox receivers for market observers (fan-in from M brokers each)
    let market_learn_mailboxes: Vec<enterprise::services::mailbox::MailboxReceiver<ObsLearn>> =
        market_learn_rxs.into_iter().map(|rxs| mailbox(rxs)).collect();

    // Build mailbox receivers for position observers (fan-in from N brokers each)
    let position_learn_mailboxes: Vec<enterprise::services::mailbox::MailboxReceiver<PositionLearn>> =
        position_learn_rxs.into_iter().map(|rxs| mailbox(rxs)).collect();

    // Trade-state queues: trade_txs[slot_idx] → trade_rxs[ei] (fan-in per position observer)
    // Each broker sends trade updates to its position observer through a dedicated queue.
    // Proposal 040: brokers send trade atoms, position observers receive through mailbox.
    let mut trade_txs_flat: Vec<Option<QueueSender<TradeUpdate>>> =
        (0..num_brokers).map(|_| None).collect();
    let mut trade_rxs_per_position: Vec<Vec<QueueReceiver<TradeUpdate>>> = Vec::with_capacity(num_position);
    for _ in 0..num_position {
        trade_rxs_per_position.push(Vec::with_capacity(num_market));
    }
    for mi in 0..num_market {
        for ei in 0..num_position {
            let (tx, rx) = queue_unbounded::<TradeUpdate>();
            let slot_idx = mi * num_position + ei;
            trade_txs_flat[slot_idx] = Some(tx);
            trade_rxs_per_position[ei].push(rx);
        }
    }

    // Build trade mailbox receivers for position observers (fan-in from N brokers each)
    let trade_mailboxes: Vec<enterprise::services::mailbox::MailboxReceiver<TradeUpdate>> =
        trade_rxs_per_position.into_iter().map(|rxs| mailbox(rxs)).collect();

    // ─── Market observers ──────────────────────────────────────────────────
    let observers = config::create_market_observers(dims, recalib_interval);
    let wired = wire_market_observers(
        observers,
        num_position,
        market_learn_mailboxes,
        cache_pool,
        console_pool,
        db_pool,
        recalib_interval,
    );

    // ─── Position observers ────────────────────────────────────────────────────
    let position_observers = config::create_position_observers(dims, recalib_interval);
    let position_cache_pool = HandlePool::new("position-cache", position_cache_handles);
    let position_console_pool = HandlePool::new("position-console", position_console_handles);
    let position_db_pool = HandlePool::new("position-db", position_db_handles);
    let wired_position = wire_position_observers(
        position_observers,
        wired.position_queue_rxs,
        position_learn_mailboxes,
        trade_mailboxes,
        position_cache_pool,
        position_console_pool,
        position_db_pool,
        noise_floor,
    );

    // ─── Brokers ───────────────────────────────────────────────────────────
    let brokers = config::create_brokers(num_market, num_position, dims, args.swap_fee);
    let scalar_encoder = Arc::new(ScalarEncoder::new(dims));
    let broker_console_pool = HandlePool::new("broker-console", broker_console_handles);
    let broker_db_pool = HandlePool::new("broker-db", broker_db_handles);
    let broker_cache_pool = HandlePool::new("broker-cache", broker_cache_handles);
    let wired_brokers = wire_brokers(
        brokers,
        wired_position.output_rxs,
        market_learn_txs,
        position_learn_txs,
        trade_txs_flat,
        broker_cache_pool,
        broker_console_pool,
        broker_db_pool,
        scalar_encoder,
        args.swap_fee,
        num_position,
    );

    // ─── Build pipelines ───────────────────────────────────────────────────
    let mut pipelines: Vec<Pipeline> = Vec::new();
    for (i, (source, target, path)) in parsed.into_iter().enumerate() {
        let p = Path::new(&path);
        let total = CandleStream::total_candles(p);
        let stream = CandleStream::open(p, &source, &target);
        stream_handles[i].out(format!(
            "{}/{} stream opened: {} candles available",
            source, target, total
        ));
        pipelines.push(Pipeline {
            source,
            target,
            stream,
            bank: IndicatorBank::new(),
            count: 0,
        });
    }

    main_handle.out(format!(
        "{}D recalib={} market={} position={} noise_floor={:.4}",
        dims, recalib_interval, num_market, num_position, noise_floor
    ));

    // ─── Per-stream loop ───────────────────────────────────────────────────
    let max = args.max_candles;
    let mut encode_count: usize = 0;
    let run_start = std::time::Instant::now();
    let mut last_report = std::time::Instant::now();
    for (i, pipeline) in pipelines.iter_mut().enumerate() {
        while pipeline.count < max && !STOP.load(Ordering::SeqCst) {
            match pipeline.stream.next() {
                Some(ohlcv) => {
                    let candle = pipeline.bank.tick(&ohlcv);
                    pipeline.count += 1;
                    encode_count += 1;

                    // Send candle to each observer
                    let window = Arc::new(vec![candle.clone()]);
                    for tx in &wired.candle_txs {
                        let _ = tx.send(ObsInput {
                            candle: candle.clone(),
                            window: Arc::clone(&window),
                            encode_count,
                        });
                    }

                    if pipeline.count % 100 == 0 {
                        let elapsed = run_start.elapsed().as_secs_f64();
                        let throughput = if elapsed > 0.0 { pipeline.count as f64 / elapsed } else { 0.0 };
                        let interval_ms = last_report.elapsed().as_millis();
                        last_report = std::time::Instant::now();
                        stream_handles[i].out(format!(
                            "{}/{} candle {}: close={:.2} {:.1}/s {:.0}ms/100",
                            pipeline.source, pipeline.target, pipeline.count,
                            candle.close, throughput, interval_ms
                        ));
                    }
                }
                None => break,
            }
        }
        if STOP.load(Ordering::SeqCst) {
            stream_handles[i].out(format!(
                "{}/{} interrupted at candle {}",
                pipeline.source, pipeline.target, pipeline.count
            ));
            break;
        }
    }

    // Final pipeline summary
    for (i, pipeline) in pipelines.iter().enumerate() {
        stream_handles[i].out(format!(
            "{}/{} done: {} candles",
            pipeline.source, pipeline.target, pipeline.count
        ));
    }

    // ─── Shutdown ──────────────────────────────────────────────────────────

    // Drop candle senders — market observers see disconnect
    drop(wired.candle_txs);

    // Join market observer threads — get the trained observers back
    for jh in wired.join_handles {
        match jh.join() {
            Ok(observer) => {
                main_handle.out(format!(
                    "{}: experience={:.1} resolved={}",
                    observer.lens,
                    observer.experience(),
                    observer.resolved,
                ));
            }
            Err(_) => {
                main_handle.err("market observer thread panicked".to_string());
            }
        }
    }

    // Drop topic handles — position observers see disconnect as topics drain
    drop(wired.topic_handles);

    // Join position observer threads — get the trained position observers back
    for jh in wired_position.join_handles {
        match jh.join() {
            Ok(position_obs) => {
                main_handle.out(format!(
                    "position-{}: trail_exp={:.1} stop_exp={:.1} grace_rate={:.3}",
                    position_obs.lens,
                    position_obs.trail_reckoner.experience(),
                    position_obs.stop_reckoner.experience(),
                    position_obs.grace_rate,
                ));
            }
            Err(_) => {
                main_handle.err("position observer thread panicked".to_string());
            }
        }
    }

    // Brokers see disconnect on chain_rx — they return.
    // Join broker threads — get the trained brokers back.
    for jh in wired_brokers.join_handles {
        match jh.join() {
            Ok(broker) => {
                let grace_rate = if broker.trade_count > 0 {
                    broker.grace_count as f64 / broker.trade_count as f64
                } else {
                    0.0
                };
                main_handle.out(format!(
                    "broker[{}] {}: trades={} grace={:.3} ev={:.2} papers={}",
                    broker.slot_idx,
                    broker.observer_names.join("/"),
                    broker.trade_count,
                    grace_rate,
                    broker.expected_value,
                    broker.papers.len(),
                ));
            }
            Err(_) => {
                main_handle.err("broker thread panicked".to_string());
            }
        }
    }

    main_handle.out(format!("results: {}", db_path));

    // ─── Cache summary ──────────────────────────────────────────────────────
    // The cache driver emits periodic telemetry through the gate pattern.
    // The atomic counters on CacheDriverHandle are for the console summary.
    {
        let cache_hits = cache_driver.hits.load(Ordering::Relaxed);
        let cache_misses = cache_driver.misses.load(Ordering::Relaxed);
        main_handle.out(format!(
            "cache: hits={} misses={} rate={:.1}%",
            cache_hits,
            cache_misses,
            if cache_hits + cache_misses > 0 {
                100.0 * cache_hits as f64 / (cache_hits + cache_misses) as f64
            } else {
                0.0
            },
        ));
    }

    // Drop all handles, join drivers.
    // Cache driver must join before db driver — its emit closure holds a db_tx.
    // When drivers exit, their closures drop, releasing the db senders.
    drop(stream_handles);
    cache_driver.join();
    db_driver.join();
    drop(main_handle);
    console_driver.join();
}
