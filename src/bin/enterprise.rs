/// enterprise — self-organizing BTC trading enterprise.
///
/// Six primitives. Two templates. One heartbeat per candle.
/// See wat/bin/enterprise.wat for the specification.
///
/// The binary creates the world, feeds candles, writes the ledger,
/// and displays progress. It does not think. It orchestrates.
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use clap::Parser;
use crossbeam::channel::{self, Receiver, Sender};
use rusqlite::{params, Connection};

use enterprise::broker::Broker;
use enterprise::ctx::Ctx;
use enterprise::enums::{ExitLens, MarketLens, ScalarEncoding};
use enterprise::exit_observer::ExitObserver;
use enterprise::indicator_bank::IndicatorBank;
use enterprise::log_entry::LogEntry;
use enterprise::market_observer::MarketObserver;
use enterprise::post::Post;
use enterprise::raw_candle::{Asset, RawCandle};
use enterprise::scalar_accumulator::ScalarAccumulator;
use enterprise::treasury::Treasury;
use enterprise::enterprise::Enterprise;
use enterprise::window_sampler::WindowSampler;

// ─── Constants ───────────────────────────────────────────────────────────────

/// Max learn signals to drain per candle per thread.
/// The reckoner is a CRDT — deferral is safe. The queue drains over
/// subsequent candles. Production rate ~1/candle. Drain rate 5/candle.
/// The queue converges to empty.
const MAX_DRAIN: usize = 5;
const MARKET_LENSES: &[MarketLens] = &[
    MarketLens::Momentum,
    MarketLens::Structure,
    MarketLens::Volume,
    MarketLens::Narrative,
    MarketLens::Regime,
    MarketLens::Generalist,
];
const EXIT_LENSES: &[ExitLens] = &[
    ExitLens::Volatility,
    ExitLens::Structure,
    ExitLens::Timing,
    ExitLens::Generalist,
];

// ─── CLI ─────────────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "enterprise", about = "Self-organizing BTC trading enterprise")]
struct Args {
    /// Vector dimension. Higher = more expressive, slower.
    #[arg(long, default_value_t = 10000)]
    dims: usize,

    /// Observations between recalibrations.
    #[arg(long, default_value_t = 500)]
    recalib_interval: usize,

    /// Denomination — what "value" means.
    #[arg(long, default_value = "USD")]
    denomination: String,

    /// Source asset name.
    #[arg(long, default_value = "USDC")]
    source_asset: String,

    /// Target asset name.
    #[arg(long, default_value = "WBTC")]
    target_asset: String,

    /// Initial balance for the source asset.
    #[arg(long, default_value_t = 10000.0)]
    source_balance: f64,

    /// Initial balance for the target asset.
    #[arg(long, default_value_t = 0.0)]
    target_balance: f64,

    /// Raw OHLCV parquet file.
    #[arg(long)]
    parquet: PathBuf,

    /// Output SQLite ledger. Auto-generated if omitted.
    #[arg(long)]
    ledger: Option<PathBuf>,

    /// Stop after this many candles (0 = run all).
    #[arg(long, default_value_t = 0)]
    max_candles: usize,

    /// Per-swap fee as a fraction (0.0010 = 10bps).
    #[arg(long, default_value_t = 0.0010)]
    swap_fee: f64,

    /// Slippage estimate per swap as a fraction (0.0025 = 25bps).
    #[arg(long, default_value_t = 0.0025)]
    slippage: f64,

    /// Maximum candle history per post.
    #[arg(long, default_value_t = 2016)]
    max_window_size: usize,
}

// ─── Parquet stream ──────────────────────────────────────────────────────────

#[cfg(feature = "parquet")]
struct ParquetRawStream {
    buffer: Vec<RawCandle>,
    buf_idx: usize,
    reader: parquet::arrow::arrow_reader::ParquetRecordBatchReader,
    source_asset: String,
    target_asset: String,
}

#[cfg(feature = "parquet")]
impl ParquetRawStream {
    fn open(path: &Path, source_asset: &str, target_asset: &str) -> Self {
        use parquet::arrow::arrow_reader::ParquetRecordBatchReaderBuilder;
        let file = std::fs::File::open(path).expect("failed to open parquet");
        let builder =
            ParquetRecordBatchReaderBuilder::try_new(file).expect("failed to read parquet");
        let reader = builder.build().expect("failed to build reader");
        Self {
            buffer: Vec::new(),
            buf_idx: 0,
            reader,
            source_asset: source_asset.to_string(),
            target_asset: target_asset.to_string(),
        }
    }

    fn total_candles(path: &Path) -> usize {
        use parquet::file::reader::{FileReader, SerializedFileReader};
        let file = std::fs::File::open(path).expect("failed to open parquet for metadata");
        let reader =
            SerializedFileReader::new(file).expect("failed to read parquet metadata");
        reader.metadata().file_metadata().num_rows() as usize
    }

