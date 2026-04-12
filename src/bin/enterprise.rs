/// enterprise — the binary. Creates the world, feeds candles, writes the ledger.
///
/// Orchestrates: ctx, enterprise, candle stream, progress display.
/// Does not think. Does not encode. Does not predict.
/// See wat/bin/enterprise.wat for the specification.
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
use enterprise::newtypes::{Amount, Price};
use enterprise::treasury::Treasury;
use enterprise::enterprise::Enterprise;
use enterprise::window_sampler::WindowSampler;

// ─── Constants ───────────────────────────────────────────────────────────────

// No MAX_DRAIN. All learning signals drain fully. The reckoner is a CRDT —
// order doesn't matter, batching doesn't matter. Drain everything.
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
            recalib_wins    INTEGER,
            recalib_total   INTEGER,
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
            disc_strength     REAL,
            last_conviction   REAL,
            curve_valid       INTEGER,
            resolved_count    INTEGER,
            proto_cos         REAL,
            fact_count        INTEGER,
            thought_ast       TEXT,
            PRIMARY KEY (candle, broker_slot_idx)
        );

        CREATE TABLE IF NOT EXISTS paper_details (
            rowid             INTEGER PRIMARY KEY AUTOINCREMENT,
            broker_slot_idx   INTEGER,
            outcome           TEXT,
            entry_price       REAL,
            extreme           REAL,
            excursion         REAL,
            trail_distance    REAL,
            stop_distance     REAL,
            optimal_trail     REAL,
            optimal_stop      REAL,
            duration          INTEGER,
            was_runner        INTEGER
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
    let mut ctx = Ctx::new(dims, recalib_interval);

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
        .map(|lens| ExitObserver::new(*lens, dims, recalib_interval, 0.0001, 0.0001))
        .collect();

    // Build brokers -- N x M grid
    // Defaults near zero — the market teaches the real distances.
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
                enterprise::distances::Distances::new(0.0001, 0.0001),
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
    initial_balances.insert(args.source_asset.clone(), Amount(args.source_balance));
    initial_balances.insert(args.target_asset.clone(), Amount(args.target_balance));
    let the_treasury = Treasury::new(
        Asset::new(&args.denomination),
        initial_balances,
        args.swap_fee,
        args.slippage,
    );

    // Build enterprise
    let ent = Enterprise::new(vec![the_post], the_treasury);

    // Proposal 027/028: Pre-register m: atoms with the VectorManager.
    // Walk a default candle through all market lenses, extract atom names,
    // encode m:-prefixed Linear facts once so the atoms exist before first candle.
    {
        let default_candle = enterprise::candle::Candle::default();
        let window = vec![default_candle.clone()];
        let mut registration_misses = Vec::new();
        let mut reg_scales = HashMap::new();
        for lens in MARKET_LENSES {
            let facts = enterprise::post::market_lens_facts(lens, &default_candle, &window, &mut reg_scales);
            for fact in &facts {
                let prefixed = enterprise::thought_encoder::ThoughtAST::Linear {
                    name: format!("m:{}", fact.name()),
                    value: 0.0,
                    scale: 1.0,
                };
                let (_, misses) = ctx.thought_encoder.encode(&prefixed);
                registration_misses.extend(misses);
            }
        }
        ctx.insert_cache_misses(registration_misses);
    }

    // Proposal 030: Pre-register opinion atoms (7 total).
    // Encode once with dummy values so the VectorManager knows them.
    {
        let mut reg_scales = HashMap::new();
        let opinion_facts = enterprise::vocab::broker::opinions::encode_market_opinions(0.0, 0.0, 0.0, &mut reg_scales);
        let exit_opinion_facts = enterprise::vocab::broker::opinions::encode_exit_opinions(0.001, 0.001, 0.0, 0.001, &mut reg_scales);
        let mut opinion_misses = Vec::new();
        for fact in opinion_facts.iter().chain(exit_opinion_facts.iter()) {
            let (_, misses) = ctx.thought_encoder.encode(fact);
            opinion_misses.extend(misses);
        }
        ctx.insert_cache_misses(opinion_misses);
    }

    // Proposal 031: Pre-register derived atoms (11 total).
    // Encode once with dummy values so the VectorManager knows them.
    {
        let mut reg_scales = HashMap::new();
        let derived_facts = enterprise::vocab::broker::derived::encode_broker_derived_facts(
            0.001, 0.001, 0.001, 0.0, 0.0, 0.001, 0.0, 1, 1.0, 0.001, 0.001, 0.001, &mut reg_scales,
        );
        let mut derived_misses = Vec::new();
        for fact in &derived_facts {
            let (_, misses) = ctx.thought_encoder.encode(fact);
            derived_misses.extend(misses);
        }
        ctx.insert_cache_misses(derived_misses);
    }

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
    let grace_pct = if (total_grace + total_violence) == 0.0 {
        0.0
    } else {
        total_grace / (total_grace + total_violence) * 100.0
    };

    let initial_equity: f64 = ent
        .treasury
        .available
        .values()
        .chain(ent.treasury.reserved.values())
        .map(|a| a.0)
        .sum();
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
    eprintln!("  grace-pct: {:.2}%", grace_pct);
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
    // Encoder handles: observers + grid + brokers + step3c
    let n_encoder_callers = n + (n * m) + (n * m) + 1;
    let (encoder_service, mut encoder_handles) =
        enterprise::encoder_service::EncoderService::spawn(n_encoder_callers, 65536);
    // Split handles: observers [0..n], grid [n..n+nm], brokers [n+nm..n+2nm], step3c last
    let step3c_handle = encoder_handles.pop().unwrap();
    let mut broker_encoder_handles: Vec<_> = encoder_handles.drain(n + n * m..).collect();
    let grid_handles: Vec<_> = encoder_handles.drain(n..).collect();
    let mut obs_encoder_handles: Vec<_> = encoder_handles.drain(..).collect();

    type ObsInput = (enterprise::candle::Candle, Arc<Vec<enterprise::candle::Candle>>, usize);
    type ObsOutput = (holon::kernel::vector::Vector, enterprise::thought_encoder::ThoughtAST, holon::memory::Prediction, f64,
                      Vec<(enterprise::thought_encoder::ThoughtAST, holon::kernel::vector::Vector)>);
    type ObsLearn = (holon::kernel::vector::Vector, enterprise::enums::Direction, f64);
    type BrokerInput = (holon::kernel::vector::Vector, holon::kernel::vector::Vector,
                        holon::kernel::vector::Vector, enterprise::enums::Direction,
                        Option<enterprise::distances::Distances>, f64,
                        enterprise::enums::Side, f64, enterprise::enums::Prediction,
                        enterprise::vocab::broker::input::BrokerMarketInput,
                        enterprise::vocab::broker::input::BrokerExitInput,
                        f64, f64, f64, f64);
    type BrokerOutput = (enterprise::proposal::Proposal, Vec<enterprise::broker::Resolution>, Vec<enterprise::broker::Resolution>);
    type BrokerLearn = (holon::kernel::vector::Vector, holon::kernel::vector::Vector,
                        holon::kernel::vector::Vector,
                        enterprise::enums::Outcome,
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

        // Observer channels + threads — consume the vec, no placeholders
        let observers: Vec<MarketObserver> = std::mem::take(&mut post.market_observers);
        for (obs_idx, mut obs) in observers.into_iter().enumerate() {
            let (obs_tx, obs_rx) = channel::bounded::<ObsInput>(1);
            let (thought_tx, thought_rx) = channel::bounded::<ObsOutput>(1);
            let (learn_tx, learn_rx) = channel::unbounded::<ObsLearn>();

            obs_txs.push(obs_tx);
            thought_rxs.push(thought_rx);
            learn_txs.push(learn_tx);

            let ctx_ref = Arc::clone(&ctx_arc);
            let enc_handle = obs_encoder_handles.pop().unwrap();
            let obs_log = log_handles.pop().unwrap();
            let lens = obs.lens;
            let recalib = args.recalib_interval;

            let handle = std::thread::spawn(move || {
                let mut candle_count = 0usize;
                let mut obs_scales = std::collections::HashMap::new();
                while let Ok((candle, window, _encode_count)) = obs_rx.recv() {
                    candle_count += 1;
                    // Drain at most MAX_DRAIN learn signals per candle.
                    // Drain all learn signals. No cap.
                    while let Ok((thought, direction, weight)) = learn_rx.try_recv() {
                        obs.resolve(&thought, direction, weight, recalib);
                    }
                    // Each observer samples its own window size
                    let ws = obs.window_sampler.sample(candle_count);
                    let full_len = window.len();
                    let start = if full_len > ws { full_len - ws } else { 0 };
                    let sliced: Vec<enterprise::candle::Candle> = window[start..].to_vec();
                    let facts = enterprise::post::market_lens_facts(&lens, &candle, &sliced, &mut obs_scales);
                    let bundle_ast = enterprise::thought_encoder::ThoughtAST::Bundle(facts);

                    // Cache pipe: check → compute → notify (all in one call)
                    let thought = enc_handle.encode(&bundle_ast, &ctx_ref.thought_encoder);

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
                            recalib_wins: obs.recalib_wins,
                            recalib_total: obs.recalib_total,
                            last_prediction: format!("{:?}", obs.last_prediction),
                        });
                    }

                    let _ = thought_tx.send((result.thought, bundle_ast, result.prediction, result.edge, vec![]));
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
        let brokers: Vec<Broker> = std::mem::take(&mut post.registry);
        let source_asset = post.source_asset.clone();
        let target_asset = post.target_asset.clone();

        // Consume the vec — no placeholders, no poison
        for (slot_idx, mut broker) in brokers.into_iter().enumerate() {
            let (in_tx, in_rx) = channel::bounded::<BrokerInput>(1);
            let (out_tx, out_rx) = channel::bounded::<BrokerOutput>(1);
            let (blearn_tx, blearn_rx) = channel::unbounded::<BrokerLearn>();

            broker_in_txs.push(in_tx);
            broker_out_rxs.push(out_rx);
            broker_learn_txs.push(blearn_tx);

            let src = source_asset.clone();
            let tgt = target_asset.clone();
            let post_idx_for_broker = all_pipes.len();
            let recalib = args.recalib_interval;
            let brk_log = log_handles.pop().unwrap();
            let brk_enc = broker_encoder_handles.pop().unwrap();
            let brk_ctx = Arc::clone(&ctx_arc);
            let brk_slot = slot_idx;

            let handle = std::thread::spawn(move || {
                let mut candle_count = 0usize;
                let mut broker_scales = std::collections::HashMap::new();
                while let Ok((composed, market_thought, exit_thought, prediction, reckoner_dists, price, side, edge, pred, market_input, exit_input, exit_grace_rate, exit_avg_residue, market_edge, atr_ratio)) = in_rx.recv() {
                    candle_count += 1;
                    // Drain all learn signals. No cap.
                    while let Ok((thought, market_thought, exit_thought_learn, outcome, weight, direction, optimal)) = blearn_rx.try_recv() {
                        broker.propagate(&thought, &market_thought, &exit_thought_learn, outcome, weight, direction, &optimal,
                            recalib, enterprise::post::ctx_scalar_encoder_placeholder());
                    }
                    // Broker owns the distance cascade: reckoner → accumulator → default
                    let dists = broker.cascade_distances(reckoner_dists);

                    // Proposal 029 Phase 3: Broker extracts from both stages' anomalies
                    // instead of bundling raw 10,000D vectors.
                    // Typed inputs enforce correct AST-anomaly pairing at compile time.
                    let dims = brk_ctx.dims;
                    let noise_floor = 5.0 / (dims as f64).sqrt();

                    // Extract market facts from the market anomaly (typed)
                    let market_present = market_input.extract_facts(
                        |ast| brk_enc.encode(ast, &brk_ctx.thought_encoder), noise_floor);

                    // Extract exit facts from the exit anomaly (typed)
                    let exit_present = exit_input.extract_facts(
                        |ast| brk_enc.encode(ast, &brk_ctx.thought_encoder), noise_floor);

                    // Proposal 030: Encode leaf observer opinions as scalar facts.
                    // Market: signed conviction (direction × magnitude), conviction, edge.
                    // Exit: trail, stop, grace-rate, avg-residue.
                    let market_conviction = match &pred {
                        enterprise::enums::Prediction::Discrete { conviction, .. } => *conviction,
                        enterprise::enums::Prediction::Continuous { .. } => 0.0,
                    };
                    let signed_conviction = if prediction == enterprise::enums::Direction::Up {
                        market_conviction
                    } else {
                        -market_conviction
                    };
                    let market_opinions = enterprise::vocab::broker::opinions::encode_market_opinions(
                        signed_conviction, market_conviction, market_edge, &mut broker_scales);
                    let exit_opinions = enterprise::vocab::broker::opinions::encode_exit_opinions(
                        dists.trail, dists.stop, exit_grace_rate, exit_avg_residue, &mut broker_scales);

                    // Broker's own self-assessment facts
                    let grace_rate = if broker.trade_count > 0 {
                        broker.cumulative_grace / (broker.cumulative_grace + broker.cumulative_violence).max(1e-10)
                    } else { 0.0 };
                    let self_facts = enterprise::vocab::broker::self_assessment::encode_broker_self_facts(
                        grace_rate,
                        broker.avg_paper_duration,
                        broker.papers.len(),
                        broker.last_trail,
                        broker.last_stop,
                        broker.resolution_count.saturating_sub(broker.reckoner.recalib_count() * recalib),
                        broker.avg_excursion,
                        &mut broker_scales,
                    );

                    // Proposal 031: Derived thoughts — cross-cutting ratios
                    let market_norm = market_thought.norm();
                    let exit_norm = exit_thought.norm();
                    let derived_facts = enterprise::vocab::broker::derived::encode_broker_derived_facts(
                        dists.trail, dists.stop, atr_ratio, signed_conviction,
                        exit_grace_rate, exit_avg_residue, grace_rate,
                        broker.papers.len(), broker.avg_paper_duration,
                        broker.avg_excursion, market_norm, exit_norm,
                        &mut broker_scales,
                    );

                    // Broker's full thought: opinions + extracted market + extracted exit + self-assessment + derived
                    let mut all_facts = market_opinions;
                    all_facts.extend(exit_opinions);
                    all_facts.extend(market_present);
                    all_facts.extend(exit_present);
                    all_facts.extend(self_facts);
                    all_facts.extend(derived_facts);
                    let broker_bundle = enterprise::thought_encoder::ThoughtAST::Bundle(all_facts).compress();
                    let broker_fact_count = match &broker_bundle {
                        enterprise::thought_encoder::ThoughtAST::Bundle(v) => v.len(),
                        _ => 1,
                    };
                    let broker_thought = brk_enc.encode(&broker_bundle, &brk_ctx.thought_encoder);

                    broker.propose(&broker_thought);

                    // The gate: only register papers when the broker has conviction.
                    // Cold-start: curve not valid → edge=0.0 → register freely (learn).
                    // Warm: curve valid → edge > 0.0 → register only when edge exists.
                    // The flip: if prediction changed direction, close old runners first.
                    let should_register = broker.cached_edge > 0.0 || !broker.reckoner.curve_valid();
                    let mut flip_resolutions = Vec::new();
                    if should_register {
                        // Check for direction flip — close old runners in opposite direction
                        if let Some(active_dir) = broker.active_direction {
                            if prediction != active_dir {
                                // FLIP — close all runners in old direction
                                flip_resolutions = broker.close_all_runners(Price(price));
                            }
                        }
                        broker.active_direction = Some(prediction);
                        broker.register_paper(broker_thought.clone(), market_thought.clone(), exit_thought.clone(), prediction, Price(price), dists);
                    }
                    let (market_signals, mut runner_resolutions) = broker.tick_papers(Price(price));
                    runner_resolutions.extend(flip_resolutions);

                    // Snapshot every 100 candles — into the DB
                    if candle_count % 100 == 0 {
                        let proto_cos = broker.reckoner.prototype_health()
                            .map_or(0.0, |(_, _, cos)| cos);
                        brk_log.log(LogEntry::BrokerSnapshot {
                            candle: candle_count,
                            broker_slot_idx: brk_slot,
                            edge: broker.edge(),
                            grace_count: broker.grace_count,
                            violence_count: broker.violence_count,
                            paper_count: broker.papers.len(),
                            trail_experience: broker.scalar_accums.get(0).map_or(0.0, |a| a.count as f64),
                            stop_experience: broker.scalar_accums.get(1).map_or(0.0, |a| a.count as f64),
                            disc_strength: broker.reckoner.last_disc_strength(),
                            last_conviction: broker.reckoner.last_cos_raw(),
                            curve_valid: broker.reckoner.curve_valid(),
                            resolved_count: broker.reckoner.resolved_count(),
                            proto_cos,
                            fact_count: broker_fact_count,
                            thought_ast: broker_bundle.to_edn(),
                        });
                    }

                    let prop = enterprise::proposal::Proposal::new(
                        composed, market_thought, exit_thought, dists, edge, side, src.clone(), tgt.clone(),
                        pred, post_idx_for_broker, broker.slot_idx);
                    let _ = out_tx.send((prop, market_signals, runner_resolutions));
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
                if let Some(c) = p.candle_window.back() {
                    current_prices.insert(
                        (p.source_asset.name.clone(), p.target_asset.name.clone()),
                        Price(c.close),
                    );
                }
            }
            let (settlements, settle_logs) = ent.treasury.settle_triggered(&current_prices);
            for entry in settle_logs { log_handle.log(entry); }

            for stl in &settlements {
                let slot = stl.trade.broker_slot_idx;
                let stl_post_idx = stl.trade.post_idx;
                let _mi = slot / pipes.m;
                let ei = slot % pipes.m;

                let direction = if stl.exit_price.0 > stl.trade.entry_price.0 {
                    enterprise::enums::Direction::Up
                } else {
                    enterprise::enums::Direction::Down
                };
                let optimal = enterprise::simulation::compute_optimal_distances(
                    &stl.trade.price_history, direction);

                // Market observer self-grades every candle — no broker propagation.
                // The observer is its own teacher. The market is the judge.
                if let Some(stl_pipes) = all_pipes.get(stl_post_idx) {
                    // Broker learns via channel — Proposal 026: include exit_thought
                    if slot < stl_pipes.broker_learn_txs.len() {
                        let _ = stl_pipes.broker_learn_txs[slot].send((
                            stl.composed_thought.clone(), stl.market_thought.clone(),
                            stl.exit_thought.clone(),
                            stl.outcome, stl.amount.0,
                            direction, optimal));
                    }
                }
                // Exit observer learns on main thread
                // Proposal 026: exit learns from exit_thought, not composed
                let is_grace = stl.outcome == enterprise::enums::Outcome::Grace;
                if stl_post_idx < ent.posts.len() && ei < ent.posts[stl_post_idx].exit_observers.len() {
                    ent.posts[stl_post_idx].exit_observers[ei].observe_distances(
                        &stl.exit_thought, &optimal, stl.amount.0, is_grace, optimal.trail);
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

        // Clone is necessary: candle_window is a VecDeque (mutated each candle via
        // push_back/pop_front). Observer threads need a contiguous Vec snapshot at this
        // candle. The Arc shares the single clone across all N observer threads.
        // VecDeque cannot provide a contiguous &[Candle] across both halves without copying.
        let window: Arc<Vec<enterprise::candle::Candle>> = Arc::new(post.candle_window.iter().cloned().collect());
        let encode_count = post.encode_count;

        let t_tick = t_candle.elapsed();

        // Fan-out: send enriched candle to all observers (product — each gets a clone)
        for tx in &pipes.obs_txs {
            let _ = tx.send((enriched.clone(), Arc::clone(&window), encode_count));
        }

        // Collect thoughts from all observers (bounded(1) — they block until we read)
        let mut market_thoughts = Vec::with_capacity(n);
        let mut market_asts: Vec<enterprise::thought_encoder::ThoughtAST> = Vec::with_capacity(n);
        let mut market_predictions: Vec<holon::memory::Prediction> = Vec::with_capacity(n);
        let mut market_edges = Vec::with_capacity(n);

        for rx in &pipes.thought_rxs {
            let (thought, ast, pred, edge, _) = rx.recv().unwrap();
            market_thoughts.push(thought);
            market_asts.push(ast);
            market_predictions.push(pred);
            market_edges.push(edge);
        }

        let t_observers = t_candle.elapsed();

        // N×M grid: parallel computation → send to broker pipes
        let price = post.last_close().0;
        let ctx_ref = &*ctx_arc;

        // Proposal 029 Phase 1: Exit encoding is per-slot (N×M), not per-lens (M).
        // Each (mi, ei) slot extracts from ONE market observer's (ast, anomaly),
        // filters above noise floor, appends surviving forms to exit facts, encodes,
        // then strips noise via the exit's own subspace.
        use rayon::prelude::*;
        let dims = ctx_ref.dims;
        let noise_floor = 5.0 / (dims as f64).sqrt();

        // Phase 1: Compute N×M exit anomalies. Sequential — noise subspace is mutable.
        // exit_anomalies[slot_idx] = anomaly for (mi, ei).
        // exit_asts[slot_idx] = the ThoughtAST for (mi, ei) — needed by broker Phase 3.
        let mut exit_anomalies: Vec<holon::kernel::vector::Vector> = Vec::with_capacity(n * m);
        let mut exit_asts: Vec<enterprise::thought_encoder::ThoughtAST> = Vec::with_capacity(n * m);
        for slot_idx in 0..(n * m) {
            let mi = slot_idx / m;
            let ei = slot_idx % m;

            // Exit lens facts + self-assessment
            let mut exit_facts = enterprise::post::exit_lens_facts(
                &post.exit_observers[ei].lens, &enriched, &mut post.scales);
            let self_facts = enterprise::post::exit_self_assessment_facts(
                post.exit_observers[ei].grace_rate,
                post.exit_observers[ei].avg_residue,
                &mut post.scales,
            );
            exit_facts.extend(self_facts);

            // Proposal 029: extract from ONE market observer's anomaly
            let facts = enterprise::thought_encoder::collect_facts(&market_asts[mi]);
            let extracted = enterprise::thought_encoder::extract(
                &market_thoughts[mi], &facts,
                |ast| grid_handles[slot_idx].encode(ast, &ctx_ref.thought_encoder));
            // Filter above noise floor, keep original ThoughtASTs
            let market_facts: Vec<enterprise::thought_encoder::ThoughtAST> = extracted
                .into_iter()
                .filter(|(_ast, presence)| presence.abs() > noise_floor)
                .map(|(ast, _presence)| ast)
                .collect();
            exit_facts.extend(market_facts);

            // Encode the combined bundle
            let exit_bundle = enterprise::thought_encoder::ThoughtAST::Bundle(exit_facts).compress();
            exit_asts.push(exit_bundle.clone());
            let exit_raw = grid_handles[slot_idx].encode(&exit_bundle, &ctx_ref.thought_encoder);

            // Update noise subspace, strip noise → exit anomaly
            let exit_f64 = enterprise::to_f64(&exit_raw);
            post.exit_observers[ei].noise_subspace.update(&exit_f64);
            let exit_anomaly = post.exit_observers[ei].strip_noise(&exit_raw);

            exit_anomalies.push(exit_anomaly);
        }

        // Phase 2: Compute grid values in parallel (pure reads)
        let grid_values: Vec<_> = {
            let exit_observers = &post.exit_observers;
            (0..(n * m))
            .into_par_iter()
            .map(|slot_idx| {
                let mi = slot_idx / m;
                let ei = slot_idx % m;

                let composed = holon::kernel::primitives::Primitives::bundle(
                    &[&market_thoughts[mi], &exit_anomalies[slot_idx]]);

                // Tier 1 only — reckoner distances on exit ANOMALY.
                let reckoner_dists = exit_observers[ei].reckoner_distances(&exit_anomalies[slot_idx]);

                let side = enterprise::post::derive_side(&market_predictions[mi]);
                let edge = 0.0_f64; // Broker computes edge on its thread
                let pred = enterprise::post::prediction_convert(&market_predictions[mi]);

                // Derive direction from prediction for paper registration
                let direction = if market_predictions[mi].direction.map_or(true, |d| d.index() == 0) {
                    enterprise::enums::Direction::Up
                } else {
                    enterprise::enums::Direction::Down
                };

                // Proposal 030: exit observer performance for opinion encoding
                let exit_gr = exit_observers[ei].grace_rate;
                let exit_ar = exit_observers[ei].avg_residue;
                let mkt_edge = market_edges[mi];

                (slot_idx, mi, ei, composed, reckoner_dists, side, edge, pred, direction, exit_gr, exit_ar, mkt_edge)
            })
            .collect()
        };

        let t_grid = t_candle.elapsed();

        // Send to broker pipes — bounded(1), each broker gets its input
        // Proposal 029 Phase 1 Change 4: pass exit ANOMALY (not raw exit vec)
        // Proposal 029 Phase 3: pass market_ast and exit_ast for extraction
        for (slot_idx, mi, _ei, composed, dists, side, edge, pred, direction, exit_gr, exit_ar, mkt_edge) in grid_values {
            let market_input = enterprise::vocab::broker::input::BrokerMarketInput {
                ast: market_asts[mi].clone(),
                anomaly: market_thoughts[mi].clone(),
            };
            let exit_input = enterprise::vocab::broker::input::BrokerExitInput {
                ast: exit_asts[slot_idx].clone(),
                anomaly: exit_anomalies[slot_idx].clone(),
            };
            let _ = pipes.broker_in_txs[slot_idx].send((
                composed, market_thoughts[mi].clone(), exit_anomalies[slot_idx].clone(), direction,
                dists, price, side, edge, pred,
                market_input, exit_input,
                exit_gr, exit_ar, mkt_edge, enriched.atr_r));
        }

        // Collect from broker pipes — bounded(1), all 24 produce
        let mut all_market_signals = Vec::new();
        let mut all_runner_resolutions = Vec::new();
        for rx in &pipes.broker_out_rxs {
            let (prop, market_signals, runner_resolutions) = rx.recv().unwrap();
            ent.treasury.submit_proposal(prop);
            for res in &market_signals {
                log_handle.log(LogEntry::PaperResolved {
                    broker_slot_idx: res.broker_slot_idx,
                    outcome: res.outcome,
                    optimal_distances: res.optimal_distances,
                });
                log_handle.log(LogEntry::PaperDetail {
                    broker_slot_idx: res.broker_slot_idx,
                    outcome: res.outcome,
                    entry_price: res.entry_price,
                    extreme: res.extreme,
                    excursion: res.excursion,
                    trail_distance: res.trail_distance,
                    stop_distance: res.stop_distance,
                    optimal_trail: res.optimal_distances.trail,
                    optimal_stop: res.optimal_distances.stop,
                    duration: res.duration,
                    was_runner: res.was_runner,
                });
            }
            for res in &runner_resolutions {
                log_handle.log(LogEntry::PaperResolved {
                    broker_slot_idx: res.broker_slot_idx,
                    outcome: res.outcome,
                    optimal_distances: res.optimal_distances,
                });
                log_handle.log(LogEntry::PaperDetail {
                    broker_slot_idx: res.broker_slot_idx,
                    outcome: res.outcome,
                    entry_price: res.entry_price,
                    extreme: res.extreme,
                    excursion: res.excursion,
                    trail_distance: res.trail_distance,
                    stop_distance: res.stop_distance,
                    optimal_trail: res.optimal_distances.trail,
                    optimal_stop: res.optimal_distances.stop,
                    duration: res.duration,
                    was_runner: res.was_runner,
                });
            }
            all_market_signals.extend(market_signals);
            all_runner_resolutions.extend(runner_resolutions);
        }

        let t_brokers = t_candle.elapsed();

        // Propagate — send learning signals to pipes + parallel exit observer learning.
        // Channel sends: cheap, sequential. Exit observer vec ops: parallel by observer.
        {
            // Market signals → market observer learn channels
            // The market observer learns from the paper's Grace/Violence verdict.
            for res in &all_market_signals {
                let mi = res.broker_slot_idx / m;
                if mi < pipes.learn_txs.len() {
                    // Grace: learn predicted direction with excursion weight
                    // Violence: learn opposite direction with stop_distance weight
                    let (direction, weight) = match res.outcome {
                        enterprise::enums::Outcome::Grace => (res.prediction, res.amount),
                        enterprise::enums::Outcome::Violence => {
                            let opposite = match res.prediction {
                                enterprise::enums::Direction::Up => enterprise::enums::Direction::Down,
                                enterprise::enums::Direction::Down => enterprise::enums::Direction::Up,
                            };
                            (opposite, res.amount)
                        }
                    };
                    let _ = pipes.learn_txs[mi].send((
                        res.market_thought.clone(), direction, weight));
                }
            }

            // Market signals also teach the BROKER — same principle as Proposal 025.
            // The broker needs both sides (Grace AND Violence) to build its discriminant.
            // Without this, the broker only learns from runners (Grace).
            for res in &all_market_signals {
                if res.broker_slot_idx < pipes.broker_learn_txs.len() {
                    let _ = pipes.broker_learn_txs[res.broker_slot_idx].send((
                        res.composed_thought.clone(), res.market_thought.clone(),
                        res.exit_thought.clone(),
                        res.outcome, res.amount,
                        res.prediction, res.optimal_distances));
                }
            }

            // Market signals also teach the exit observer — Violence papers carry
            // optimal distances from hindsight simulation. Without this, the exit
            // only learns from Grace (runners) and the distance feedback loop is one-sided.
            // Proposal 026: exit learns from exit_thought, not composed.
            for res in &all_market_signals {
                let ei = res.broker_slot_idx % m;
                let is_grace = res.outcome == enterprise::enums::Outcome::Grace;
                if ei < post.exit_observers.len() {
                    post.exit_observers[ei].observe_distances(
                        &res.exit_thought, &res.optimal_distances, res.amount,
                        is_grace, res.optimal_distances.trail);
                }
            }

            // Runner resolutions → broker learn channels + exit observer learning
            // Also: second market teaching — runner closure reinforces market observer
            let mut exit_work: Vec<Vec<(usize, usize)>> = vec![Vec::new(); m];
            for (ri, res) in all_runner_resolutions.iter().enumerate() {
                let ei = res.broker_slot_idx % m;
                let mi = res.broker_slot_idx / m;

                // Broker: learn via channel (cheap — just a send)
                // Proposal 026: include exit_thought
                let _ = pipes.broker_learn_txs[res.broker_slot_idx].send((
                    res.composed_thought.clone(), res.market_thought.clone(),
                    res.exit_thought.clone(),
                    res.outcome, res.amount,
                    res.prediction, res.optimal_distances));

                // Second market teaching: runner closure reinforces market observer.
                // Weight = excess = excursion - trail_distance (how much beyond "barely right").
                let excess = (res.excursion - res.trail_distance).max(0.0);
                if excess > 0.0 && mi < pipes.learn_txs.len() {
                    let _ = pipes.learn_txs[mi].send((
                        res.market_thought.clone(), res.prediction, excess));
                }

                // Collect exit work — apply in parallel below
                if ei < m {
                    exit_work[ei].push((ei, ri));
                }
            }

            // Exit observer learning — parallel across M exit observers, sequential within.
            // Deferred batch training: each runner resolution carries an exit_batch with
            // per-candle (thought, optimal, weight) observations. These are the primary
            // training signal. The single-point resolution observation is also sent.
            // Proposal 026: exit learns from exit_thought, not composed.
            post.exit_observers
                .par_iter_mut()
                .zip(exit_work.par_iter())
                .for_each(|(eobs, work)| {
                    for &(_ei, ri) in work {
                        let res = &all_runner_resolutions[ri];
                        let is_grace = res.outcome == enterprise::enums::Outcome::Grace;

                        // Batch training: ALL per-candle observations from the runner's life
                        // Note: batch thoughts are composed (from runner history), not exit-only.
                        // This is a known limitation — runner histories would need exit_thought
                        // stored per-candle for full alignment. For now, use the paper's exit_thought
                        // for the single-point observation, and pass batch as-is.
                        for (thought, optimal, weight) in &res.exit_batch {
                            eobs.observe_distances(thought, optimal, *weight, is_grace, optimal.trail);
                        }

                        // Single-point resolution observation — uses exit_thought
                        eobs.observe_distances(
                            &res.exit_thought, &res.optimal_distances, res.amount,
                            is_grace, res.optimal_distances.trail);
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

            // exit_anomalies already computed in the N×M grid — reuse them here.

            // Parallel: distance query per trade. Independent.
            let level_updates: Vec<_> = trade_info
                .par_iter()
                .filter_map(|&(tid, slot, side)| {
                    let mi = slot / pipes.m;
                    let ei = slot % pipes.m;
                    if mi < market_thoughts.len() && ei < post.exit_observers.len() && slot < exit_anomalies.len() {
                        // Proposal 029: exit reckoner queries on exit anomaly, not raw vec.
                        let reckoner_dists = post.exit_observers[ei].reckoner_distances(&exit_anomalies[slot]);
                        let dists = reckoner_dists.unwrap_or(post.exit_observers[ei].default_distances);
                        let new_levels = dists.to_levels(Price(price), side);
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
                num_resolutions: all_market_signals.len() + all_runner_resolutions.len(),
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
