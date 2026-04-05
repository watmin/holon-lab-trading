use rusqlite::{params, Connection};
use crate::journal::Direction;

// ─── LogEntry ───────────────────────────────────────────────────────────────
// The fold says WHAT happened. The caller decides WHEN to write.
// Beckman's free monad: separate description from interpretation.

pub enum LogEntry {
    CandleLog {
        step: i64,
        candle_idx: i64,
        timestamp: String,
        tht_cos: f64,
        tht_conviction: f64,
        tht_pred: Option<String>,
        meta_pred: Option<String>,
        meta_conviction: f64,
        actual: String,
        traded: i32,
        position_frac: Option<f64>,
        equity: f64,
        outcome_pct: f64,
        usdc_bal: f64,
        wbtc_bal: f64,
        usdc_deployed: f64,
        wbtc_deployed: f64,
    },
    TradeLedger {
        step: i64,
        candle_idx: i64,
        timestamp: String,
        exit_candle_idx: Option<i64>,
        exit_timestamp: Option<String>,
        direction: String,
        conviction: f64,
        high_conviction: i32,
        entry_price: f64,
        exit_price: f64,
        position_frac: f64,
        position_usd: f64,
        gross_return_pct: f64,
        swap_fee_pct: f64,
        slippage_pct: f64,
        net_return_pct: f64,
        pnl_usd: f64,
        equity_after: f64,
        max_favorable_pct: f64,
        max_adverse_pct: f64,
        crossing_candles: Option<i64>,
        horizon_candles: i64,
        outcome: String,
        won: i32,
        exit_reason: String,
    },
    PositionOpen {
        step: i64,
        candle_idx: i64,
        timestamp: String,
        direction: Direction,
        entry_price: f64,
        position_usd: f64,
        swap_fee_pct: f64,
    },
    PositionExit {
        step: i64,
        candle_idx: i64,
        timestamp: String,
        direction: Direction,
        entry_price: f64,
        exit_price: f64,
        gross_return_pct: f64,
        position_usd: f64,
        swap_fee_pct: f64,
        horizon_candles: i64,
        won: i32,
        exit_reason: String,
    },
    RecalibLog {
        step: i64,
        journal: String,
        cos_raw: f64,
        disc_strength: f64,
        buy_count: i64,
        sell_count: i64,
        buy_norm: f64,      // L2 norm of Buy prototype
        sell_norm: f64,     // L2 norm of Sell prototype
        proto_cosine: f64,  // cosine between Buy and Sell prototypes
    },
    DiscDecode {
        step: i64,
        journal: String,
        rank: i64,
        fact_label: String,
        cosine: f64,
    },
    ObserverLog {
        step: i64,
        observer: String,
        conviction: f64,
        direction: String,
        correct: i32,
    },
    RiskLog {
        step: i64,
        drawdown_pct: f64,
        streak_len: i32,
        streak_dir: String,
        recent_acc: f64,
        equity_pct: f64,
        won: i32,
    },
    TradeFact {
        step: i64,
        fact_label: String,
    },
    TradeVector {
        step: i64,
        won: i32,
        tht_data: Vec<u8>,
    },
    CandleSnapshot {
        candle_idx: i64,
        // Raw OHLCV
        ts: String, open: f64, high: f64, low: f64, close: f64, volume: f64,
        // Indicators
        sma20: f64, sma50: f64, sma200: f64,
        bb_upper: f64, bb_lower: f64, bb_width: f64, bb_pos: f64,
        rsi: f64,
        macd_line: f64, macd_signal: f64, macd_hist: f64,
        dmi_plus: f64, dmi_minus: f64, adx: f64,
        atr: f64, atr_r: f64,
        stoch_k: f64, stoch_d: f64,
        williams_r: f64, cci: f64, mfi: f64,
        roc_1: f64, roc_3: f64, roc_6: f64, roc_12: f64,
        obv_slope_12: f64, volume_sma_20: f64, vol_accel: f64,
        // Multi-timeframe
        tf_1h_close: f64, tf_1h_high: f64, tf_1h_low: f64, tf_1h_ret: f64, tf_1h_body: f64,
        tf_4h_close: f64, tf_4h_high: f64, tf_4h_low: f64, tf_4h_ret: f64, tf_4h_body: f64,
        // Ichimoku
        tenkan_sen: f64, kijun_sen: f64, senkou_span_a: f64, senkou_span_b: f64,
        cloud_top: f64, cloud_bottom: f64,
        // Keltner + derived
        kelt_upper: f64, kelt_lower: f64, kelt_pos: f64, squeeze: i32,
        range_pos_12: f64, range_pos_24: f64, range_pos_48: f64,
        trend_consistency_6: f64, trend_consistency_12: f64, trend_consistency_24: f64,
        atr_roc_6: f64, atr_roc_12: f64,
        // Time
        hour: f64, day_of_week: f64,
    },
    LearnedStopLog {
        step: i64,
        candle_idx: i64,
        recommended_distance_pct: f64,  // what the learned stop said
        learned_k_trail: f64,           // distance / ATR
        pair_count: i64,                // how many (thought, distance) pairs accumulated
        atr: f64,                       // current ATR for context
    },
    BatchCommit,
}

