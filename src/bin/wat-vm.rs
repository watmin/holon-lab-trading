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
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

use enterprise::domain::broker::Broker;
use enterprise::domain::candle_stream::CandleStream;
use enterprise::domain::regime_observer::RegimeObserver;
use enterprise::domain::indicator_bank::IndicatorBank;
use enterprise::domain::ledger;
use enterprise::domain::config;
use enterprise::domain::market_observer::MarketObserver;
use enterprise::domain::treasury::Treasury;
use enterprise::encoding::thought_encoder::ThoughtAST;
use enterprise::types::candle::Candle;
use enterprise::kernel::handle_pool::HandlePool;
use enterprise::programs::app::broker_program::broker_program;
use enterprise::programs::app::regime_observer_program::RegimeSlot;
use enterprise::programs::app::regime_observer_program::regime_observer_program;
use enterprise::programs::app::market_observer_program::ObsInput;
use enterprise::programs::app::market_observer_program::market_observer_program;
use enterprise::programs::app::treasury_program::{treasury_program, TreasuryEvent, TreasuryHandle, TreasuryTickSender, TreasuryResponse};
use enterprise::programs::chain::MarketRegimeChain;
use enterprise::programs::stdlib::cache::{CacheHandle, cache};
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
    /// Candle window — grows up to max_window_size, then the oldest falls off.
    candle_window: Vec<Candle>,
    max_window_size: usize,
}

// ─── Wiring ────────────────────────────────────────────────────────────────

struct WiredMarketObservers {
    /// Senders to feed candles to each observer
    candle_txs: Vec<QueueSender<ObsInput>>,
    /// Thread handles — join to get trained observers back
    join_handles: Vec<std::thread::JoinHandle<MarketObserver>>,
    /// Topic handles — must live until shutdown
    topic_handles: Vec<enterprise::services::topic::TopicHandle>,
    /// Regime slot receivers: position_queue_rxs[mi][ei] — market observer mi, regime observer ei
    position_queue_rxs: Vec<Vec<enterprise::services::queue::QueueReceiver<MarketChain>>>,
}