    fn fill_buffer(&mut self) -> bool {
        use arrow::array::{Array, Float64Array, StringArray, TimestampMicrosecondArray};

        loop {
            match self.reader.next() {
                Some(Ok(batch)) => {
                    if batch.num_rows() == 0 {
                        continue;
                    }
                    let ts_col = batch.column_by_name("ts").expect("missing ts");
                    let open_col = batch.column_by_name("open").expect("missing open");
                    let high_col = batch.column_by_name("high").expect("missing high");
                    let low_col = batch.column_by_name("low").expect("missing low");
                    let close_col = batch.column_by_name("close").expect("missing close");
                    let vol_col = batch.column_by_name("volume").expect("missing volume");

                    let ts_strings: Vec<String> =
                        if let Some(arr) = ts_col.as_any().downcast_ref::<StringArray>() {
                            (0..arr.len()).map(|i| arr.value(i).to_string()).collect()
                        } else if let Some(arr) = ts_col
                            .as_any()
                            .downcast_ref::<TimestampMicrosecondArray>()
                        {
                            (0..arr.len())
                                .map(|i| {
                                    let micros = arr.value(i);
                                    let secs = micros / 1_000_000;
                                    let nsecs = ((micros % 1_000_000) * 1000) as u32;
                                    chrono::DateTime::from_timestamp(secs, nsecs)
                                        .map(|dt| dt.format("%Y-%m-%d %H:%M:%S").to_string())
                                        .unwrap_or_default()
                                })
                                .collect()
                        } else {
                            panic!("unsupported timestamp column type");
                        };

                    let opens = open_col
                        .as_any()
                        .downcast_ref::<Float64Array>()
                        .expect("open not f64");
                    let highs = high_col
                        .as_any()
                        .downcast_ref::<Float64Array>()
                        .expect("high not f64");
                    let lows = low_col
                        .as_any()
                        .downcast_ref::<Float64Array>()
                        .expect("low not f64");
                    let closes = close_col
                        .as_any()
                        .downcast_ref::<Float64Array>()
                        .expect("close not f64");
                    let volumes = vol_col
                        .as_any()
                        .downcast_ref::<Float64Array>()
                        .expect("volume not f64");

                    self.buffer.clear();
                    self.buf_idx = 0;
                    for i in 0..batch.num_rows() {
                        self.buffer.push(RawCandle::new(
                            Asset::new(&self.source_asset),
                            Asset::new(&self.target_asset),
                            ts_strings[i].clone(),
                            opens.value(i),
                            highs.value(i),
                            lows.value(i),
                            closes.value(i),
                            volumes.value(i),
                        ));
                    }
                    return true;
                }
                Some(Err(e)) => panic!("parquet read error: {}", e),
                None => return false,
            }
        }
    }
}

#[cfg(feature = "parquet")]
impl Iterator for ParquetRawStream {
    type Item = RawCandle;

    fn next(&mut self) -> Option<RawCandle> {
        if self.buf_idx >= self.buffer.len() {
            if !self.fill_buffer() {
                return None;
            }
        }
        let raw = self.buffer[self.buf_idx].clone();
        self.buf_idx += 1;
        Some(raw)
    }
}

// ─── Ledger ──────────────────────────────────────────────────────────────────

fn init_ledger(path: &str) -> Connection {
    let conn = Connection::open(path).expect("failed to open ledger");
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT
        );
        CREATE TABLE IF NOT EXISTS brokers (
            slot_idx      INTEGER PRIMARY KEY,
            market_lens   TEXT NOT NULL,
            exit_lens     TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS log (
            step              INTEGER PRIMARY KEY AUTOINCREMENT,
            kind              TEXT NOT NULL,
            broker_slot_idx   INTEGER,
            trade_id          INTEGER,
            outcome           TEXT,
            amount            REAL,
            duration          INTEGER,
            reason            TEXT,
            observers_updated INTEGER
        );
        CREATE TABLE IF NOT EXISTS diagnostics (
            candle           INTEGER PRIMARY KEY,
            throughput       REAL,
            cache_hits       INTEGER,
            cache_misses     INTEGER,
            cache_hit_pct    REAL,
            cache_size       INTEGER,
            equity           REAL,
            us_settle        INTEGER,
            us_tick          INTEGER,
            us_observers     INTEGER,
            us_grid          INTEGER,
            us_brokers       INTEGER,
            us_propagate     INTEGER,
            us_triggers      INTEGER,
            us_fund          INTEGER,
            us_total         INTEGER,
            num_settlements  INTEGER,
            num_resolutions  INTEGER,
            num_active_trades INTEGER
        );

        CREATE TABLE IF NOT EXISTS observer_snapshots (
            candle          INTEGER,
            observer_idx    INTEGER,
            lens            TEXT,
            disc_strength   REAL,
            conviction      REAL,
            experience      REAL,
            resolved        INTEGER,
            recalib_count   INTEGER,
            last_prediction TEXT,
            PRIMARY KEY (candle, observer_idx)
        );

        CREATE TABLE IF NOT EXISTS broker_snapshots (
            candle            INTEGER,
            broker_slot_idx   INTEGER,
            edge              REAL,
            grace_count       INTEGER,
            violence_count    INTEGER,
            paper_count       INTEGER,
            trail_experience  REAL,
            stop_experience   REAL,
            PRIMARY KEY (candle, broker_slot_idx)
        );",
    )
    .expect("failed to create ledger tables");
    conn
}

fn register_brokers(conn: &Connection, post: &enterprise::post::Post) {
    let mut stmt = conn
        .prepare("INSERT INTO brokers (slot_idx, market_lens, exit_lens) VALUES (?1, ?2, ?3)")
        .expect("failed to prepare broker insert");
    let m = post.exit_observers.len();
    for broker in &post.registry {
        let mi = broker.slot_idx / m;
        let ei = broker.slot_idx % m;
        let market_name = format!("{}", post.market_observers[mi].lens);
        let exit_name = format!("{}", post.exit_observers[ei].lens);
        stmt.execute(rusqlite::params![broker.slot_idx as i64, market_name, exit_name]).ok();
    }
}

// ─── Construction ────────────────────────────────────────────────────────────