// ─── flush_logs ─────────────────────────────────────────────────────────────
// The interpreter. Turns descriptions into side effects.

pub fn flush_logs(entries: &[LogEntry], conn: &Connection) {
    for entry in entries {
        match entry {
            LogEntry::CandleLog {
                step, candle_idx, timestamp, tht_cos, tht_conviction, tht_pred,
                meta_pred, meta_conviction, actual, traded, position_frac, equity, outcome_pct,
                usdc_bal, wbtc_bal, usdc_deployed, wbtc_deployed,
            } => {
                conn.execute(
                    "INSERT INTO candle_log
                     (step,candle_idx,timestamp,
                      tht_cos,tht_conviction,tht_pred,
                      meta_pred,meta_conviction,
                      actual,traded,position_frac,equity,outcome_pct,
                      usdc_bal,wbtc_bal,usdc_deployed,wbtc_deployed)
                     VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)",
                    params![step, candle_idx, timestamp, tht_cos, tht_conviction, tht_pred,
                            meta_pred, meta_conviction, actual, traded, position_frac, equity, outcome_pct,
                            usdc_bal, wbtc_bal, usdc_deployed, wbtc_deployed],
                ).ok();
            }
            LogEntry::TradeLedger {
                step, candle_idx, timestamp, exit_candle_idx, exit_timestamp,
                direction, conviction, high_conviction,
                entry_price, exit_price, position_frac, position_usd,
                gross_return_pct, swap_fee_pct, slippage_pct, net_return_pct,
                pnl_usd, equity_after,
                max_favorable_pct, max_adverse_pct,
                crossing_candles, horizon_candles, outcome, won, exit_reason,
            } => {
                conn.execute(
                    "INSERT INTO trade_ledger
                     (step,candle_idx,timestamp,exit_candle_idx,exit_timestamp,
                      direction,conviction,high_conviction,
                      entry_price,exit_price,position_frac,position_usd,
                      gross_return_pct,swap_fee_pct,slippage_pct,net_return_pct,
                      pnl_usd,equity_after,
                      max_favorable_pct,max_adverse_pct,
                      crossing_candles,horizon_candles,outcome,won,exit_reason)
                     VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25)",
                    params![step, candle_idx, timestamp, exit_candle_idx, exit_timestamp,
                            direction, conviction, high_conviction,
                            entry_price, exit_price, position_frac, position_usd,
                            gross_return_pct, swap_fee_pct, slippage_pct, net_return_pct,
                            pnl_usd, equity_after,
                            max_favorable_pct, max_adverse_pct,
                            crossing_candles, horizon_candles, outcome, won, exit_reason],
                ).ok();
            }
            LogEntry::PositionOpen {
                step, candle_idx, timestamp, direction, entry_price, position_usd, swap_fee_pct,
            } => {
                conn.execute(
                    "INSERT INTO trade_ledger (step,candle_idx,timestamp,direction,entry_price,position_usd,swap_fee_pct,exit_reason)
                     VALUES (?1,?2,?3,?4,?5,?6,?7,'Open')",
                    params![step, candle_idx, timestamp, direction.to_string(), entry_price, position_usd, swap_fee_pct],
                ).ok();
            }
            LogEntry::PositionExit {
                step, candle_idx, timestamp, direction, entry_price, exit_price,
                gross_return_pct, position_usd, swap_fee_pct, horizon_candles, won, exit_reason,
            } => {
                conn.execute(
                    "INSERT INTO trade_ledger (step,candle_idx,timestamp,direction,entry_price,exit_price,gross_return_pct,position_usd,swap_fee_pct,horizon_candles,won,exit_reason)
                     VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",
                    params![step, candle_idx, timestamp, direction.to_string(), entry_price, exit_price,
                            gross_return_pct, position_usd, swap_fee_pct, horizon_candles, won, exit_reason],
                ).ok();
            }
            LogEntry::RecalibLog {
                step, journal, cos_raw, disc_strength, buy_count, sell_count,
                buy_norm, sell_norm, proto_cosine,
            } => {
                conn.execute(
                    "INSERT INTO recalib_log (step,journal,cos_raw,disc_strength,buy_count,sell_count,buy_norm,sell_norm,proto_cosine)
                     VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
                    params![step, journal, cos_raw, disc_strength, buy_count, sell_count,
                            buy_norm, sell_norm, proto_cosine],
                ).ok();
            }
            LogEntry::DiscDecode {
                step, journal, rank, fact_label, cosine,
            } => {
                conn.execute(
                    "INSERT INTO disc_decode (step,journal,rank,fact_label,cosine)
                     VALUES (?1,?2,?3,?4,?5)",
                    params![step, journal, rank, fact_label, cosine],
                ).ok();
            }
            LogEntry::ObserverLog {
                step, observer, conviction, direction, correct,
            } => {
                conn.execute(
                    "INSERT INTO observer_log (step,observer,conviction,direction,correct)
                     VALUES (?1,?2,?3,?4,?5)",
                    params![step, observer, conviction, direction, correct],
                ).ok();
            }
            LogEntry::RiskLog {
                step, drawdown_pct, streak_len, streak_dir, recent_acc, equity_pct, won,
            } => {
                conn.execute(
                    "INSERT INTO risk_log (step,drawdown_pct,streak_len,streak_dir,recent_acc,equity_pct,won)
                     VALUES (?1,?2,?3,?4,?5,?6,?7)",
                    params![step, drawdown_pct, streak_len, streak_dir, recent_acc, equity_pct, won],
                ).ok();
            }
            LogEntry::TradeFact {
                step, fact_label,
            } => {
                conn.execute(
                    "INSERT INTO trade_facts (step, fact_label) VALUES (?1, ?2)",
                    params![step, fact_label],
                ).ok();
            }
            LogEntry::TradeVector {
                step, won, tht_data,
            } => {
                conn.execute(
                    "INSERT INTO trade_vectors (step, won, tht_data) VALUES (?1, ?2, ?3)",
                    params![step, won, tht_data],
                ).ok();
            }
            LogEntry::CandleSnapshot {
                candle_idx, ts,
                open, high, low, close, volume,
                sma20, sma50, sma200,
                bb_upper, bb_lower, bb_width, bb_pos,
                rsi, macd_line, macd_signal, macd_hist,
                dmi_plus, dmi_minus, adx, atr, atr_r,
                stoch_k, stoch_d, williams_r, cci, mfi,
                roc_1, roc_3, roc_6, roc_12,
                obv_slope_12, volume_sma_20, vol_accel,
                tf_1h_close, tf_1h_high, tf_1h_low, tf_1h_ret, tf_1h_body,
                tf_4h_close, tf_4h_high, tf_4h_low, tf_4h_ret, tf_4h_body,
                tenkan_sen, kijun_sen, senkou_span_a, senkou_span_b,
                cloud_top, cloud_bottom,
                kelt_upper, kelt_lower, kelt_pos, squeeze,
                range_pos_12, range_pos_24, range_pos_48,
                trend_consistency_6, trend_consistency_12, trend_consistency_24,
                atr_roc_6, atr_roc_12,
                hour, day_of_week,
            } => {
                conn.execute(
                    "INSERT INTO candle_snapshot (
                        candle_idx, ts,
                        open, high, low, close, volume,
                        sma20, sma50, sma200,
                        bb_upper, bb_lower, bb_width, bb_pos,
                        rsi, macd_line, macd_signal, macd_hist,
                        dmi_plus, dmi_minus, adx, atr, atr_r,
                        stoch_k, stoch_d, williams_r, cci, mfi,
                        roc_1, roc_3, roc_6, roc_12,
                        obv_slope_12, volume_sma_20, vol_accel,
                        tf_1h_close, tf_1h_high, tf_1h_low, tf_1h_ret, tf_1h_body,
                        tf_4h_close, tf_4h_high, tf_4h_low, tf_4h_ret, tf_4h_body,
                        tenkan_sen, kijun_sen, senkou_span_a, senkou_span_b,
                        cloud_top, cloud_bottom,
                        kelt_upper, kelt_lower, kelt_pos, squeeze,
                        range_pos_12, range_pos_24, range_pos_48,
                        trend_consistency_6, trend_consistency_12, trend_consistency_24,
                        atr_roc_6, atr_roc_12,
                        hour, day_of_week
                    ) VALUES (
                        ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,
                        ?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,
                        ?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,
                        ?31,?32,?33,?34,?35,?36,?37,?38,?39,?40,
                        ?41,?42,?43,?44,?45,?46,?47,?48,?49,?50,
                        ?51,?52,?53,?54,?55,?56,?57,?58,?59,?60,
                        ?61,?62,?63,?64,?65
                    )",
                    params![
                        candle_idx, ts,
                        open, high, low, close, volume,
                        sma20, sma50, sma200,
                        bb_upper, bb_lower, bb_width, bb_pos,
                        rsi, macd_line, macd_signal, macd_hist,
                        dmi_plus, dmi_minus, adx, atr, atr_r,
                        stoch_k, stoch_d, williams_r, cci, mfi,
                        roc_1, roc_3, roc_6, roc_12,
                        obv_slope_12, volume_sma_20, vol_accel,
                        tf_1h_close, tf_1h_high, tf_1h_low, tf_1h_ret, tf_1h_body,
                        tf_4h_close, tf_4h_high, tf_4h_low, tf_4h_ret, tf_4h_body,
                        tenkan_sen, kijun_sen, senkou_span_a, senkou_span_b,
                        cloud_top, cloud_bottom,
                        kelt_upper, kelt_lower, kelt_pos, squeeze,
                        range_pos_12, range_pos_24, range_pos_48,
                        trend_consistency_6, trend_consistency_12, trend_consistency_24,
                        atr_roc_6, atr_roc_12,
                        hour, day_of_week,
                    ],
                ).map_err(|e| eprintln!("candle_snapshot insert error: {}", e)).ok();
            }
            LogEntry::LearnedStopLog {
                step, candle_idx, recommended_distance_pct, learned_k_trail, pair_count, atr,
            } => {
                conn.execute(
                    "INSERT INTO learned_stop_log (step,candle_idx,recommended_distance_pct,learned_k_trail,pair_count,atr)
                     VALUES (?1,?2,?3,?4,?5,?6)",
                    params![step, candle_idx, recommended_distance_pct, learned_k_trail, pair_count, atr],
                ).ok();
            }
            LogEntry::BatchCommit => {
                conn.execute_batch("COMMIT; BEGIN").ok();
            }
        };
    }
}

