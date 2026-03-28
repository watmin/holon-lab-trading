use rusqlite::Connection;

// ─── DB setup ────────────────────────────────────────────────────────────────

pub fn init_run_db(path: &str) -> Connection {
    let db = Connection::open(path).expect("failed to open run DB");
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
            -- visual journal
            vis_cos          REAL,    -- signed cosine vs discriminant (+buy, -sell)
            vis_conviction   REAL,    -- |vis_cos|
            vis_pred         TEXT,    -- 'Buy' | 'Sell' | NULL
            -- thought journal
            tht_cos          REAL,
            tht_conviction   REAL,
            tht_pred         TEXT,
            -- agreement (NULL if either journal had no prediction yet)
            agree            INTEGER,
            -- orchestration output
            meta_pred        TEXT,
            meta_conviction  REAL,
            -- what actually happened
            actual           TEXT,    -- 'Buy' | 'Sell' | 'Noise'
            -- paper trading
            traded           INTEGER, -- 1 if a position was taken
            position_frac    REAL,
            equity           REAL,    -- equity after this trade resolved
            outcome_pct      REAL     -- price change at first threshold crossing
        );

        -- One row per journal recalibration.
        CREATE TABLE IF NOT EXISTS recalib_log (
            step          INTEGER,  -- candle index when recalib fired
            journal       TEXT,     -- 'visual' | 'thought'
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

        -- Thought subspace state at each recalibration.
        CREATE TABLE IF NOT EXISTS subspace_log (
            step            INTEGER,
            residual        REAL,     -- current candle's thought residual
            threshold       REAL,     -- adaptive anomaly threshold
            explained       REAL,     -- fraction of variance explained
            top_eigenvalues TEXT      -- JSON array of top-5 eigenvalues
        );

        -- Per-expert predictions logged at entry expiry.
        CREATE TABLE IF NOT EXISTS expert_log (
            step          INTEGER,
            expert        TEXT,
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
            was_flipped       INTEGER,  -- 1 if flip was active
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

        -- Visual + thought vectors for flip-zone trades (for engram analysis).
        CREATE TABLE IF NOT EXISTS trade_vectors (
            step          INTEGER PRIMARY KEY,
            won           INTEGER,  -- 1 if trade was correct
            vis_data      BLOB,     -- bipolar visual vector (i8 array)
            tht_data      BLOB      -- bipolar thought vector (i8 array)
        );

        -- Desk predictions: every desk's paper trail.
        -- One row per resolved prediction per desk.
        CREATE TABLE IF NOT EXISTS desk_predictions (
            desk          TEXT,       -- desk name (e.g. 'desk-48c')
            candle_idx    INTEGER,    -- entry candle
            conviction    REAL,       -- prediction conviction
            direction     TEXT,       -- predicted direction (flipped)
            outcome       TEXT,       -- actual: 'Buy' | 'Sell' | 'Noise'
            correct       INTEGER,    -- 1 if flipped prediction matched outcome
            gross_pct     REAL,       -- price change at threshold crossing
            window        INTEGER,    -- desk window size
            horizon       INTEGER     -- desk horizon size
        );
    ").expect("failed to init run DB");
    db
}
