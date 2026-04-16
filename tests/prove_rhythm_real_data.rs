/// prove_rhythm_real_data.rs — indicator rhythms on real BTC candles.
///
/// Reads btc_5m_raw.parquet. Ticks through IndicatorBank. Builds
/// indicator rhythms from real RSI, MACD, ADX, OBV values. Trains
/// a subspace on early windows. Tests against later windows during
/// different market regimes.
///
/// The question: does the subspace detect regime changes in real data?

use std::path::Path;

use holon::kernel::primitives::Primitives;
use holon::kernel::scalar::{ScalarEncoder, ScalarMode};
use holon::kernel::similarity::Similarity;
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;
use holon::memory::OnlineSubspace;

use enterprise::domain::candle_stream::CandleStream;
use enterprise::domain::indicator_bank::IndicatorBank;
use enterprise::types::candle::Candle;

const DIMS: usize = 10_000;
const WINDOW_SIZE: usize = 50;
const PARQUET: &str = "data/btc_5m_raw.parquet";

fn therm(scalar: &ScalarEncoder, value: f64, min: f64, max: f64) -> Vector {
    scalar.encode(value, ScalarMode::Thermometer { min, max })
}

fn to_f64(v: &Vector) -> Vec<f64> {
    v.data().iter().map(|&x| x as f64).collect()
}

/// Build one indicator rhythm from a window of candles.
/// Atom wraps the whole rhythm. Thermometer + delta.
fn indicator_rhythm_from_candles(
    vm: &VectorManager,
    scalar: &ScalarEncoder,
    atom_name: &str,
    candles: &[Candle],
    extract: fn(&Candle) -> f64,
    value_min: f64,
    value_max: f64,
    delta_range: f64,
) -> Vector {
    let facts: Vec<Vector> = candles.iter().enumerate().map(|(i, c)| {
        let val = extract(c);
        if i == 0 {
            therm(scalar, val, value_min, value_max)
        } else {
            let prev = extract(&candles[i - 1]);
            let delta = val - prev;
            let v = therm(scalar, val, value_min, value_max);
            let d = Primitives::bind(
                &vm.get_vector("delta"),
                &therm(scalar, delta, -delta_range, delta_range),
            );
            let refs = vec![&v, &d];
            Primitives::bundle(&refs)
        }
    }).collect();

    let trigrams: Vec<Vector> = facts.windows(3).map(|w| {
        let ab = Primitives::bind(&w[0], &Primitives::permute(&w[1], 1));
        Primitives::bind(&ab, &Primitives::permute(&w[2], 2))
    }).collect();

    let pairs: Vec<Vector> = trigrams.windows(2)
        .map(|w| Primitives::bind(&w[0], &w[1])).collect();

    if pairs.is_empty() {
        return Vector::zeros(DIMS);
    }
    let budget = (DIMS as f64).sqrt() as usize;
    let start = if pairs.len() > budget { pairs.len() - budget } else { 0 };
    let trimmed: Vec<&Vector> = pairs[start..].iter().collect();
    let raw = Primitives::bundle(&trimmed);
    Primitives::bind(&vm.get_vector(atom_name), &raw)
}

/// Build a market rhythm from a window of candles — 4 indicators.
fn market_rhythm(
    vm: &VectorManager,
    scalar: &ScalarEncoder,
    candles: &[Candle],
) -> Vector {
    let r_rsi = indicator_rhythm_from_candles(
        vm, scalar, "rsi", candles, |c| c.rsi, 0.0, 100.0, 10.0);
    let r_macd = indicator_rhythm_from_candles(
        vm, scalar, "macd", candles, |c| c.macd_hist, -50.0, 50.0, 20.0);
    let r_adx = indicator_rhythm_from_candles(
        vm, scalar, "adx", candles, |c| c.adx, 0.0, 100.0, 10.0);
    let r_obv = indicator_rhythm_from_candles(
        vm, scalar, "obv", candles, |c| c.obv_slope_12, -2.0, 2.0, 1.0);
    let refs = vec![&r_rsi, &r_macd, &r_adx, &r_obv];
    Primitives::bundle(&refs)
}

/// Classify a window's dominant regime from net price movement.
/// >1% move = trending (up or down). Otherwise mixed.
fn classify_regime(candles: &[Candle]) -> &'static str {
    let first = candles.first().unwrap().close;
    let last = candles.last().unwrap().close;
    let pct_move = (last - first) / first;
    if pct_move > 0.01 {
        "up"
    } else if pct_move < -0.01 {
        "down"
    } else {
        "mixed"
    }
}

