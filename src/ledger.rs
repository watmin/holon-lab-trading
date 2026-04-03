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
            } => {
                conn.execute(
                    "INSERT INTO recalib_log (step,journal,cos_raw,disc_strength,buy_count,sell_count)
                     VALUES (?1,?2,?3,?4,?5,?6)",
                    params![step, journal, cos_raw, disc_strength, buy_count, sell_count],
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
            journal       TEXT,     -- 'thought'
            cos_raw       REAL,     -- cos(buy_proto, sell_proto) before discrimination
            disc_strength REAL,     -- separating signal available (0=none, 1=fully separated)
            buy_count     INTEGER,
            sell_count    INTEGER
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

        -- Thought vectors for flip-zone trades (for engram analysis).
        CREATE TABLE IF NOT EXISTS trade_vectors (
            step          INTEGER PRIMARY KEY,
            won           INTEGER,  -- 1 if trade was correct
            tht_data      BLOB      -- bipolar thought vector (i8 array)
        );
    ").expect("failed to init run DB");
    db
}