fn build_enterprise(args: &Args) -> (Enterprise, Ctx) {
    let dims = args.dims;
    let recalib_interval = args.recalib_interval;

    // Build ctx
    let ctx = Ctx::new(dims, recalib_interval);

    // Assets
    let source = Asset::new(&args.source_asset);
    let target = Asset::new(&args.target_asset);

    let n = MARKET_LENSES.len();
    let m = EXIT_LENSES.len();

    // Build market observers -- one per MarketLens variant
    let market_observers: Vec<MarketObserver> = MARKET_LENSES
        .iter()
        .enumerate()
        .map(|(i, lens)| {
            let seed = 7919 + i * 1000;
            MarketObserver::new(
                *lens,
                dims,
                recalib_interval,
                WindowSampler::new(seed, 12, args.max_window_size),
            )
        })
        .collect();

    // Build exit observers -- one per ExitLens variant
    let exit_observers: Vec<ExitObserver> = EXIT_LENSES
        .iter()
        .map(|lens| ExitObserver::new(*lens, dims, recalib_interval, 0.015, 0.030))
        .collect();

    // Build brokers -- N x M grid
    let registry: Vec<Broker> = (0..(n * m))
        .map(|slot_idx| {
            let mi = slot_idx / m;
            let ei = slot_idx % m;
            let market_name = format!("{}", MARKET_LENSES[mi]);
            let exit_name = format!("{}", EXIT_LENSES[ei]);
            Broker::new(
                vec![market_name, exit_name],
                slot_idx,
                m,
                dims,
                recalib_interval,
                vec![
                    ScalarAccumulator::new("trail-distance", ScalarEncoding::Log, dims),
                    ScalarAccumulator::new("stop-distance", ScalarEncoding::Log, dims),
                ],
            )
        })
        .collect();

    // Build the post
    let the_post = Post::new(
        0,
        source.clone(),
        target.clone(),
        IndicatorBank::new(),
        args.max_window_size,
        market_observers,
        exit_observers,
        registry,
    );

    // Build treasury
    let mut initial_balances = HashMap::new();
    initial_balances.insert(args.source_asset.clone(), args.source_balance);
    initial_balances.insert(args.target_asset.clone(), args.target_balance);
    let the_treasury = Treasury::new(
        Asset::new(&args.denomination),
        initial_balances,
        args.swap_fee,
        args.slippage,
    );

    // Build enterprise
    let ent = Enterprise::new(vec![the_post], the_treasury);

    (ent, ctx)
}

// ─── Progress ────────────────────────────────────────────────────────────────

fn display_progress(ent: &Enterprise, candle_num: usize, elapsed_ms: f64) {
    let throughput = if elapsed_ms == 0.0 {
        0.0
    } else {
        candle_num as f64 * 1000.0 / elapsed_ms
    };
    let equity = ent.treasury.total_equity();

    eprintln!(
        "\n  candle={} throughput={:.0}/s equity={:.2}",
        candle_num, throughput, equity
    );

    // Per-post stats — iterate all posts
    for post in &ent.posts {

    // Per-observer stats
    for obs in &post.market_observers {
        eprintln!(
            "    market-{}: recalib={} experience={:.2} resolved={}",
            obs.lens,
            obs.reckoner.recalib_count(),
            obs.experience(),
            obs.resolved,
        );
    }

    // Per-broker stats
    for b in &post.registry {
        eprintln!(
            "    broker-{}: papers={} grace={:.4} violence={:.4} trades={} edge={:.4}",
            b.slot_idx,
            b.paper_count(),
            b.cumulative_grace,
            b.cumulative_violence,
            b.trade_count,
            b.edge(),
        );
    }

    } // end per-post iteration
}

// ─── Summary ─────────────────────────────────────────────────────────────────

fn display_summary(
    ent: &Enterprise,
    total_candles: usize,
    elapsed_ms: f64,
    bnh_entry: f64,
    last_close: f64,
    swap_fee: f64,
    slippage: f64,
    log_step: usize,
    ledger_path: &str,
) {
    let equity = ent.treasury.total_equity();
    let throughput = if elapsed_ms == 0.0 {
        0.0
    } else {
        total_candles as f64 * 1000.0 / elapsed_ms
    };
    let total_trades: usize = ent.posts.iter().flat_map(|p| &p.registry).map(|b| b.trade_count).sum();
    let total_grace: f64 = ent.posts.iter().flat_map(|p| &p.registry).map(|b| b.cumulative_grace).sum();
    let total_violence: f64 = ent.posts.iter().flat_map(|p| &p.registry).map(|b| b.cumulative_violence).sum();
    let win_rate = if total_trades == 0 {
        0.0
    } else {
        total_grace / (total_grace + total_violence) * 100.0
    };

    let initial_equity = ent
        .treasury
        .available
        .values()
        .chain(ent.treasury.reserved.values())
        .sum::<f64>();
    let ret = if initial_equity == 0.0 {
        0.0
    } else {
        (equity - initial_equity) / initial_equity * 100.0
    };
    let bnh_ret = if bnh_entry == 0.0 {
        0.0
    } else {
        (last_close - bnh_entry) / bnh_entry * 100.0
    };

    let venue_rt = 2.0 * (swap_fee + slippage) * 100.0;

    eprintln!();
    eprintln!("=== SUMMARY ===");
    eprintln!(
        "  candles: {} throughput: {:.0}/s",
        total_candles, throughput
    );
    eprintln!("  equity: {:.2} ({:+.2}%)", equity, ret);
    eprintln!("  buy-and-hold: {:+.2}%", bnh_ret);
    eprintln!(
        "  trades: {} grace: {:.4} violence: {:.4}",
        total_trades, total_grace, total_violence
    );
    eprintln!("  win-rate: {:.2}%", win_rate);
    if swap_fee > 0.0 || slippage > 0.0 {
        eprintln!(
            "  venue: {:.1}bps fee + {:.1}bps slippage = {:.2}% round trip",
            swap_fee * 10000.0,
            slippage * 10000.0,
            venue_rt
        );
    }

    // Observer panel — iterate all posts
    eprintln!();
    eprintln!("  Observer panel:");
    for post in &ent.posts {
        for obs in &post.market_observers {
            eprintln!(
                "    {}: recalib={} experience={:.2} resolved={}",
                obs.lens,
                obs.reckoner.recalib_count(),
                obs.experience(),
                obs.resolved,
            );
        }
    }

    eprintln!();
    eprintln!("  Run DB: {} ({} rows)", ledger_path, log_step);
    eprintln!("===============");
}

