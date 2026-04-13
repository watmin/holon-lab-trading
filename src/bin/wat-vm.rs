/// wat-vm — the second heartbeat. Reads candles, enriches them, feeds observers.
///
/// Candles flow to N market observers. Each observer encodes through its lens,
/// learns the noise subspace, predicts direction. Results are discarded.
/// The observers come home with experience.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use clap::Parser;

use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

use enterprise::domain::candle_stream::CandleStream;
use enterprise::domain::indicator_bank::IndicatorBank;
use enterprise::domain::ledger;
use enterprise::domain::config;
use enterprise::domain::market_observer::MarketObserver;
use enterprise::kernel::handle_pool::HandlePool;
use enterprise::encoding::thought_encoder::{ThoughtAST, ThoughtEncoder};
use enterprise::programs::app::market_observer_program::{ObsInput, ObsLearn};
use enterprise::programs::app::market_observer_program::market_observer_program;
use enterprise::programs::stdlib::cache::cache;
use enterprise::programs::stdlib::console::console;
use enterprise::programs::stdlib::database::database;
use enterprise::services::mailbox::mailbox;
use enterprise::services::queue::{queue_bounded, queue_unbounded, QueueSender};
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

struct WiredObservers {
    /// Senders to feed candles to each observer
    candle_txs: Vec<QueueSender<ObsInput>>,
    /// Thread handles — join to get trained observers back
    join_handles: Vec<std::thread::JoinHandle<MarketObserver>>,
    /// Topic handles — must live until shutdown
    topic_handles: Vec<enterprise::services::topic::TopicHandle>,
}

fn wire_market_observers(
    observers: Vec<MarketObserver>,
    mut cache_pool: HandlePool<enterprise::programs::stdlib::cache::CacheHandle<ThoughtAST, Vector>>,
    mut console_pool: HandlePool<enterprise::programs::stdlib::console::ConsoleHandle>,
    mut db_pool: HandlePool<enterprise::services::queue::QueueSender<LogEntry>>,
    encoder: Arc<ThoughtEncoder>,
    recalib_interval: usize,
) -> WiredObservers {
    let num_observers = observers.len();
    let mut candle_txs: Vec<QueueSender<ObsInput>> = Vec::with_capacity(num_observers);
    let mut join_handles: Vec<std::thread::JoinHandle<MarketObserver>> =
        Vec::with_capacity(num_observers);
    let mut topic_handles = Vec::with_capacity(num_observers);

    for (i, observer) in observers.into_iter().enumerate() {
        // Candle input queue
        let (candle_tx, candle_rx) = queue_bounded::<ObsInput>(1);
        candle_txs.push(candle_tx);

        // Output topic with zero consumers — results discarded
        let (result_tx, topic_handle) = topic::<MarketChain>(1, vec![]);
        topic_handles.push(topic_handle);

        // Learn mailbox — dummy, no learn signals
        let (learn_dummy_tx, learn_dummy_rx) = queue_unbounded::<ObsLearn>();
        drop(learn_dummy_tx); // no one sends learn signals
        let learn_rx = mailbox(vec![learn_dummy_rx]);

        // Cache handle for this observer
        let obs_cache = cache_pool.pop();

        // Console handle for this observer
        let obs_console = console_pool.pop();

        // DB sender — real database
        let db_tx = db_pool.pop();

        let enc = Arc::clone(&encoder);
        let jh = std::thread::spawn(move || {
            market_observer_program(
                candle_rx,
                result_tx,
                learn_rx,
                obs_cache,
                obs_console,
                db_tx,
                observer,
                enc,
                i,
                recalib_interval,
            )
        });
        join_handles.push(jh);
    }

    // Assert all pooled handles were claimed — orphans cause deadlocks.
    // If any finish() is forgotten, Drop fires here at function return.
    console_pool.finish();
    cache_pool.finish();
    db_pool.finish();

    WiredObservers {
        candle_txs,
        join_handles,
        topic_handles,
    }
}

// ─── Main ───────────────────────────────────────────────────────────────────

fn main() {
    let args = Args::parse();
    let num_observers = config::MARKET_LENSES.len();
    let dims = args.dims;
    let recalib_interval = args.recalib_interval;

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

    // Console: one handle per stream + one per observer + one for main
    let num_console = parsed.len() + num_observers + 1;
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
    let (db_senders, db_driver) = database::<LogEntry>(
        &db_path,
        num_observers,
        100,
        ledger::ledger_setup,
        ledger::ledger_insert,
    );

    let db_pool = HandlePool::new("db", db_senders);

    main_handle.out(format!("db: {}", db_path));

    // ─── ThoughtEncoder + Cache ────────────────────────────────────────────
    let vm = VectorManager::new(dims);
    let encoder = Arc::new(ThoughtEncoder::new(vm));

    let (cache_handles, cache_driver) =
        cache::<ThoughtAST, Vector>("encoder", 65536, num_observers);
    let cache_pool = HandlePool::new("cache", cache_handles);

    // ─── Market observers ──────────────────────────────────────────────────
    let observers = config::create_market_observers(dims, recalib_interval);
    let wired = wire_market_observers(
        observers,
        cache_pool,
        console_pool,
        db_pool,
        Arc::clone(&encoder),
        recalib_interval,
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
        "{}D recalib={} observers={}",
        dims, recalib_interval, num_observers
    ));

    // ─── Per-stream loop ───────────────────────────────────────────────────
    let max = args.max_candles;
    let mut encode_count: usize = 0;
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

                    if pipeline.count % 500 == 0 {
                        stream_handles[i].out(format!(
                            "{}/{} candle {}: close={:.2}",
                            pipeline.source, pipeline.target, pipeline.count, candle.close
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

    // Drop candle senders — observers see disconnect
    drop(wired.candle_txs);

    // Join observer threads — get the trained observers back
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
                main_handle.err("observer thread panicked".to_string());
            }
        }
    }

    main_handle.out(format!("results: {}", db_path));

    // Drop all handles, join drivers
    drop(stream_handles);
    drop(wired.topic_handles);
    db_driver.join();
    drop(main_handle);
    cache_driver.join();
    console_driver.join();
}