#[test]
fn real_btc_regime_separation() {
    let path = Path::new(PARQUET);
    if !path.exists() {
        println!("Skipping: {} not found", PARQUET);
        return;
    }

    let vm = VectorManager::new(DIMS);
    let scalar = ScalarEncoder::new(DIMS);

    // Read candles
    println!("\n=== Loading candles ===");
    let stream = CandleStream::open(path, "USDC", "WBTC");
    let mut bank = IndicatorBank::new();
    let mut candles: Vec<Candle> = Vec::new();

    let max_candles = 3_000;
    for raw in stream {
        if candles.len() >= max_candles {
            break;
        }
        let candle = bank.tick(&raw);
        candles.push(candle);
    }
    println!("  loaded {} candles", candles.len());

    // Skip warmup — first 500 candles for indicator stabilization
    let warmup = 500;
    let candles = &candles[warmup..];
    println!("  after warmup skip: {} candles", candles.len());

    // Build rhythm windows
    let stride = 10; // advance by 10 candles per window
    let mut windows: Vec<(&[Candle], &'static str)> = Vec::new();
    let mut i = 0;
    while i + WINDOW_SIZE <= candles.len() {
        let w = &candles[i..i + WINDOW_SIZE];
        let regime = classify_regime(w);
        windows.push((w, regime));
        i += stride;
    }

    let up_count = windows.iter().filter(|(_, r)| *r == "up").count();
    let down_count = windows.iter().filter(|(_, r)| *r == "down").count();
    let mixed_count = windows.iter().filter(|(_, r)| *r == "mixed").count();
    println!("  windows: {} total, {} up, {} down, {} mixed",
        windows.len(), up_count, down_count, mixed_count);

    if up_count < 5 || down_count < 5 {
        println!("  Not enough regime diversity in first {} candles. Need both up and down.", max_candles);
        println!("  This is data-dependent — try a larger window or different segment.");
        return;
    }

    // Train subspace on the first half
    let train_count = windows.len() / 2;
    let test_windows = &windows[train_count..];
    let train_windows = &windows[..train_count];

    let mut subspace = OnlineSubspace::new(DIMS, 32);
    println!("\n=== Training on first {} windows ===", train_count);
    let mut trained = 0;
    for (w, _regime) in train_windows {
        let rhythm = market_rhythm(&vm, &scalar, w);
        subspace.update(&to_f64(&rhythm));
        trained += 1;
    }
    println!("  trained on {} windows", trained);

    // Test: measure residuals by regime
    println!("\n=== Testing on remaining {} windows ===", test_windows.len());
    let mut up_residuals = Vec::new();
    let mut down_residuals = Vec::new();
    let mut mixed_residuals = Vec::new();

    for (w, regime) in test_windows {
        let rhythm = market_rhythm(&vm, &scalar, w);
        let residual = subspace.residual(&to_f64(&rhythm));
        match *regime {
            "up" => up_residuals.push(residual),
            "down" => down_residuals.push(residual),
            "mixed" => mixed_residuals.push(residual),
            _ => {}
        }
    }

    let avg = |v: &[f64]| if v.is_empty() { 0.0 } else { v.iter().sum::<f64>() / v.len() as f64 };
    let avg_up = avg(&up_residuals);
    let avg_down = avg(&down_residuals);
    let avg_mixed = avg(&mixed_residuals);

    println!("\n=== RESULTS ===");
    println!("  up windows:    n={:>4}  avg residual={:.4}", up_residuals.len(), avg_up);
    println!("  down windows:  n={:>4}  avg residual={:.4}", down_residuals.len(), avg_down);
    println!("  mixed windows: n={:>4}  avg residual={:.4}", mixed_residuals.len(), avg_mixed);

    if avg_up > 0.0 {
        println!("  down/up ratio: {:.2}x", avg_down / avg_up);
        println!("  mixed/up ratio: {:.2}x", avg_mixed / avg_up);
    }
    if avg_down > 0.0 && avg_up > 0.0 {
        let bigger = avg_down.max(avg_up);
        let smaller = avg_down.min(avg_up);
        println!("  regime separation: {:.2}x", bigger / smaller);
    }

    // Also measure: raw cosine between a typical up window and a typical down window
    if !up_residuals.is_empty() && !down_residuals.is_empty() {
        // Find windows closest to their regime average
        let up_window = test_windows.iter()
            .filter(|(_, r)| *r == "up")
            .next().unwrap().0;
        let down_window = test_windows.iter()
            .filter(|(_, r)| *r == "down")
            .next().unwrap().0;

        let up_rhythm = market_rhythm(&vm, &scalar, up_window);
        let down_rhythm = market_rhythm(&vm, &scalar, down_window);

        let raw_cos = Similarity::cosine(&up_rhythm, &down_rhythm);

        let up_anomaly = Vector::from_f64(&subspace.anomalous_component(&to_f64(&up_rhythm)));
        let down_anomaly = Vector::from_f64(&subspace.anomalous_component(&to_f64(&down_rhythm)));
        let anomaly_cos = Similarity::cosine(&up_anomaly, &down_anomaly);

        println!("\n=== RAW vs ANOMALY ===");
        println!("  raw cosine (up vs down):     {:.4}", raw_cos);
        println!("  anomaly cosine (up vs down): {:.4}", anomaly_cos);
    }
}