fn wire_market_observers(
    observers: Vec<MarketObserver>,
    num_regime_observers: usize,
    mut cache_pool: HandlePool<CacheHandle<ThoughtAST, Vector>>,
    mut console_pool: HandlePool<enterprise::programs::stdlib::console::ConsoleHandle>,
    mut db_pool: HandlePool<enterprise::services::queue::QueueSender<LogEntry>>,
    vm: &VectorManager,
    scalar: &Arc<ScalarEncoder>,
    recalib_interval: usize,
) -> WiredMarketObservers {
    let num_observers = observers.len();
    let mut candle_txs: Vec<QueueSender<ObsInput>> = Vec::with_capacity(num_observers);
    let mut join_handles: Vec<std::thread::JoinHandle<MarketObserver>> =
        Vec::with_capacity(num_observers);
    let mut topic_handles = Vec::with_capacity(num_observers);
    let mut position_queue_rxs: Vec<Vec<enterprise::services::queue::QueueReceiver<MarketChain>>> =
        Vec::with_capacity(num_observers);

    for (i, observer) in observers.into_iter().enumerate() {
        // Candle input queue
        let (candle_tx, candle_rx) = queue_bounded::<ObsInput>(1);
        candle_txs.push(candle_tx);

        // Create M queues for fan-out to regime observers
        let mut position_txs = Vec::with_capacity(num_regime_observers);
        let mut position_rxs = Vec::with_capacity(num_regime_observers);
        for _ in 0..num_regime_observers {
            let (tx, rx) = queue_bounded::<MarketChain>(1);
            position_txs.push(tx);
            position_rxs.push(rx);
        }
        position_queue_rxs.push(position_rxs);

        // Output topic with M consumers — fan out to regime observers
        let (result_tx, topic_handle) = topic::<MarketChain>(1, position_txs);
        topic_handles.push(topic_handle);

        // Cache handle for this observer
        let obs_cache = cache_pool.pop();

        // Console handle for this observer
        let obs_console = console_pool.pop();

        // DB sender — real database
        let db_tx = db_pool.pop();

        // Leaf tools — cloned per program
        let obs_vm = vm.clone();
        let obs_scalar = Arc::clone(scalar);

        let jh = std::thread::spawn(move || {
            market_observer_program(
                candle_rx,
                result_tx,
                obs_cache,
                obs_vm,
                obs_scalar,
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

struct WiredRegimeObservers {
    /// Thread handles — join to get trained regime observers back
    join_handles: Vec<std::thread::JoinHandle<RegimeObserver>>,
    /// Output receivers — one per (mi, ei) slot. The broker consumes these.
    /// Layout: flat vec of N*M, index = mi * num_position + ei
    output_rxs: Vec<QueueReceiver<MarketRegimeChain>>,
}

fn wire_regime_observers(
    regime_observers: Vec<RegimeObserver>,
    position_queue_rxs: Vec<Vec<enterprise::services::queue::QueueReceiver<MarketChain>>>,
    mut cache_pool: HandlePool<CacheHandle<ThoughtAST, Vector>>,
    mut console_pool: HandlePool<enterprise::programs::stdlib::console::ConsoleHandle>,
    mut db_pool: HandlePool<enterprise::services::queue::QueueSender<LogEntry>>,
    vm: &VectorManager,
    scalar: &Arc<ScalarEncoder>,
    noise_floor: f64,
) -> WiredRegimeObservers {
    let num_market = position_queue_rxs.len();
    let num_position = regime_observers.len();
    let mut join_handles: Vec<std::thread::JoinHandle<RegimeObserver>> =
        Vec::with_capacity(num_position);

    // Output receivers: indexed [mi * num_position + ei]
    // We'll fill them in slot order as we wire each regime observer.
    let mut output_rxs_by_slot: Vec<Option<QueueReceiver<MarketRegimeChain>>> =
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

    for (ei, regime_obs) in regime_observers.into_iter().enumerate() {
        // Build N slots for this regime observer
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
            slots.push(RegimeSlot {
                input_rx: rx,
                output_tx,
            });
        }

        let obs_cache = cache_pool.pop();
        let obs_console = console_pool.pop();
        let db_tx = db_pool.pop();

        // Leaf tools — cloned per program
        let obs_vm = vm.clone();
        let obs_scalar = Arc::clone(scalar);

        let jh = std::thread::spawn(move || {
            regime_observer_program(
                slots,
                obs_cache,
                obs_vm,
                obs_scalar,
                obs_console,
                db_tx,
                regime_obs,
                noise_floor,
                ei,
            )
        });
        join_handles.push(jh);
    }

    cache_pool.finish();
    console_pool.finish();
    db_pool.finish();

    let output_rxs: Vec<QueueReceiver<MarketRegimeChain>> = output_rxs_by_slot
        .into_iter()
        .map(|opt| opt.expect("every slot must have an output receiver"))
        .collect();

    WiredRegimeObservers {
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
    output_rxs: Vec<QueueReceiver<MarketRegimeChain>>,
    treasury_handles: Vec<TreasuryHandle>,
    mut cache_pool: HandlePool<CacheHandle<ThoughtAST, Vector>>,
    mut console_pool: HandlePool<enterprise::programs::stdlib::console::ConsoleHandle>,
    mut db_pool: HandlePool<enterprise::services::queue::QueueSender<LogEntry>>,
    vm: &VectorManager,
    scalar: &Arc<ScalarEncoder>,
) -> WiredBrokers {
    let num_brokers = brokers.len();
    let mut join_handles: Vec<std::thread::JoinHandle<Broker>> = Vec::with_capacity(num_brokers);

    for ((broker, chain_rx), treasury) in brokers
        .into_iter()
        .zip(output_rxs.into_iter())
        .zip(treasury_handles.into_iter())
    {
        let broker_cache = cache_pool.pop();
        let broker_console = console_pool.pop();
        let broker_db = db_pool.pop();

        // Leaf tools — cloned per program
        let broker_vm = vm.clone();
        let broker_scalar = Arc::clone(scalar);

        let jh = std::thread::spawn(move || {
            broker_program(
                chain_rx,
                broker_cache,
                broker_vm,
                broker_scalar,
                broker_console,
                broker_db,
                broker,
                treasury,
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

    // Console: streams + market + position + brokers + treasury + main
    let num_console = parsed.len() + num_market + num_position + num_brokers + 1 + 1;
    let (handles, console_driver) = console(num_console);
    let mut console_pool = HandlePool::new("console", handles);

    // Main handle — first claim
    let main_handle = console_pool.pop();

    // Stream handles — one per pipeline
    let mut stream_handles = Vec::with_capacity(parsed.len());
    for _ in 0..parsed.len() {
        stream_handles.push(console_pool.pop());
    }

    // Treasury console handle
    let treasury_console_handle = console_pool.pop();

    // ─── Database ───────────────────────────────────────────────────────────
    std::fs::create_dir_all("runs").ok();
    let db_path = format!(
        "runs/wat-vm_{}.db",
        chrono::Local::now().format("%Y%m%d_%H%M%S")
    );

    // All wires before any work. The kernel creates all queues, builds the
    // mailbox, then spawns the database. +1 self-telemetry, +1 cache telemetry.
    let num_db_producers = num_market + num_position + num_brokers;
    let num_db_total = num_db_producers + 1 + 1; // +1 cache telemetry, +1 treasury
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

    // Treasury DB sender
    let treasury_db_handle = db_txs.pop().unwrap();

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

    // ─── Encoding Cache ─────────────────────────────────────────────────────
    // Generic cache<ThoughtAST, Vector>. The encode() function owns the leaf
    // tools (VectorManager + ScalarEncoder) — passed to programs alongside
    // the cache handle. The cache thread is pure LRU: gets and sets, no computation.
    let vm = VectorManager::new(dims);
    let scalar = Arc::new(ScalarEncoder::new(dims));

    let cache_gate = enterprise::programs::telemetry::make_rate_gate(
        std::time::Duration::from_secs(5),
    );
    let cache_emit = {
        let tx = cache_telemetry_tx;
        let seq = std::sync::atomic::AtomicUsize::new(0);
        move |stats: enterprise::programs::stdlib::cache::CacheStats| {
            let s = seq.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let id = format!("cache:emit:{}", s);
            let ts = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos() as u64;
            let dims = "{\"name\":\"encoder\"}";
            let m = |name, val: f64, unit| {
                enterprise::programs::telemetry::emit_metric(
                    &tx, "cache", &id, dims, ts, name, val, unit,
                );
            };
            m("hits", stats.hits as f64, "Count");
            m("misses", stats.misses as f64, "Count");
            m("cache_size", stats.cache_size as f64, "Count");
            let hit_rate = if stats.hits + stats.misses > 0 {
                stats.hits as f64 / (stats.hits + stats.misses) as f64
            } else { 0.0 };
            m("hit_rate", hit_rate, "Count");
            m("ns_gets", stats.ns_gets as f64, "Nanoseconds");
            m("ns_sets", stats.ns_sets as f64, "Nanoseconds");
            m("gets_serviced", stats.gets_serviced as f64, "Count");
            m("sets_drained", stats.sets_drained as f64, "Count");
            m("evictions", stats.evictions as f64, "Count");
        }
    };
    // children_fn: how to walk a ThoughtAST tree. The cache uses this
    // for resolve() — walk the tree, stop at hits, return the shallowest
    // cached ancestors. Flat nodes (Atom, scalars) have no children.
    let children_fn: Box<dyn Fn(&ThoughtAST) -> Vec<ThoughtAST> + Send> = Box::new(|ast| {
        use enterprise::encoding::thought_encoder::ThoughtAST;
        match ast {
            ThoughtAST::Bind(l, r) => vec![l.as_ref().clone(), r.as_ref().clone()],
            ThoughtAST::Permute(c, _) => vec![c.as_ref().clone()],
            ThoughtAST::Bundle(children) => children.clone(),
            ThoughtAST::Sequential(items) => items.clone(),
            _ => vec![], // Atom, Linear, Log, Circular, Thermometer — leaves
        }
    });
    let (cache_handles, cache_driver) = cache::<ThoughtAST, Vector>(
        "encoder",
        262144, // 256K — cache everything we can
        num_market + num_position + num_brokers,
        children_fn,
        Box::new(cache_gate),
        Box::new(cache_emit),
    );
    let mut cache_pool = HandlePool::new("cache", cache_handles);

    // ─── Reserve handles for regime observers and brokers ──────────────────
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

    // Position observer does not learn. It is thought middleware.
    // The broker is the accountability unit. 054/055.

    // ─── Market observers ──────────────────────────────────────────────────
    let observers = config::create_market_observers(dims, recalib_interval);
    let wired = wire_market_observers(
        observers,
        num_position,
        cache_pool,
        console_pool,
        db_pool,
        &vm,
        &scalar,
        recalib_interval,
    );

    // ─── Position observers ────────────────────────────────────────────────────
    let regime_observers = config::create_regime_observers();
    let position_cache_pool = HandlePool::new("position-cache", position_cache_handles);
    let position_console_pool = HandlePool::new("position-console", position_console_handles);
    let position_db_pool = HandlePool::new("position-db", position_db_handles);
    let wired_position = wire_regime_observers(
        regime_observers,
        wired.position_queue_rxs,
        position_cache_pool,
        position_console_pool,
        position_db_pool,
        &vm,
        &scalar,
        noise_floor,
    );

    // ─── Treasury ───────────────────────────────────────────────────────────
    // One mailbox for ALL inputs: ticks from the main loop + requests from N brokers.
    // N+1 senders: 1 for the tick sender, N for broker handles.
    let num_treasury_senders = num_brokers + 1;
    let mut event_txs = Vec::with_capacity(num_treasury_senders);
    let mut event_rxs = Vec::with_capacity(num_treasury_senders);
    for _ in 0..num_treasury_senders {
        let (tx, rx) = queue_unbounded::<TreasuryEvent>();
        event_txs.push(tx);
        event_rxs.push(rx);
    }
    let event_mailbox_rx = mailbox(event_rxs);

    // The tick sender — main loop sends TreasuryEvent::Tick through this.
    let treasury_tick_sender = TreasuryTickSender::new(event_txs.pop().unwrap());

    // Per-broker response queues + handles.
    let mut client_txs: Vec<QueueSender<TreasuryResponse>> = Vec::with_capacity(num_brokers);
    let mut treasury_handles: Vec<TreasuryHandle> = Vec::with_capacity(num_brokers);
    for (i, event_tx) in event_txs.into_iter().enumerate() {
        let (resp_tx, resp_rx) = queue_bounded::<TreasuryResponse>(1);
        client_txs.push(resp_tx);
        treasury_handles.push(TreasuryHandle::new(i, event_tx, resp_rx));
    }

    // ─── Brokers ───────────────────────────────────────────────────────────
    let brokers = config::create_brokers(num_market, num_position, dims, recalib_interval);
    let broker_console_pool = HandlePool::new("broker-console", broker_console_handles);
    let broker_db_pool = HandlePool::new("broker-db", broker_db_handles);
    let broker_cache_pool = HandlePool::new("broker-cache", broker_cache_handles);
    let wired_brokers = wire_brokers(
        brokers,
        wired_position.output_rxs,
        treasury_handles,
        broker_cache_pool,
        broker_console_pool,
        broker_db_pool,
        &vm,
        &scalar,
    );

    // Spawn treasury thread.
    let treasury = Treasury::new(args.swap_fee, args.swap_fee);
    let base_deadline = 500;
    let treasury_handle = std::thread::spawn(move || {
        treasury_program(
            event_mailbox_rx,
            client_txs,
            treasury_console_handle,
            treasury_db_handle,
            treasury,
            base_deadline,
        )
    });

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
        // max window: sqrt(dims)+3 = 103 candles at D=10,000.
        // The rhythm trim caps at this — larger windows waste memory.
        let max_window = ((dims as f64).sqrt() as usize) + 3;
        pipelines.push(Pipeline {
            source,
            target,
            stream,
            bank: IndicatorBank::new(),
            count: 0,
            candle_window: Vec::with_capacity(max_window),
            max_window_size: max_window,
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
                    let t_tick = std::time::Instant::now();
                    let candle = pipeline.bank.tick(&ohlcv);
                    let ns_tick = t_tick.elapsed().as_nanos() as f64;
                    pipeline.count += 1;
                    encode_count += 1;

                    // Grow the candle window, trim to max.
                    let t_win = std::time::Instant::now();
                    pipeline.candle_window.push(candle.clone());
                    if pipeline.candle_window.len() > pipeline.max_window_size {
                        let excess = pipeline.candle_window.len() - pipeline.max_window_size;
                        pipeline.candle_window.drain(..excess);
                    }
                    let window: Arc<Vec<Candle>> = Arc::new(pipeline.candle_window.clone());
                    let ns_window = t_win.elapsed().as_nanos() as f64;

                    // Send candle to each observer
                    let t_send = std::time::Instant::now();
                    for tx in &wired.candle_txs {
                        let _ = tx.send(ObsInput {
                            candle: candle.clone(),
                            window: Arc::clone(&window),
                            encode_count,
                        });
                    }
                    let ns_send = t_send.elapsed().as_nanos() as f64;

                    // Send tick to treasury
                    treasury_tick_sender.send_tick(
                        pipeline.count,
                        candle.close,
                        candle.atr_ratio * candle.close,
                    );

                    if pipeline.count % 100 == 0 {
                        let elapsed = run_start.elapsed().as_secs_f64();
                        let throughput = if elapsed > 0.0 { pipeline.count as f64 / elapsed } else { 0.0 };
                        let interval_ms = last_report.elapsed().as_millis();
                        last_report = std::time::Instant::now();
                        stream_handles[i].out(format!(
                            "{}/{} candle {}: close={:.2} {:.1}/s {:.0}ms/100 tick={:.1}ms win={:.1}ms send={:.1}ms",
                            pipeline.source, pipeline.target, pipeline.count,
                            candle.close, throughput, interval_ms,
                            ns_tick / 1e6, ns_window / 1e6, ns_send / 1e6,
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

    // Drop topic handles — regime observers see disconnect as topics drain
    drop(wired.topic_handles);

    // Join regime observer threads — get the trained regime observers back
    for jh in wired_position.join_handles {
        match jh.join() {
            Ok(regime_obs) => {
                main_handle.out(format!(
                    "position-{}: done",
                    regime_obs.lens,
                ));
            }
            Err(_) => {
                main_handle.err("regime observer thread panicked".to_string());
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
                    "broker[{}] {}: trades={} grace={:.3} ev={:.2}",
                    broker.slot_idx,
                    broker.observer_names.join("/"),
                    broker.trade_count,
                    grace_rate,
                    broker.expected_value,
                ));
            }
            Err(_) => {
                main_handle.err("broker thread panicked".to_string());
            }
        }
    }

    // Treasury shutdown — drop tick sender, join thread.
    drop(treasury_tick_sender);
    match treasury_handle.join() {
        Ok(treasury) => {
            let total_papers: usize = treasury
                .proposer_records
                .values()
                .map(|r| r.paper_submitted)
                .sum();
            let total_survived: usize = treasury
                .proposer_records
                .values()
                .map(|r| r.paper_survived)
                .sum();
            let total_failed: usize = treasury
                .proposer_records
                .values()
                .map(|r| r.paper_failed)
                .sum();
            main_handle.out(format!(
                "treasury: papers={} survived={} failed={}",
                total_papers, total_survived, total_failed,
            ));
        }
        Err(_) => {
            main_handle.err("treasury thread panicked".to_string());
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
