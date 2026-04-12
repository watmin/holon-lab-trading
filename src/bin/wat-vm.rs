/// wat-vm — the first heartbeat. Reads candles, enriches them, counts them.
///
/// No thinking. No encoding. No prediction. Just the stream and the bank.
/// The simplest proof that the pipeline breathes.

use clap::Parser;

#[cfg(feature = "parquet")]
use std::path::Path;
#[cfg(feature = "parquet")]
use enterprise::domain::candle_stream::CandleStream;
#[cfg(feature = "parquet")]
use enterprise::domain::indicator_bank::IndicatorBank;
#[cfg(feature = "parquet")]
use enterprise::programs::stdlib::console::console;

// ─── CLI ─────────────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "wat-vm", about = "The simplest heartbeat — candles in, count out")]
struct Args {
    /// Candle streams. Format: SOURCE:TARGET:PATH. Repeatable.
    #[arg(long = "stream", required = true)]
    streams: Vec<String>,

    /// Max candles per stream. Each pipeline owns its limit.
    #[arg(long)]
    max_candles: usize,
}

// ─── Pipeline ────────────────────────────────────────────────────────────────

#[cfg(feature = "parquet")]
struct Pipeline {
    source: String,
    target: String,
    stream: CandleStream,
    bank: IndicatorBank,
    count: usize,
}

// ─── Main ────────────────────────────────────────────────────────────────────

#[cfg(feature = "parquet")]
fn main() {
    let args = Args::parse();

    // Parse --stream flags into pipelines
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

    // Console: one handle per stream
    let (handles, driver) = console(parsed.len());

    // Build pipelines
    let mut pipelines: Vec<Pipeline> = Vec::new();
    for (i, (source, target, path)) in parsed.into_iter().enumerate() {
        let p = Path::new(&path);
        let total = CandleStream::total_candles(p);
        let stream = CandleStream::open(p, &source, &target);
        handles[i].out(format!(
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

    // Per-stream loop. Each pipeline owns its limit.
    // No coordination. The count is per-pipeline.
    let max = args.max_candles;
    for (i, pipeline) in pipelines.iter_mut().enumerate() {
        while pipeline.count < max {
            match pipeline.stream.next() {
                Some(ohlcv) => {
                    let candle = pipeline.bank.tick(&ohlcv);
                    pipeline.count += 1;
                    if pipeline.count % 500 == 0 {
                        handles[i].out(format!(
                            "{}/{} candle {}: close={:.2}",
                            pipeline.source, pipeline.target, pipeline.count, candle.close
                        ));
                    }
                }
                None => break, // stream exhausted
            }
        }
    }

    // Final summary
    for (i, pipeline) in pipelines.iter().enumerate() {
        handles[i].out(format!(
            "{}/{} done: {} candles",
            pipeline.source, pipeline.target, pipeline.count
        ));
    }

    // Drop handles, then join driver
    drop(handles);
    driver.join();
}

#[cfg(not(feature = "parquet"))]
fn main() {
    eprintln!("vm requires the 'parquet' feature");
    std::process::exit(1);
}
