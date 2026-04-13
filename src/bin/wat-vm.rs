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
use enterprise::domain::exit_observer::ExitObserver;
use enterprise::domain::indicator_bank::IndicatorBank;
use enterprise::domain::ledger;
use enterprise::domain::config;
use enterprise::domain::market_observer::MarketObserver;
use enterprise::kernel::handle_pool::HandlePool;
use enterprise::encoding::thought_encoder::{ThoughtAST, ThoughtEncoder};
use enterprise::programs::app::exit_observer_program::{ExitLearn, ExitSlot};
use enterprise::programs::app::exit_observer_program::exit_observer_program;
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

struct WiredMarketObservers {
    /// Senders to feed candles to each observer
    candle_txs: Vec<QueueSender<ObsInput>>,
    /// Thread handles — join to get trained observers back
    join_handles: Vec<std::thread::JoinHandle<MarketObserver>>,
    /// Topic handles — must live until shutdown
    topic_handles: Vec<enterprise::services::topic::TopicHandle>,
    /// Exit slot receivers: exit_queue_rxs[mi][ei] — market observer mi, exit observer ei
    exit_queue_rxs: Vec<Vec<enterprise::services::queue::QueueReceiver<MarketChain>>>,
}

fn wire_market_observers(
    observers: Vec<MarketObserver>,
    num_exit_observers: usize,
    mut cache_pool: HandlePool<enterprise::programs::stdlib::cache::CacheHandle<ThoughtAST, Vector>>,
    mut console_pool: HandlePool<enterprise::programs::stdlib::console::ConsoleHandle>,
    mut db_pool: HandlePool<enterprise::services::queue::QueueSender<LogEntry>>,
    encoder: Arc<ThoughtEncoder>,
    recalib_interval: usize,
) -> WiredMarketObservers {
    let num_observers = observers.len();
    let mut candle_txs: Vec<QueueSender<ObsInput>> = Vec::with_capacity(num_observers);
    let mut join_handles: Vec<std::thread::JoinHandle<MarketObserver>> =
        Vec::with_capacity(num_observers);
    let mut topic_handles = Vec::with_capacity(num_observers);
    let mut exit_queue_rxs: Vec<Vec<enterprise::services::queue::QueueReceiver<MarketChain>>> =
        Vec::with_capacity(num_observers);

    for (i, observer) in observers.into_iter().enumerate() {
        // Candle input queue
        let (candle_tx, candle_rx) = queue_bounded::<ObsInput>(1);
        candle_txs.push(candle_tx);

        // Create M queues for fan-out to exit observers
        let mut exit_txs = Vec::with_capacity(num_exit_observers);
        let mut exit_rxs = Vec::with_capacity(num_exit_observers);
        for _ in 0..num_exit_observers {
            let (tx, rx) = queue_bounded::<MarketChain>(1);
            exit_txs.push(tx);
            exit_rxs.push(rx);
        }
        exit_queue_rxs.push(exit_rxs);

        // Output topic with M consumers — fan out to exit observers
        let (result_tx, topic_handle) = topic::<MarketChain>(1, exit_txs);
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
    console_pool.finish();
    cache_pool.finish();
    db_pool.finish();

    WiredMarketObservers {
        candle_txs,
        join_handles,
        topic_handles,
        exit_queue_rxs,
    }
}

// ─── Exit observer wiring ──────────────────────────────────────────────────

struct WiredExitObservers {
    /// Thread handles — join to get trained exit observers back
    join_handles: Vec<std::thread::JoinHandle<ExitObserver>>,
}

fn wire_exit_observers(
    exit_observers: Vec<ExitObserver>,
    exit_queue_rxs: Vec<Vec<enterprise::services::queue::QueueReceiver<MarketChain>>>,
    mut cache_pool: HandlePool<enterprise::programs::stdlib::cache::CacheHandle<ThoughtAST, Vector>>,
    mut console_pool: HandlePool<enterprise::programs::stdlib::console::ConsoleHandle>,
    mut db_pool: HandlePool<enterprise::services::queue::QueueSender<LogEntry>>,
    encoder: Arc<ThoughtEncoder>,
    noise_floor: f64,
) -> WiredExitObservers {
    let num_market = exit_queue_rxs.len();
    let num_exit = exit_observers.len();
    let mut join_handles: Vec<std::thread::JoinHandle<ExitObserver>> =
        Vec::with_capacity(num_exit);

    // Transpose: exit_queue_rxs[mi][ei] → slots[ei][mi]
    // We need to move receivers out, so consume the outer vec.
    let mut transposed: Vec<Vec<Option<enterprise::services::queue::QueueReceiver<MarketChain>>>> =
        Vec::with_capacity(num_exit);
    for _ in 0..num_exit {
        transposed.push(Vec::with_capacity(num_market));
    }
    for mi_rxs in exit_queue_rxs {
        for (ei, rx) in mi_rxs.into_iter().enumerate() {
            transposed[ei].push(Some(rx));
        }
    }

    for (ei, exit_obs) in exit_observers.into_iter().enumerate() {
        // Build N slots for this exit observer
        let slot_rxs: Vec<enterprise::services::queue::QueueReceiver<MarketChain>> = transposed[ei]
            .iter_mut()
            .map(|opt| opt.take().expect("each rx used exactly once"))
            .collect();

        let mut slots = Vec::with_capacity(num_market);
        for rx in slot_rxs {
            // Output to broker — dummy consumer drains the queue (broker not wired yet)
            let (discard_tx, discard_rx) = queue_unbounded();
            std::thread::spawn(move || { while discard_rx.recv().is_ok() {} });
            slots.push(ExitSlot {
                input_rx: rx,
                output_tx: discard_tx,
            });
        }

        // Learn mailbox — dummy, no learn signals yet
        let (learn_dummy_tx, learn_dummy_rx) = queue_unbounded::<ExitLearn>();
        drop(learn_dummy_tx);
        let learn_rx = mailbox(vec![learn_dummy_rx]);

        let obs_cache = cache_pool.pop();
        let obs_console = console_pool.pop();
        let db_tx = db_pool.pop();

        let enc = Arc::clone(&encoder);
        let jh = std::thread::spawn(move || {
            exit_observer_program(
                slots,
                learn_rx,
                obs_cache,
                obs_console,
                db_tx,
                exit_obs,
                enc,
                noise_floor,
                ei,
            )
        });
        join_handles.push(jh);
    }

    cache_pool.finish();
    console_pool.finish();
    db_pool.finish();

    WiredExitObservers {
        join_handles,
    }
}

// ─── Main ───────────────────────────────────────────────────────────────────

fn main() {
    let args = Args::parse();
    let num_market = config::MARKET_LENSES.len();
    let num_exit = config::EXIT_LENSES.len();
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

    // Console: one handle per stream + one per market observer + one per exit observer + one for main
    let num_console = parsed.len() + num_market + num_exit + 1;
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
        num_market + num_exit,
        100,
        ledger::ledger_setup,
        ledger::ledger_insert,
    );

    let mut db_pool = HandlePool::new("db", db_senders);

    main_handle.out(format!("db: {}", db_path));

    // ─── ThoughtEncoder + Cache ────────────────────────────────────────────
    let vm = VectorManager::new(dims);
    let encoder = Arc::new(ThoughtEncoder::new(vm));

    let (cache_handles, cache_driver) =
        cache::<ThoughtAST, Vector>("encoder", 65536, num_market + num_exit);
    let mut cache_pool = HandlePool::new("cache", cache_handles);

    // ─── Market observer pools (split from exit observer pools) ──────────
    // Pop exit observer handles first so market observer wiring gets the rest.
    let mut exit_console_handles = Vec::with_capacity(num_exit);
    let mut exit_cache_handles = Vec::with_capacity(num_exit);
    let mut exit_db_handles = Vec::with_capacity(num_exit);
    for _ in 0..num_exit {
        exit_console_handles.push(console_pool.pop());
        exit_cache_handles.push(cache_pool.pop());
        exit_db_handles.push(db_pool.pop());
    }

    // ─── Market observers ──────────────────────────────────────────────────
    let observers = config::create_market_observers(dims, recalib_interval);
    let wired = wire_market_observers(
        observers,
        num_exit,
        cache_pool,
        console_pool,
        db_pool,
        Arc::clone(&encoder),
        recalib_interval,
    );

    // ─── Exit observers ────────────────────────────────────────────────────
    let exit_observers = config::create_exit_observers(dims, recalib_interval);
    let exit_cache_pool = HandlePool::new("exit-cache", exit_cache_handles);
    let exit_console_pool = HandlePool::new("exit-console", exit_console_handles);
    let exit_db_pool = HandlePool::new("exit-db", exit_db_handles);
    let wired_exit = wire_exit_observers(
        exit_observers,
        wired.exit_queue_rxs,
        exit_cache_pool,
        exit_console_pool,
        exit_db_pool,
        Arc::clone(&encoder),
        noise_floor,
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
        "{}D recalib={} market={} exit={} noise_floor={:.4}",
        dims, recalib_interval, num_market, num_exit, noise_floor
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

    // Drop topic handles — exit observers see disconnect as topics drain
    drop(wired.topic_handles);

    // Join exit observer threads — get the trained exit observers back
    for jh in wired_exit.join_handles {
        match jh.join() {
            Ok(exit_obs) => {
                main_handle.out(format!(
                    "exit-{}: trail_exp={:.1} stop_exp={:.1} grace_rate={:.3}",
                    exit_obs.lens,
                    exit_obs.trail_reckoner.experience(),
                    exit_obs.stop_reckoner.experience(),
                    exit_obs.grace_rate,
                ));
            }
            Err(_) => {
                main_handle.err("exit observer thread panicked".to_string());
            }
        }
    }

    main_handle.out(format!("results: {}", db_path));

    // Drop all handles, join drivers
    drop(stream_handles);
    db_driver.join();
    drop(main_handle);
    cache_driver.join();
    console_driver.join();
}