// ─── Main ────────────────────────────────────────────────────────────────────

#[cfg(feature = "parquet")]
fn main() {
    let args = Args::parse();

    eprintln!("enterprise: four-step loop, {} observers, {} exit, {} brokers",
        MARKET_LENSES.len(), EXIT_LENSES.len(),
        MARKET_LENSES.len() * EXIT_LENSES.len());
    eprintln!("  {}D  recalib={}  max-window={}",
        args.dims, args.recalib_interval, args.max_window_size);
    if args.swap_fee > 0.0 || args.slippage > 0.0 {
        let rt = 2.0 * (args.swap_fee + args.slippage) * 100.0;
        eprintln!(
            "  venue: {:.1}bps fee + {:.1}bps slippage = {:.2}% round trip",
            args.swap_fee * 10000.0,
            args.slippage * 10000.0,
            rt
        );
    }

    // ─ Parquet stream ─
    let total_candles = ParquetRawStream::total_candles(&args.parquet);
    eprintln!("  Parquet: {:?} ({} candles)", args.parquet, total_candles);
    let raw_stream = ParquetRawStream::open(&args.parquet, &args.source_asset, &args.target_asset);

    // ─ Construction ─
    let (mut ent, ctx) = build_enterprise(&args);

    // ─ Ledger ─
    let ledger_path = match &args.ledger {
        Some(p) => {
            if let Some(parent) = p.parent() {
                std::fs::create_dir_all(parent).ok();
            }
            p.display().to_string()
        }
        None => {
            let ts = chrono::Utc::now().format("%Y%m%d_%H%M%S");
            std::fs::create_dir_all("runs").ok();
            format!("runs/enterprise_{}.db", ts)
        }
    };
    let ledger = init_ledger(&ledger_path);

    // Meta table
    {
        let mut stmt = ledger
            .prepare("INSERT INTO meta (key,value) VALUES (?1,?2)")
            .unwrap();
        for (k, v) in &[
            ("binary", "enterprise".to_string()),
            ("dims", args.dims.to_string()),
            ("recalib_interval", args.recalib_interval.to_string()),
            ("denomination", args.denomination.clone()),
            ("source_asset", args.source_asset.clone()),
            ("target_asset", args.target_asset.clone()),
            ("source_balance", args.source_balance.to_string()),
            ("target_balance", args.target_balance.to_string()),
            ("max_candles", args.max_candles.to_string()),
            ("swap_fee", args.swap_fee.to_string()),
            ("slippage", args.slippage.to_string()),
            ("max_window_size", args.max_window_size.to_string()),
            ("total_candles", total_candles.to_string()),
        ] {
            stmt.execute(params![k, v]).ok();
        }
    }
    // Register broker lens names
    for post in &ent.posts {
        register_brokers(&ledger, post);
    }
    eprintln!("  Run database: {}", ledger_path);

    // ─ Loop config ─
    let end_idx = if args.max_candles > 0 {
        args.max_candles.min(total_candles)
    } else {
        total_candles
    };
    let progress_every = 50;

    let kill_file = Path::new("trader-stop");
    let mut bnh_entry: f64 = 0.0;
    let mut last_close: f64 = 0.0;
    let t_start = Instant::now();
    let mut candle_num: usize = 0;

    // Log service — the DB writer as a pipe.
    // One handle for the main thread. The log service owns the SQLite connection.
    // 1 main + N observers + N*M brokers = 1 + 6 + 24 = 31 handles
    let n_log_handles = 1 + MARKET_LENSES.len() + MARKET_LENSES.len() * EXIT_LENSES.len();
    let (log_service, mut log_handles) = enterprise::log_service::LogService::spawn(n_log_handles, ledger);
    let log_handle = log_handles.pop().unwrap();

    eprintln!("\n  Walk-forward: up to {} candles...", end_idx);

    // ─ The fold — everything is a pipe ─
    // Each unit is a thread. bounded(1) = lock step = lazy enumerator.
    // The fold decomposes into sub-folds connected by rendezvous channels.
    // The composition of folds IS the enterprise fold.
    // Per-post pipes: the outer loop iterates posts. No magic index.

    let n = MARKET_LENSES.len();
    let m = EXIT_LENSES.len();
    let ctx_arc = Arc::new(ctx);

    // Encoder service — the cache as a pipe.
    // 6 observer handles + 24 grid handles + 1 step-3c handle = 31
    let n_encoder_callers = n + (n * m) + 1;
    let (encoder_service, mut encoder_handles) =
        enterprise::encoder_service::EncoderService::spawn(n_encoder_callers, 65536);
    // Split handles: observers get [0..n], grid gets [n..n+n*m], step3c gets the last
    let step3c_handle = encoder_handles.pop().unwrap();
    let grid_handles: Vec<_> = encoder_handles.drain(n..).collect();
    let mut obs_encoder_handles: Vec<_> = encoder_handles.drain(..).collect();

    type ObsInput = (enterprise::candle::Candle, Arc<Vec<enterprise::candle::Candle>>, usize);
    type ObsOutput = (holon::kernel::vector::Vector, holon::memory::Prediction, f64,
                      Vec<(enterprise::thought_encoder::ThoughtAST, holon::kernel::vector::Vector)>);
    type ObsLearn = (holon::kernel::vector::Vector, enterprise::enums::Direction, f64);
    type BrokerInput = (holon::kernel::vector::Vector, enterprise::distances::Distances, f64,
                        enterprise::enums::Side, f64, enterprise::enums::Prediction);
    type BrokerOutput = (enterprise::proposal::Proposal, Vec<enterprise::broker::Resolution>);
    type BrokerLearn = (holon::kernel::vector::Vector, enterprise::enums::Outcome,
                        f64, enterprise::enums::Direction, enterprise::distances::Distances);

    /// Per-post pipe wiring. One per asset pair. No magic index.
    struct PostPipes {
        source_asset: String,
        target_asset: String,
        obs_txs: Vec<Sender<ObsInput>>,
        thought_rxs: Vec<Receiver<ObsOutput>>,
        learn_txs: Vec<Sender<ObsLearn>>,
        broker_in_txs: Vec<Sender<BrokerInput>>,
        broker_out_rxs: Vec<Receiver<BrokerOutput>>,
        broker_learn_txs: Vec<Sender<BrokerLearn>>,
        observer_handles: Vec<std::thread::JoinHandle<MarketObserver>>,
        broker_handles: Vec<std::thread::JoinHandle<Broker>>,
        m: usize,
    }

    // ── Setup pipes for EACH post — iterate, never index ──
    let mut all_pipes: Vec<PostPipes> = Vec::new();

    for post in &mut ent.posts {
        let mut obs_txs = Vec::new();
        let mut thought_rxs = Vec::new();
        let mut learn_txs = Vec::new();
        let mut observer_handles = Vec::new();

        // Observer channels + threads
        let mut observers: Vec<MarketObserver> = std::mem::take(&mut post.market_observers);
        for i in 0..n {
            let (obs_tx, obs_rx) = channel::bounded::<ObsInput>(1);
            let (thought_tx, thought_rx) = channel::bounded::<ObsOutput>(1);
            let (learn_tx, learn_rx) = channel::unbounded::<ObsLearn>();

            obs_txs.push(obs_tx);
            thought_rxs.push(thought_rx);
            learn_txs.push(learn_tx);

            let mut obs = std::mem::replace(&mut observers[i], MarketObserver::new(
                MarketLens::Momentum, 10, 500, WindowSampler::new(0, 12, 2016)));
            let ctx_ref = Arc::clone(&ctx_arc);
            let enc_handle = obs_encoder_handles.pop().unwrap();
            let obs_log = log_handles.pop().unwrap();
            let lens = obs.lens;
            let obs_idx = i;
            let recalib = args.recalib_interval;

            let handle = std::thread::spawn(move || {
                let mut candle_count = 0usize;
                while let Ok((candle, window, _encode_count)) = obs_rx.recv() {
                    candle_count += 1;
                    // Drain at most MAX_DRAIN learn signals per candle.
                    // The learning is eventually consistent — the CRDT converges.
                    // The queue drains over subsequent candles.
                    {
                        let mut drained = 0;
                        while drained < MAX_DRAIN {
                            match learn_rx.try_recv() {
                                Ok((thought, direction, weight)) => {
                                    obs.resolve(&thought, direction, weight, recalib);
                                    drained += 1;
                                }
                                Err(_) => break,
                            }
                        }
                    }
                    let facts = enterprise::post::market_lens_facts_pub(&lens, &candle, &*window);
                    let bundle_ast = enterprise::thought_encoder::ThoughtAST::Bundle(facts);

                    // Cache pipe: get from encoder service
                    let thought = match enc_handle.get(&bundle_ast) {
                        Some(cached) => cached,
                        None => {
                            // Miss — compute locally, install all sub-tree misses
                            let (vec, misses) = ctx_ref.thought_encoder.encode(&bundle_ast);
                            for (ast, v) in misses {
                                enc_handle.set(ast, v);
                            }
                            vec
                        }
                    };

                    let result = obs.observe(thought, Vec::new());

                    // Snapshot every 100 candles — into the DB
                    if candle_count % 100 == 0 {
                        obs_log.log(LogEntry::ObserverSnapshot {
                            candle: candle_count,
                            observer_idx: obs_idx,
                            lens: format!("{}", lens),
                            disc_strength: obs.reckoner.last_disc_strength(),
                            conviction: result.prediction.conviction,
                            experience: obs.experience(),
                            resolved: obs.resolved,
                            recalib_count: obs.reckoner.recalib_count(),
                            last_prediction: format!("{:?}", obs.last_prediction),
                        });
                    }

                    let _ = thought_tx.send((result.thought, result.prediction, result.edge, vec![]));
                }
                obs
            });
            observer_handles.push(handle);
        }

        // Broker channels + threads
        let mut broker_in_txs = Vec::new();
        let mut broker_out_rxs = Vec::new();
        let mut broker_learn_txs = Vec::new();
        let mut broker_handles = Vec::new();
        let mut brokers: Vec<Broker> = std::mem::take(&mut post.registry);
        let source_asset = post.source_asset.clone();
        let target_asset = post.target_asset.clone();

        for slot_idx in 0..(n * m) {
            let (in_tx, in_rx) = channel::bounded::<BrokerInput>(1);
            let (out_tx, out_rx) = channel::bounded::<BrokerOutput>(1);
            let (blearn_tx, blearn_rx) = channel::unbounded::<BrokerLearn>();

            broker_in_txs.push(in_tx);
            broker_out_rxs.push(out_rx);
            broker_learn_txs.push(blearn_tx);

            let mut broker = std::mem::replace(&mut brokers[slot_idx], Broker::new(
                vec![], 0, 0, 10, 500, vec![]));
            let src = source_asset.clone();
            let tgt = target_asset.clone();
            let post_idx_for_broker = all_pipes.len();
            let recalib = args.recalib_interval;
            let brk_log = log_handles.pop().unwrap();
            let brk_slot = slot_idx;

            let handle = std::thread::spawn(move || {
                let mut candle_count = 0usize;
                while let Ok((composed, dists, price, side, edge, pred)) = in_rx.recv() {
                    candle_count += 1;
                    // Drain at most MAX_DRAIN learn signals per candle.
                    // The reckoner is a CRDT. Deferral is safe. The queue drains
                    // over subsequent candles. Constant time per candle.
                    {
                        let mut drained = 0;
                        while drained < MAX_DRAIN {
                            match blearn_rx.try_recv() {
                                Ok((thought, outcome, weight, direction, optimal)) => {
                                    broker.propagate(&thought, outcome, weight, direction, &optimal,
                                        recalib, enterprise::post::ctx_scalar_encoder_placeholder());
                                    drained += 1;
                                }
                                Err(_) => break,
                            }
                        }
                    }
                    broker.propose(&composed);
                    broker.register_paper(composed.clone(), price, dists);
                    let resolutions = broker.tick_papers(price);

                    // Snapshot every 100 candles — into the DB
                    if candle_count % 100 == 0 {
                        brk_log.log(LogEntry::BrokerSnapshot {
                            candle: candle_count,
                            broker_slot_idx: brk_slot,
                            edge: broker.edge(),
                            grace_count: broker.trade_count,
                            violence_count: broker.trade_count - (broker.cumulative_grace > broker.cumulative_violence) as usize,
                            paper_count: broker.papers.len(),
                            trail_experience: broker.scalar_accums.get(0).map_or(0.0, |a| a.count as f64),
                            stop_experience: broker.scalar_accums.get(1).map_or(0.0, |a| a.count as f64),
                        });
                    }

                    let prop = enterprise::proposal::Proposal::new(
                        composed, dists, edge, side, src.clone(), tgt.clone(),
                        pred, post_idx_for_broker, broker.slot_idx);
                    let _ = out_tx.send((prop, resolutions));
                }
                broker
            });
            broker_handles.push(handle);
        }

        all_pipes.push(PostPipes {
            source_asset: source_asset.name.clone(),
            target_asset: target_asset.name.clone(),
            obs_txs,
            thought_rxs,
            learn_txs,
            broker_in_txs,
            broker_out_rxs,
            broker_learn_txs,
            observer_handles,
            broker_handles,
            m,
        });
    }

    // ── The fold — main thread is a ROUTER ────────────────────────
    // Each candle routes to the right post's pipes by asset pair.
    // Cache misses flow to the encoder service via .set() at each call site.
    // The ctx's own HashMap is the pre-pipe cache — redundant now.
    // The encoder service IS the cache. No accumulated_misses needed.

    for rc in raw_stream {
        if args.max_candles > 0 && candle_num >= args.max_candles {
            break;
        }

        if candle_num % 1000 == 0 && kill_file.exists() {
            eprintln!("\n  Kill switch triggered at candle {}", candle_num);
            std::fs::remove_file(kill_file).ok();
            break;
        }

        if candle_num == 0 {
            bnh_entry = rc.close;
        }
        last_close = rc.close;

        // Route candle to the right post by asset pair
        let pipes = all_pipes.iter().enumerate().find(|(_, p)| {
            p.source_asset == rc.source_asset.name && p.target_asset == rc.target_asset.name
        });
        let (post_idx, pipes) = match pipes {
            Some((idx, p)) => (idx, p),
            None => continue, // No post for this candle's pair — skip
        };
        let t_candle = std::time::Instant::now();

        // Step 1: SETTLE TRIGGERED TRADES
        {
            let mut current_prices = std::collections::HashMap::new();
            for p in &ent.posts {
                current_prices.insert(
                    (p.source_asset.name.clone(), p.target_asset.name.clone()),
                    p.current_price(),
                );
            }
            let (settlements, settle_logs) = ent.treasury.settle_triggered(&current_prices);
            for entry in settle_logs { log_handle.log(entry); }

            for stl in &settlements {
                let slot = stl.trade.broker_slot_idx;
                let stl_post_idx = stl.trade.post_idx;
                let mi = slot / pipes.m;
                let ei = slot % pipes.m;

                let direction = if stl.exit_price > stl.trade.entry_price {
                    enterprise::enums::Direction::Up
                } else {
                    enterprise::enums::Direction::Down
                };
                let optimal = enterprise::simulation::compute_optimal_distances(
                    &stl.trade.price_history, direction);

                // Market observer learns via channel
                if let Some(stl_pipes) = all_pipes.get(stl_post_idx) {
                    if mi < stl_pipes.learn_txs.len() {
                        let _ = stl_pipes.learn_txs[mi].send((
                            stl.composed_thought.clone(), direction, stl.amount));
                    }
                    // Broker learns via channel
                    if slot < stl_pipes.broker_learn_txs.len() {
                        let _ = stl_pipes.broker_learn_txs[slot].send((
                            stl.composed_thought.clone(), stl.outcome, stl.amount,
                            direction, optimal));
                    }
                }
                // Exit observer learns on main thread
                if stl_post_idx < ent.posts.len() && ei < ent.posts[stl_post_idx].exit_observers.len() {
                    ent.posts[stl_post_idx].exit_observers[ei].observe_distances(
                        &stl.composed_thought, &optimal, stl.amount);
                }
            }
        }

        let t_step1 = t_candle.elapsed();

        let post = &mut ent.posts[post_idx];

        // Step 2: Tick indicator bank (sequential — streaming state)
        let enriched = post.indicator_bank.tick(&rc);
        post.candle_window.push_back(enriched.clone());
        while post.candle_window.len() > post.max_window_size {
            post.candle_window.pop_front();
        }
        post.encode_count += 1;

        let window: Arc<Vec<enterprise::candle::Candle>> = Arc::new(post.candle_window.iter().cloned().collect());
        let encode_count = post.encode_count;

        let t_tick = t_candle.elapsed();

        // Fan-out: send enriched candle to all observers (product — each gets a clone)
        for tx in &pipes.obs_txs {
            let _ = tx.send((enriched.clone(), Arc::clone(&window), encode_count));
        }

        // Collect thoughts from all observers (bounded(1) — they block until we read)
        let mut market_thoughts = Vec::with_capacity(n);
        let mut market_predictions: Vec<holon::memory::Prediction> = Vec::with_capacity(n);
        let mut market_edges = Vec::with_capacity(n);

        for rx in &pipes.thought_rxs {
            let (thought, pred, edge, _) = rx.recv().unwrap();
            market_thoughts.push(thought);
            market_predictions.push(pred);
            market_edges.push(edge);
        }

        let t_observers = t_candle.elapsed();

        // N×M grid: parallel computation → send to broker pipes
        let price = post.current_price();
        let ctx_ref = &*ctx_arc;

        // Compute values in parallel (pure reads, scoped borrow)
        use rayon::prelude::*;
        let grid_values: Vec<_> = {
            let exit_observers = &post.exit_observers;
            // Brokers are on threads — read scalar_accums from... we need them here.
            // For now: edge is 0.0 (brokers are on threads, we can't read them).
            // The broker thread will compute edge internally.
            (0..(n * m))
            .into_par_iter()
            .map(|slot_idx| {
                let mi = slot_idx / m;
                let ei = slot_idx % m;

                let exit_facts = enterprise::post::exit_lens_facts_pub(
                    &exit_observers[ei].lens, &enriched);
                let exit_bundle = enterprise::thought_encoder::ThoughtAST::Bundle(exit_facts);

                // Cache pipe: check encoder service
                let exit_vec = match grid_handles[slot_idx].get(&exit_bundle) {
                    Some(cached) => cached,
                    None => {
                        let (vec, misses) = ctx_ref.thought_encoder.encode(&exit_bundle);
                        for (ast, v) in misses {
                            grid_handles[slot_idx].set(ast, v);
                        }
                        vec
                    }
                };

                let composed = holon::kernel::primitives::Primitives::bundle(
                    &[&market_thoughts[mi], &exit_vec]);

                // Distances from exit observer — reckoner prediction or default.
                let empty_accums: Vec<enterprise::scalar_accumulator::ScalarAccumulator> = Vec::new();
                let (dists, _) = exit_observers[ei].recommended_distances(
                    &composed, &empty_accums, ctx_ref.thought_encoder.scalar_encoder());

                let side = enterprise::post::derive_side_pub(&market_predictions[mi]);
                let edge = 0.0_f64; // Broker computes edge on its thread
                let pred = enterprise::post::prediction_convert_pub(&market_predictions[mi]);

                (slot_idx, composed, dists, side, edge, pred)
            })
            .collect()
        };

        let t_grid = t_candle.elapsed();

        // Send to broker pipes — bounded(1), each broker gets its input
        for (slot_idx, composed, dists, side, edge, pred) in grid_values {
            let _ = pipes.broker_in_txs[slot_idx].send((composed, dists, price, side, edge, pred));
        }

        // Collect from broker pipes — bounded(1), all 24 produce
        let mut all_resolutions = Vec::new();
        for rx in &pipes.broker_out_rxs {
            let (prop, resolutions) = rx.recv().unwrap();
            ent.treasury.submit_proposal(prop);
            for res in &resolutions {
                log_handle.log(LogEntry::PaperResolved {
                    broker_slot_idx: res.broker_slot_idx,
                    outcome: res.outcome,
                    optimal_distances: res.optimal_distances,
                });
            }
            all_resolutions.extend(resolutions);
        }

        let t_brokers = t_candle.elapsed();

        // Propagate — send learning signals to pipes + parallel exit observer learning.
        // Channel sends: cheap, sequential. Exit observer vec ops: parallel by observer.
        {
            // Collect exit learning work grouped by exit observer index
            let mut exit_work: Vec<Vec<(usize, usize)>> = vec![Vec::new(); m];
            for (ri, res) in all_resolutions.iter().enumerate() {
                let mi = res.broker_slot_idx / m;
                let ei = res.broker_slot_idx % m;

                // Market observer: learn via channel (cheap — just a send)
                if mi < pipes.learn_txs.len() {
                    let _ = pipes.learn_txs[mi].send((
                        res.composed_thought.clone(), res.direction, res.amount));
                }

                // Broker: learn via channel (cheap — just a send)
                let _ = pipes.broker_learn_txs[res.broker_slot_idx].send((
                    res.composed_thought.clone(), res.outcome, res.amount,
                    res.direction, res.optimal_distances));

                // Collect exit work — apply in parallel below
                if ei < m {
                    exit_work[ei].push((ei, ri));
                }
            }

            // Exit observer learning — parallel across M exit observers, sequential within.
            // Each exit observer is independent. MAX_DRAIN per observer.
            post.exit_observers
                .par_iter_mut()
                .zip(exit_work.par_iter())
                .for_each(|(eobs, work)| {
                    let mut drained = 0;
                    for &(_ei, ri) in work {
                        if drained >= MAX_DRAIN { break; }
                        let res = &all_resolutions[ri];
                        eobs.observe_distances(
                            &res.composed_thought, &res.optimal_distances, res.amount);
                        drained += 1;
                    }
                });
        }

        let t_propagate = t_candle.elapsed();

        // Step 3c: UPDATE TRIGGERS — refresh stop distances on active trades
        // Parallel: each trade's trigger update is independent.
        {
            let trade_info: Vec<_> = ent.treasury.trades.iter()
                .filter(|(_, t)| t.post_idx == post_idx &&
                    (t.phase == enterprise::enums::TradePhase::Active
                  || t.phase == enterprise::enums::TradePhase::Runner))
                .map(|(id, t)| (*id, t.broker_slot_idx, t.side))
                .collect();

            let ctx_ref = &*ctx_arc;

            // Pre-encode exit vecs per exit observer (M, not per-trade).
            // Each exit lens produces the same facts for the same candle.
            let exit_vecs: Vec<_> = (0..pipes.m)
                .map(|ei| {
                    let exit_facts = enterprise::post::exit_lens_facts_pub(
                        &post.exit_observers[ei].lens, &enriched);
                    let exit_bundle = enterprise::thought_encoder::ThoughtAST::Bundle(exit_facts);
                    match step3c_handle.get(&exit_bundle) {
                        Some(cached) => cached,
                        None => {
                            let (vec, misses) = ctx_ref.thought_encoder.encode(&exit_bundle);
                            for (ast, v) in misses {
                                step3c_handle.set(ast, v);
                            }
                            vec
                        }
                    }
                })
                .collect();

            // Parallel: compose + distance query per trade. Independent.
            let level_updates: Vec<_> = trade_info
                .par_iter()
                .filter_map(|&(tid, slot, side)| {
                    let mi = slot / pipes.m;
                    let ei = slot % pipes.m;
                    if mi < market_thoughts.len() && ei < post.exit_observers.len() {
                        let composed = holon::kernel::primitives::Primitives::bundle(
                            &[&market_thoughts[mi], &exit_vecs[ei]]);
                        let empty_accums: Vec<enterprise::scalar_accumulator::ScalarAccumulator> = Vec::new();
                        let (dists, _) = post.exit_observers[ei].recommended_distances(
                            &composed, &empty_accums, ctx_ref.thought_encoder.scalar_encoder());
                        let new_levels = dists.to_levels(price, side);
                        Some((tid, new_levels))
                    } else {
                        None
                    }
                })
                .collect();

            for (tid, levels) in level_updates {
                ent.treasury.update_trade_stops(tid, levels);
            }
        }

        let t_triggers = t_candle.elapsed();

        // Tick trade price histories
        for (_, trade) in ent.treasury.trades.iter_mut() {
            trade.tick(rc.close);
        }

        let t_misc = t_candle.elapsed();

        // Step 4: Fund proposals
        let fund_logs = ent.treasury.fund_proposals();
        for entry in fund_logs { log_handle.log(entry); }

        let t_fund = t_candle.elapsed();

        candle_num += 1;

        // Logs flow through the pipe. No batching. The log service writes.

        // Diagnostics every 10 candles — timing + counts + cache, all in the DB
        if candle_num % 10 == 0 && candle_num > 0 {
            let t_total = t_candle.elapsed();
            let elapsed_ms = t_start.elapsed().as_secs_f64() * 1000.0;
            let throughput = if elapsed_ms > 0.0 { candle_num as f64 * 1000.0 / elapsed_ms } else { 0.0 };
            let num_active = ent.treasury.trades.iter()
                .filter(|(_, t)| t.phase == enterprise::enums::TradePhase::Active
                              || t.phase == enterprise::enums::TradePhase::Runner)
                .count();
            log_handle.log(LogEntry::Diagnostic {
                candle: candle_num,
                throughput,
                cache_hits: encoder_service.hit_count(),
                cache_misses: encoder_service.miss_count(),
                cache_size: encoder_service.cache_len(),
                equity: ent.treasury.total_equity(),
                us_settle: t_step1.as_micros() as u64,
                us_tick: (t_tick - t_step1).as_micros() as u64,
                us_observers: (t_observers - t_tick).as_micros() as u64,
                us_grid: (t_grid - t_observers).as_micros() as u64,
                us_brokers: (t_brokers - t_grid).as_micros() as u64,
                us_propagate: (t_propagate - t_brokers).as_micros() as u64,
                us_triggers: (t_triggers - t_propagate).as_micros() as u64,
                us_fund: (t_fund - t_misc).as_micros() as u64,
                us_total: t_total.as_micros() as u64,
                num_settlements: 0, // TODO: count from step 1
                num_resolutions: all_resolutions.len(),
                num_active_trades: num_active,
            });
        }

        // Progress display to stderr — less frequent
        if candle_num % progress_every == 0 {
            let elapsed_ms = t_start.elapsed().as_secs_f64() * 1000.0;
            display_progress(&ent, candle_num, elapsed_ms);
        }
    }

    // ── Shutdown: close channels, join threads, restore observers + brokers ──
    // Iterate all posts — no magic index
    for (post_idx, pipes) in all_pipes.into_iter().enumerate() {
        // Drop senders to close channels — threads will exit their loops
        drop(pipes.obs_txs);
        drop(pipes.broker_in_txs);
        drop(pipes.learn_txs);
        drop(pipes.broker_learn_txs);

        // Join observer threads — restore to post
        let mut restored_observers = Vec::new();
        for handle in pipes.observer_handles {
            let obs = handle.join().unwrap();
            restored_observers.push(obs);
        }
        ent.posts[post_idx].market_observers = restored_observers;

        // Join broker threads — restore to post
        let mut restored_brokers = Vec::new();
        for handle in pipes.broker_handles {
            let broker = handle.join().unwrap();
            restored_brokers.push(broker);
        }
        ent.posts[post_idx].registry = restored_brokers;
    } // end per-post shutdown

    // Shutdown encoder service — report cache stats
    eprintln!("  Cache: {} hits, {} misses ({:.1}% hit rate)",
        encoder_service.hit_count(),
        encoder_service.miss_count(),
        if encoder_service.hit_count() + encoder_service.miss_count() > 0 {
            100.0 * encoder_service.hit_count() as f64
                / (encoder_service.hit_count() + encoder_service.miss_count()) as f64
        } else { 0.0 });
    // Drop remaining handles so the encoder thread can exit
    drop(grid_handles);
    drop(step3c_handle);
    encoder_service.shutdown();

    // Shutdown log service — drop handle, cascade closes pipe, writer drains and exits
    let log_rows = log_service.rows();
    drop(log_handle);
    log_service.shutdown();

    // ─ Summary ─
    let elapsed_ms = t_start.elapsed().as_secs_f64() * 1000.0;
    display_summary(
        &ent,
        candle_num,
        elapsed_ms,
        bnh_entry,
        last_close,
        args.swap_fee,
        args.slippage,
        log_rows,
        &ledger_path,
    );
}

#[cfg(not(feature = "parquet"))]
fn main() {
    eprintln!("enterprise binary requires the 'parquet' feature. Build with:");
    eprintln!("  cargo build --release --features parquet");
    std::process::exit(1);
}