// ─── Ledger ─────────────────────────────────────────────────────────────────
// The ledger records everything. It doesn't decide anything. It counts.

pub fn init_ledger(path: &str) -> Connection {
    let db = Connection::open(path).expect("failed to open ledger");
    db.execute_batch("
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;

        CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT
        );

        -- One row per expired pending entry.
        CREATE TABLE IF NOT EXISTS candle_log (
            step             INTEGER PRIMARY KEY,
            candle_idx       INTEGER,
            timestamp        TEXT,
            -- thought journal
            tht_cos          REAL,
            tht_conviction   REAL,
            tht_pred         TEXT,
            -- manager output
            meta_pred        TEXT,
            meta_conviction  REAL,
            -- what actually happened
            actual           TEXT,    -- 'Buy' | 'Sell' | 'Noise'
            -- paper trading
            traded           INTEGER, -- 1 if a position was taken
            position_frac    REAL,
            equity           REAL,    -- treasury total value (all assets at market price)
            outcome_pct      REAL,    -- price change at first threshold crossing
            -- treasury state (units held, not USD value)
            usdc_bal         REAL,    -- USDC available balance
            wbtc_bal         REAL,    -- WBTC available balance
            usdc_deployed    REAL,    -- USDC locked in positions
            wbtc_deployed    REAL     -- WBTC locked in positions
        );

        -- One row per journal recalibration.
        CREATE TABLE IF NOT EXISTS recalib_log (
            step          INTEGER,  -- candle index when recalib fired
            journal       TEXT,     -- observer name or 'thought'
            cos_raw       REAL,     -- cos(buy_proto, sell_proto) before discrimination
            disc_strength REAL,     -- separating signal available (0=none, 1=fully separated)
            buy_count     INTEGER,
            sell_count    INTEGER,
            buy_norm      REAL,     -- L2 norm of Buy prototype
            sell_norm     REAL,     -- L2 norm of Sell prototype
            proto_cosine  REAL      -- cosine between Buy and Sell prototypes
        );

        -- Top fact contributions to discriminant at each recalibration.
        CREATE TABLE IF NOT EXISTS disc_decode (
            step          INTEGER,  -- recalib step
            journal       TEXT,
            rank          INTEGER,  -- 1 = most influential
            fact_label    TEXT,
            cosine        REAL      -- +buy / -sell
        );

        -- Facts present for each traded candle (flip zone trades only).
        CREATE TABLE IF NOT EXISTS trade_facts (
            step          INTEGER,  -- candle_log step
            fact_label    TEXT
        );

        -- Per-observer predictions logged at entry expiry.
        CREATE TABLE IF NOT EXISTS observer_log (
            step          INTEGER,
            observer      TEXT,
            conviction    REAL,
            direction     TEXT,     -- raw (un-flipped) prediction
            correct       INTEGER   -- 1 if flipped prediction matches actual
        );

        -- Risk state at each trade resolution.
        CREATE TABLE IF NOT EXISTS risk_log (
            step          INTEGER,
            drawdown_pct  REAL,
            streak_len    INTEGER,
            streak_dir    TEXT,     -- 'winning' | 'losing'
            recent_acc    REAL,
            equity_pct    REAL,     -- equity change from initial
            won           INTEGER
        );

        CREATE TABLE IF NOT EXISTS learned_stop_log (
            step                      INTEGER,
            candle_idx                INTEGER,
            recommended_distance_pct  REAL,
            learned_k_trail           REAL,
            pair_count                INTEGER,
            atr                       REAL
        );

        -- The ledger. One row per resolved trade. Pure accounting — no hallucination.
        -- Every number is measured, not predicted. This is what the risk experts read.
        CREATE TABLE IF NOT EXISTS trade_ledger (
            step              INTEGER PRIMARY KEY,
            candle_idx        INTEGER,  -- entry candle
            timestamp         TEXT,     -- entry time
            exit_candle_idx   INTEGER,  -- candle where threshold crossed (NULL if expired as Noise)
            exit_timestamp    TEXT,
            direction         TEXT,     -- 'Buy' | 'Sell'
            conviction        REAL,     -- meta_conviction at entry
            high_conviction   INTEGER,  -- 1 if conviction >= threshold
            entry_price       REAL,
            exit_price        REAL,     -- price at first threshold crossing (or at horizon expiry)
            position_frac     REAL,     -- fraction of equity risked
            position_usd      REAL,     -- dollar value of position at entry
            gross_return_pct  REAL,     -- directional return before costs
            swap_fee_pct      REAL,     -- total swap fees (round trip)
            slippage_pct      REAL,     -- total slippage (round trip)
            net_return_pct    REAL,     -- gross - fees - slippage
            pnl_usd           REAL,     -- net dollar P&L
            equity_after      REAL,     -- equity after this trade
            max_favorable_pct REAL,     -- best excursion in our direction
            max_adverse_pct   REAL,     -- worst excursion against us
            crossing_candles  INTEGER,  -- candles from entry to threshold crossing (NULL if Noise)
            horizon_candles   INTEGER,  -- total candles this entry was pending
            outcome           TEXT,     -- 'Buy' | 'Sell' | 'Noise'
            won               INTEGER,  -- 1 if net_return > 0 (after costs)
            exit_reason       TEXT      -- 'ThresholdCrossing' | 'TrailingStop' | 'TakeProfit' | 'HorizonExpiry'
        );

        -- Full candle snapshot at trade resolution time. Every indicator value.
        -- Join with trade_facts to verify: does the indicator justify the fact?
        CREATE TABLE IF NOT EXISTS candle_snapshot (
            candle_idx        INTEGER PRIMARY KEY,
            ts                TEXT,
            open REAL, high REAL, low REAL, close REAL, volume REAL,
            sma20 REAL, sma50 REAL, sma200 REAL,
            bb_upper REAL, bb_lower REAL, bb_width REAL, bb_pos REAL,
            rsi REAL,
            macd_line REAL, macd_signal REAL, macd_hist REAL,
            dmi_plus REAL, dmi_minus REAL, adx REAL,
            atr REAL, atr_r REAL,
            stoch_k REAL, stoch_d REAL,
            williams_r REAL, cci REAL, mfi REAL,
            roc_1 REAL, roc_3 REAL, roc_6 REAL, roc_12 REAL,
            obv_slope_12 REAL, volume_sma_20 REAL, vol_accel REAL,
            tf_1h_close REAL, tf_1h_high REAL, tf_1h_low REAL, tf_1h_ret REAL, tf_1h_body REAL,
            tf_4h_close REAL, tf_4h_high REAL, tf_4h_low REAL, tf_4h_ret REAL, tf_4h_body REAL,
            tenkan_sen REAL, kijun_sen REAL, senkou_span_a REAL, senkou_span_b REAL,
            cloud_top REAL, cloud_bottom REAL,
            kelt_upper REAL, kelt_lower REAL, kelt_pos REAL, squeeze INTEGER,
            range_pos_12 REAL, range_pos_24 REAL, range_pos_48 REAL,
            trend_consistency_6 REAL, trend_consistency_12 REAL, trend_consistency_24 REAL,
            atr_roc_6 REAL, atr_roc_12 REAL,
            hour REAL, day_of_week REAL
        );

        -- Thought vectors for flip-zone trades (for engram analysis).
        CREATE TABLE IF NOT EXISTS trade_vectors (
            step          INTEGER PRIMARY KEY,
            won           INTEGER,  -- 1 if trade was correct
            tht_data      BLOB      -- bipolar thought vector (i8 array)
        );

        -- Accumulation model summary. Written at end of run.
        -- See wat/accumulation.wat for the full spec.
        CREATE TABLE IF NOT EXISTS accumulation_summary (
            asset             TEXT,     -- e.g. 'WBTC', 'USDC'
            total_accumulated REAL,     -- lifetime residue harvested
            total_lost        REAL,     -- lifetime loss from stop-outs
            trade_count       INTEGER,
            recovery_count    INTEGER,  -- principal recovered (wins)
            loss_count        INTEGER,  -- stopped out (losses)
            total_fees        REAL
        );
    ").expect("failed to init run DB");
    db
}

