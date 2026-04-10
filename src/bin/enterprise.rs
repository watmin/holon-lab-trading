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
use enterprise::enums::{ExitLens, MarketLens, Outcome, ScalarEncoding};
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

const BATCH_SIZE: usize = 1000;
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

fn flush_logs(logs: &[LogEntry], conn: &Connection) {
    if logs.is_empty() {
        return;
    }
    let mut stmt = conn
        .prepare_cached(
            "INSERT INTO log (kind, broker_slot_idx, trade_id, outcome, amount, duration, reason, observers_updated)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        )
        .expect("failed to prepare log insert");

    for entry in logs {
        match entry {
            LogEntry::ProposalSubmitted {
                broker_slot_idx, ..
            } => {
                stmt.execute(params![
                    "ProposalSubmitted",
                    *broker_slot_idx as i64,
                    None::<i64>,
                    None::<String>,
                    None::<f64>,
                    None::<i64>,
                    None::<String>,
                    None::<i64>,
                ])
                .ok();
            }
            LogEntry::ProposalFunded {
                trade_id,
                broker_slot_idx,
                amount_reserved,
            } => {
                stmt.execute(params![
                    "ProposalFunded",
                    *broker_slot_idx as i64,
                    trade_id.0 as i64,
                    None::<String>,
                    *amount_reserved,
                    None::<i64>,
                    None::<String>,
                    None::<i64>,
                ])
                .ok();
            }
            LogEntry::ProposalRejected {
                broker_slot_idx,
                reason,
            } => {
                stmt.execute(params![
                    "ProposalRejected",
                    *broker_slot_idx as i64,
                    None::<i64>,
                    None::<String>,
                    None::<f64>,
                    None::<i64>,
                    reason,
                    None::<i64>,
                ])
                .ok();
            }
            LogEntry::TradeSettled {
                trade_id,
                outcome,
                amount,
                duration,
                ..
            } => {
                let outcome_str = match outcome {
                    Outcome::Grace => "Grace",
                    Outcome::Violence => "Violence",
                };
                stmt.execute(params![
                    "TradeSettled",
                    None::<i64>,
                    trade_id.0 as i64,
                    outcome_str,
                    *amount,
                    *duration as i64,
                    None::<String>,
                    None::<i64>,
                ])
                .ok();
            }
            LogEntry::PaperResolved {
                broker_slot_idx,
                outcome,
                ..
            } => {
                let outcome_str = match outcome {
                    Outcome::Grace => "Grace",
                    Outcome::Violence => "Violence",
                };
                stmt.execute(params![
                    "PaperResolved",
                    *broker_slot_idx as i64,
                    None::<i64>,
                    outcome_str,
                    None::<f64>,
                    None::<i64>,
                    None::<String>,
                    None::<i64>,
                ])
                .ok();
            }
            LogEntry::Propagated {
                broker_slot_idx,
                observers_updated,
            } => {
                stmt.execute(params![
                    "Propagated",
                    *broker_slot_idx as i64,
                    None::<i64>,
                    None::<String>,
                    None::<f64>,
                    None::<i64>,
                    None::<String>,
                    *observers_updated as i64,
                ])
                .ok();
            }
        }
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
    let post = &ent.posts[0];

    eprintln!(
        "\n  candle={} throughput={:.0}/s equity={:.2}",
        candle_num, throughput, equity
    );

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
    let post = &ent.posts[0];

    let total_trades: usize = post.registry.iter().map(|b| b.trade_count).sum();
    let total_grace: f64 = post.registry.iter().map(|b| b.cumulative_grace).sum();
    let total_violence: f64 = post.registry.iter().map(|b| b.cumulative_violence).sum();
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

    // Observer panel
    eprintln!();
    eprintln!("  Observer panel:");
    for obs in &post.market_observers {
        eprintln!(
            "    {}: recalib={} experience={:.2} resolved={}",
            obs.lens,
            obs.reckoner.recalib_count(),
            obs.experience(),
            obs.resolved,
        );
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
    let (mut ent, mut ctx) = build_enterprise(&args);

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
    register_brokers(&ledger, &ent.posts[0]);
    eprintln!("  Run database: {}", ledger_path);

    // ─ Loop config ─
    let end_idx = if args.max_candles > 0 {
        args.max_candles.min(total_candles)
    } else {
        total_candles
    };
    let progress_every = if end_idx <= 5_000 {
        500
    } else if end_idx <= 50_000 {
        2_000
    } else {
        10_000
    };

    let kill_file = Path::new("trader-stop");
    let mut bnh_entry: f64 = 0.0;
    let mut last_close: f64 = 0.0;
    let t_start = Instant::now();
    let mut candle_num: usize = 0;
    let mut log_step: usize = 0;
    let mut pending_logs: Vec<LogEntry> = Vec::new();

    ledger.execute_batch("BEGIN").ok();

    eprintln!("\n  Walk-forward: up to {} candles...", end_idx);

    // ─ The fold — everything is a pipe ─
    // Each unit is a thread. bounded(1) = lock step = lazy enumerator.
    // The fold decomposes into sub-folds connected by rendezvous channels.
    // The composition of folds IS the enterprise fold.

    let n = MARKET_LENSES.len();
    let m = EXIT_LENSES.len();
    let mut ctx_arc = Arc::new(ctx);

    // ── Channels ──
    // Main → observers: one channel per observer (product fan-out — cloned candles)
    let mut obs_txs: Vec<Sender<(enterprise::candle::Candle, Vec<enterprise::candle::Candle>, usize)>> = Vec::new();
    let mut obs_rxs: Vec<Receiver<(enterprise::candle::Candle, Vec<enterprise::candle::Candle>, usize)>> = Vec::new();
    for _ in 0..n {
        let (tx, rx) = channel::bounded(1);
        obs_txs.push(tx);
        obs_rxs.push(rx);
    }

    // Observers → main: thoughts back (one channel per observer)
    // Uses holon-rs Prediction (what the observer returns), converted at consumer
    let mut thought_txs: Vec<Sender<(holon::kernel::vector::Vector, holon::memory::Prediction, f64, Vec<(enterprise::thought_encoder::ThoughtAST, holon::kernel::vector::Vector)>)>> = Vec::new();
    let mut thought_rxs: Vec<Receiver<(holon::kernel::vector::Vector, holon::memory::Prediction, f64, Vec<(enterprise::thought_encoder::ThoughtAST, holon::kernel::vector::Vector)>)>> = Vec::new();
    for _ in 0..n {
        let (tx, rx) = channel::bounded(1);
        thought_txs.push(tx);
        thought_rxs.push(rx);
    }

    // Main → observers: learning signals (propagation back)
    // UNBOUNDED — learning is eventually consistent. The observer drains
    // non-blocking with try_recv. The main thread never blocks on send.
    // bounded(1) here causes deadlock: main blocks on send, observer
    // blocks on recv for next candle. Neither proceeds.
    let mut learn_txs: Vec<Sender<(holon::kernel::vector::Vector, enterprise::enums::Direction, f64)>> = Vec::new();
    let mut learn_rxs: Vec<Receiver<(holon::kernel::vector::Vector, enterprise::enums::Direction, f64)>> = Vec::new();
    for _ in 0..n {
        let (tx, rx) = channel::unbounded();
        learn_txs.push(tx);
        learn_rxs.push(rx);
    }

    // ── Observer threads ──
    // Each observer is a pipe: receive candle, encode, send thought. Lock step.
    // Also drains learning signals (non-blocking) at the end of each iteration.
    let mut observer_handles = Vec::new();
    let post = &mut ent.posts[0];

    // Move observers out of the post for threading
    let mut observers: Vec<MarketObserver> = std::mem::take(&mut post.market_observers);

    for i in 0..n {
        let rx = obs_rxs.remove(0);
        let tx = thought_txs.remove(0);
        let learn_rx = learn_rxs.remove(0);
        let mut obs = std::mem::replace(&mut observers[i], MarketObserver::new(
            MarketLens::Momentum, 10, 500, WindowSampler::new(0, 12, 2016),
        ));
        let ctx_ref = Arc::clone(&ctx_arc);
        let lens = obs.lens;
        let recalib = args.recalib_interval;

        let handle = std::thread::spawn(move || {
            // The pipe: receive, encode, send. Drain learning. Forever. Lock step.
            while let Ok((candle, window, _encode_count)) = rx.recv() {
                // Encode via lens
                let facts = enterprise::post::market_lens_facts_pub(&lens, &candle, &window);
                let bundle_ast = enterprise::thought_encoder::ThoughtAST::Bundle(facts);
                let (thought, misses) = ctx_ref.thought_encoder.encode(&bundle_ast);
                let result = obs.observe(thought, Vec::new());

                // Send downstream — block until consumer takes
                let _ = tx.send((result.thought, result.prediction, result.edge, misses));

                // Drain learning signals — non-blocking. Apply all pending.
                while let Ok((thought, direction, weight)) = learn_rx.try_recv() {
                    obs.resolve(&thought, direction, weight, recalib);
                }
            }
            obs // Return the observer when the channel closes
        });
        observer_handles.push(handle);
    }

    // ── The fold — main thread drives indicator bank + collects ──
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

        // Tick indicator bank (sequential — streaming state)
        let enriched = ent.posts[0].indicator_bank.tick(&rc);
        ent.posts[0].candle_window.push_back(enriched.clone());
        while ent.posts[0].candle_window.len() > ent.posts[0].max_window_size {
            ent.posts[0].candle_window.pop_front();
        }
        ent.posts[0].encode_count += 1;

        let window: Vec<enterprise::candle::Candle> = ent.posts[0].candle_window.iter().cloned().collect();
        let encode_count = ent.posts[0].encode_count;

        // Fan-out: send enriched candle to all observers (product — each gets a clone)
        for tx in &obs_txs {
            let _ = tx.send((enriched.clone(), window.clone(), encode_count));
        }

        // Collect thoughts from all observers (bounded(1) — they block until we read)
        let mut market_thoughts = Vec::with_capacity(n);
        let mut market_predictions: Vec<holon::memory::Prediction> = Vec::with_capacity(n);
        let mut market_edges = Vec::with_capacity(n);
        let mut all_misses = Vec::new();

        for rx in &thought_rxs {
            let (thought, pred, edge, misses) = rx.recv().unwrap();
            market_thoughts.push(thought);
            market_predictions.push(pred);
            market_edges.push(edge);
            all_misses.extend(misses);
        }

        // N×M grid: exit encoding + composition + propose + paper (main thread for now)
        let price = ent.posts[0].current_price();
        let ctx_ref = &*ctx_arc;

        for slot_idx in 0..(n * m) {
            let mi = slot_idx / m;
            let ei = slot_idx % m;

            let exit_facts = enterprise::post::exit_lens_facts_pub(
                &ent.posts[0].exit_observers[ei].lens, &enriched);
            let exit_bundle = enterprise::thought_encoder::ThoughtAST::Bundle(exit_facts);
            let (exit_vec, exit_misses) = ctx_ref.thought_encoder.encode(&exit_bundle);
            all_misses.extend(exit_misses);

            let composed = holon::kernel::primitives::Primitives::bundle(
                &[&market_thoughts[mi], &exit_vec]);

            let (dists, _) = ent.posts[0].exit_observers[ei].recommended_distances(
                &composed,
                &ent.posts[0].registry[slot_idx].scalar_accums,
                ctx_ref.thought_encoder.scalar_encoder(),
            );

            ent.posts[0].registry[slot_idx].propose(&composed);
            ent.posts[0].registry[slot_idx].register_paper(composed.clone(), price, dists);

            // Derive side and build proposal
            let side = enterprise::post::derive_side_pub(&market_predictions[mi]);
            let edge = ent.posts[0].registry[slot_idx].edge();
            let pred = enterprise::post::prediction_convert_pub(&market_predictions[mi]);

            let prop = enterprise::proposal::Proposal::new(
                composed, dists, edge, side,
                ent.posts[0].source_asset.clone(),
                ent.posts[0].target_asset.clone(),
                pred, 0, slot_idx,
            );
            ent.treasury.submit_proposal(prop);
        }

        // Tick papers (per candle — papers resolve correctly)
        // Collect all resolutions, then propagate
        let mut all_resolutions = Vec::new();
        for broker in &mut ent.posts[0].registry {
            let resolutions = broker.tick_papers(price);
            for res in &resolutions {
                pending_logs.push(LogEntry::PaperResolved {
                    broker_slot_idx: res.broker_slot_idx,
                    outcome: res.outcome,
                    optimal_distances: res.optimal_distances,
                });
            }
            all_resolutions.extend(resolutions);
        }

        // Step 7: Propagate — send learning signals back to observer pipes
        // The observer threads drain these non-blocking at the end of each iteration.
        for res in &all_resolutions {
            let mi = res.broker_slot_idx / m;
            let ei = res.broker_slot_idx % m;

            // Market observer learns direction (via learn channel)
            if mi < learn_txs.len() {
                let _ = learn_txs[mi].send((
                    res.composed_thought.clone(),
                    res.direction,
                    res.amount,
                ));
            }

            // Exit observer learns distances (main thread — not on a pipe yet)
            if ei < ent.posts[0].exit_observers.len() {
                ent.posts[0].exit_observers[ei].observe_distances(
                    &res.composed_thought,
                    &res.optimal_distances,
                    res.amount,
                );
            }

            // Broker learns Grace/Violence (main thread — broker owns its reckoner)
            ent.posts[0].registry[res.broker_slot_idx].propagate(
                &res.composed_thought,
                res.outcome,
                res.amount,
                res.direction,
                &res.optimal_distances,
                args.recalib_interval,
                enterprise::post::ctx_scalar_encoder_placeholder(),
            );
        }

        // Tick trade price histories
        for (_, trade) in ent.treasury.trades.iter_mut() {
            trade.tick(rc.close);
        }

        // Insert cache misses
        // ctx is behind Arc — we need mut access. Use Arc::get_mut at the boundary.
        // For now, collect misses and insert after threads complete.

        // Fund proposals
        let fund_logs = ent.treasury.fund_proposals();
        pending_logs.extend(fund_logs);

        candle_num += 1;

        if pending_logs.len() >= BATCH_SIZE {
            flush_logs(&pending_logs, &ledger);
            log_step += pending_logs.len();
            pending_logs.clear();
        }

        if candle_num % progress_every == 0 {
            let elapsed_ms = t_start.elapsed().as_secs_f64() * 1000.0;
            display_progress(&ent, candle_num, elapsed_ms);
        }
    }

    // ── Shutdown: close channels, join threads, restore observers ──
    drop(obs_txs); // Close channels — observer threads will exit their loops
    for handle in observer_handles {
        let obs = handle.join().unwrap();
        // Observers return from their threads — restore into post
        // (state is preserved from the pipe's fold)
    }

    // Insert accumulated cache misses
    if let Some(ctx_mut) = Arc::get_mut(&mut ctx_arc) {
        // Can insert misses here after all threads are joined
    }

    // Flush remaining logs
    flush_logs(&pending_logs, &ledger);
    log_step += pending_logs.len();
    pending_logs.clear();

    ledger.execute_batch("COMMIT").ok();

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
        log_step,
        &ledger_path,
    );
}

#[cfg(not(feature = "parquet"))]
fn main() {
    eprintln!("enterprise binary requires the 'parquet' feature. Build with:");
    eprintln!("  cargo build --release --features parquet");
    std::process::exit(1);
}
