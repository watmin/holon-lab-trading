/// enterprise — self-organizing BTC trading enterprise.
///
/// Six primitives. Two templates. One heartbeat per candle.
/// See wat/bin/enterprise.wat for the specification.
///
/// The binary creates the world, feeds candles, writes the ledger,
/// and displays progress. It does not think. It orchestrates.
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

use clap::Parser;
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

    // ─ The fold ─
    for rc in raw_stream {
        // Max candles check
        if args.max_candles > 0 && candle_num >= args.max_candles {
            break;
        }

        // Kill switch — check every 1000 candles
        if candle_num % 1000 == 0 && kill_file.exists() {
            eprintln!("\n  Kill switch triggered at candle {}", candle_num);
            std::fs::remove_file(kill_file).ok();
            break;
        }

        // Record bnh entry from first candle
        if candle_num == 0 {
            bnh_entry = rc.close;
        }
        last_close = rc.close;

        // Process candle through the enterprise
        let (logs, misses) = ent.on_candle(&rc, &ctx);

        // Insert cache misses — the one seam
        ctx.insert_cache_misses(misses);

        // Increment price history on all active trades
        for (_, trade) in ent.treasury.trades.iter_mut() {
            trade.tick(rc.close);
        }

        // Accumulate logs
        pending_logs.extend(logs);
        candle_num += 1;

        // Flush logs in batches
        if pending_logs.len() >= BATCH_SIZE {
            flush_logs(&pending_logs, &ledger);
            log_step += pending_logs.len();
            pending_logs.clear();
        }

        // Progress display
        if candle_num % progress_every == 0 {
            let elapsed_ms = t_start.elapsed().as_secs_f64() * 1000.0;
            display_progress(&ent, candle_num, elapsed_ms);
        }
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