pub fn write_accumulation_summary(conn: &Connection, ledger: &crate::treasury::AccumulationLedger) {
    // Collect all assets from both maps
    let mut assets = std::collections::HashSet::new();
    for k in ledger.total_accumulated.keys() { assets.insert(k.clone()); }
    for k in ledger.total_lost.keys() { assets.insert(k.clone()); }
    for asset in &assets {
        conn.execute(
            "INSERT INTO accumulation_summary
             (asset, total_accumulated, total_lost, trade_count, recovery_count, loss_count, total_fees)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                asset.as_str(),
                ledger.accumulated(asset),
                ledger.lost(asset),
                ledger.trade_count as i64,
                ledger.recovery_count as i64,
                ledger.loss_count as i64,
                ledger.total_fees,
            ],
        ).ok();
    }
}

pub fn write_meta(conn: &Connection, key: &str, value: &str) {
    conn.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
        params![key, value],
    )
    .expect("failed to write meta");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static TEST_COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn test_db_path() -> String {
        let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
        let pid = std::process::id();
        format!("/tmp/test_ledger_{}_{}.db", pid, id)
    }

    #[test]
    fn init_ledger_creates_tables() {
        let path = test_db_path();
        let _ = std::fs::remove_file(&path);
        let conn = init_ledger(&path);

        let mut stmt = conn
            .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            .unwrap();
        let tables: Vec<String> = stmt
            .query_map([], |row| row.get(0))
            .unwrap()
            .map(|r| r.unwrap())
            .collect();

        let expected = [
            "candle_log",
            "disc_decode",
            "meta",
            "observer_log",
            "recalib_log",
            "risk_log",
            "trade_facts",
            "trade_ledger",
            "trade_vectors",
        ];
        for name in &expected {
            assert!(
                tables.contains(&name.to_string()),
                "missing table: {}",
                name
            );
        }

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn write_meta_stores_key_value() {
        let path = test_db_path();
        let _ = std::fs::remove_file(&path);
        let conn = init_ledger(&path);

        write_meta(&conn, "run_name", "test-run-42");

        let val: String = conn
            .query_row("SELECT value FROM meta WHERE key = ?1", params!["run_name"], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(val, "test-run-42");

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn flush_logs_empty_no_panic() {
        let path = test_db_path();
        let _ = std::fs::remove_file(&path);
        let conn = init_ledger(&path);

        flush_logs(&[], &conn);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn flush_logs_candle_log() {
        let path = test_db_path();
        let _ = std::fs::remove_file(&path);
        let conn = init_ledger(&path);

        let entries = vec![LogEntry::CandleLog {
            step: 1,
            candle_idx: 100,
            timestamp: "2025-01-01T00:00:00".to_string(),
            tht_cos: 0.85,
            tht_conviction: 0.72,
            tht_pred: Some("Buy".to_string()),
            meta_pred: Some("Buy".to_string()),
            meta_conviction: 0.65,
            actual: "Buy".to_string(),
            traded: 1,
            position_frac: Some(0.1),
            equity: 10000.0,
            outcome_pct: 1.5,
            usdc_bal: 9000.0,
            wbtc_bal: 0.01,
            usdc_deployed: 1000.0,
            wbtc_deployed: 0.0,
        }];

        flush_logs(&entries, &conn);

        let (step, equity): (i64, f64) = conn
            .query_row("SELECT step, equity FROM candle_log WHERE step = 1", [], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })
            .unwrap();
        assert_eq!(step, 1);
        assert!((equity - 10000.0).abs() < f64::EPSILON);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn flush_logs_position_open() {
        let path = test_db_path();
        let _ = std::fs::remove_file(&path);
        let conn = init_ledger(&path);

        let entries = vec![LogEntry::PositionOpen {
            step: 10,
            candle_idx: 200,
            timestamp: "2025-02-01T00:00:00".to_string(),
            direction: Direction::Long,
            entry_price: 42000.0,
            position_usd: 5000.0,
            swap_fee_pct: 0.001,
        }];

        flush_logs(&entries, &conn);

        let (step, dir, reason): (i64, String, String) = conn
            .query_row(
                "SELECT step, direction, exit_reason FROM trade_ledger WHERE step = 10",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(step, 10);
        assert_eq!(dir, "Buy");
        assert_eq!(reason, "Open");

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn flush_logs_position_exit() {
        let path = test_db_path();
        let _ = std::fs::remove_file(&path);
        let conn = init_ledger(&path);

        let entries = vec![LogEntry::PositionExit {
            step: 20,
            candle_idx: 300,
            timestamp: "2025-03-01T00:00:00".to_string(),
            direction: Direction::Short,
            entry_price: 50000.0,
            exit_price: 48000.0,
            gross_return_pct: 4.0,
            position_usd: 3000.0,
            swap_fee_pct: 0.001,
            horizon_candles: 12,
            won: 1,
            exit_reason: "ThresholdCrossing".to_string(),
        }];

        flush_logs(&entries, &conn);

        let (step, dir, won, reason): (i64, String, i32, String) = conn
            .query_row(
                "SELECT step, direction, won, exit_reason FROM trade_ledger WHERE step = 20",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .unwrap();
        assert_eq!(step, 20);
        assert_eq!(dir, "Sell");
        assert_eq!(won, 1);
        assert_eq!(reason, "ThresholdCrossing");

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn flush_logs_disc_decode() {
        let path = test_db_path();
        let _ = std::fs::remove_file(&path);
        let conn = init_ledger(&path);

        let entries = vec![LogEntry::DiscDecode {
            step: 30,
            journal: "thought".to_string(),
            rank: 1,
            fact_label: "rsi_oversold".to_string(),
            cosine: 0.87,
        }];

        flush_logs(&entries, &conn);

        let (step, rank, label, cos): (i64, i64, String, f64) = conn
            .query_row(
                "SELECT step, rank, fact_label, cosine FROM disc_decode WHERE step = 30",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .unwrap();
        assert_eq!(step, 30);
        assert_eq!(rank, 1);
        assert_eq!(label, "rsi_oversold");
        assert!((cos - 0.87).abs() < 1e-10);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn flush_logs_recalib_log() {
        let path = test_db_path();
        let _ = std::fs::remove_file(&path);
        let conn = init_ledger(&path);

        let entries = vec![LogEntry::RecalibLog {
            step: 40,
            journal: "momentum".to_string(),
            cos_raw: 0.12,
            disc_strength: 0.88,
            buy_count: 150,
            sell_count: 130,
            buy_norm: 1.0,
            sell_norm: 1.0,
            proto_cosine: 0.95,
        }];

        flush_logs(&entries, &conn);

        let (step, journal, cos_raw, buy_count): (i64, String, f64, i64) = conn
            .query_row(
                "SELECT step, journal, cos_raw, buy_count FROM recalib_log WHERE step = 40",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .unwrap();
        assert_eq!(step, 40);
        assert_eq!(journal, "momentum");
        assert!((cos_raw - 0.12).abs() < 1e-10);
        assert_eq!(buy_count, 150);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn flush_logs_trade_ledger() {
        let path = test_db_path();
        let _ = std::fs::remove_file(&path);
        let conn = init_ledger(&path);

        let entries = vec![LogEntry::TradeLedger {
            step: 50,
            candle_idx: 400,
            timestamp: "2025-04-01T00:00:00".to_string(),
            exit_candle_idx: Some(410),
            exit_timestamp: Some("2025-04-01T00:50:00".to_string()),
            direction: "Buy".to_string(),
            conviction: 0.75,
            high_conviction: 1,
            entry_price: 60000.0,
            exit_price: 61000.0,
            position_frac: 0.1,
            position_usd: 6000.0,
            gross_return_pct: 1.67,
            swap_fee_pct: 0.001,
            slippage_pct: 0.0025,
            net_return_pct: 1.33,
            pnl_usd: 80.0,
            equity_after: 10080.0,
            max_favorable_pct: 2.0,
            max_adverse_pct: 0.5,
            crossing_candles: Some(8),
            horizon_candles: 12,
            outcome: "Buy".to_string(),
            won: 1,
            exit_reason: "ThresholdCrossing".to_string(),
        }];

        flush_logs(&entries, &conn);

        let (step, dir, won, pnl): (i64, String, i32, f64) = conn
            .query_row(
                "SELECT step, direction, won, pnl_usd FROM trade_ledger WHERE step = 50",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .unwrap();
        assert_eq!(step, 50);
        assert_eq!(dir, "Buy");
        assert_eq!(won, 1);
        assert!((pnl - 80.0).abs() < 1e-10);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn flush_logs_observer_log() {
        let path = test_db_path();
        let _ = std::fs::remove_file(&path);
        let conn = init_ledger(&path);

        let entries = vec![LogEntry::ObserverLog {
            step: 60,
            observer: "momentum".to_string(),
            conviction: 0.65,
            direction: "Buy".to_string(),
            correct: 1,
        }];

        flush_logs(&entries, &conn);

        let (step, obs, correct): (i64, String, i32) = conn
            .query_row(
                "SELECT step, observer, correct FROM observer_log WHERE step = 60",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(step, 60);
        assert_eq!(obs, "momentum");
        assert_eq!(correct, 1);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn flush_logs_risk_log() {
        let path = test_db_path();
        let _ = std::fs::remove_file(&path);
        let conn = init_ledger(&path);

        let entries = vec![LogEntry::RiskLog {
            step: 70,
            drawdown_pct: 3.5,
            streak_len: 4,
            streak_dir: "losing".to_string(),
            recent_acc: 0.48,
            equity_pct: -2.0,
            won: 0,
        }];

        flush_logs(&entries, &conn);

        let (step, drawdown, streak): (i64, f64, i32) = conn
            .query_row(
                "SELECT step, drawdown_pct, streak_len FROM risk_log WHERE step = 70",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(step, 70);
        assert!((drawdown - 3.5).abs() < 1e-10);
        assert_eq!(streak, 4);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn flush_logs_trade_fact() {
        let path = test_db_path();
        let _ = std::fs::remove_file(&path);
        let conn = init_ledger(&path);

        let entries = vec![LogEntry::TradeFact {
            step: 80,
            fact_label: "rsi_bullish".to_string(),
        }];

        flush_logs(&entries, &conn);

        let (step, label): (i64, String) = conn
            .query_row(
                "SELECT step, fact_label FROM trade_facts WHERE step = 80",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(step, 80);
        assert_eq!(label, "rsi_bullish");

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn flush_logs_trade_vector() {
        let path = test_db_path();
        let _ = std::fs::remove_file(&path);
        let conn = init_ledger(&path);

        let data = vec![1u8, 2, 3, 4, 5];
        let entries = vec![LogEntry::TradeVector {
            step: 90,
            won: 1,
            tht_data: data.clone(),
        }];

        flush_logs(&entries, &conn);

        let (step, won, blob): (i64, i32, Vec<u8>) = conn
            .query_row(
                "SELECT step, won, tht_data FROM trade_vectors WHERE step = 90",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(step, 90);
        assert_eq!(won, 1);
        assert_eq!(blob, data);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn flush_logs_batch_commit() {
        let path = test_db_path();
        let _ = std::fs::remove_file(&path);
        let conn = init_ledger(&path);

        // Start a transaction so BatchCommit's "COMMIT; BEGIN" has something to commit
        conn.execute_batch("BEGIN").ok();
        let entries = vec![LogEntry::BatchCommit];
        flush_logs(&entries, &conn);
        // Should not panic — the batch commit succeeded

        let _ = std::fs::remove_file(&path);
    }
}
