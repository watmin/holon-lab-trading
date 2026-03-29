;; ── narrative expert ────────────────────────────────────────────────
;;
;; Thinks about: the story of what happened and when.
;; Vocabulary: PELT segment narrative, temporal lookback, calendar.
;; Window: sampled from [12, 2016] per candle.
;;
;; The narrative expert tells the story: "RSI was trending up for 8
;; candles, then reversed 3 candles ago, during the Asian session,
;; on a Friday." It's the only expert that knows WHEN things happened
;; relative to trading sessions and days of the week.

;; ── Eval methods ────────────────────────────────────────────────────
;; eval_segment_narrative   — PELT changepoints → 17 indicator streams → segments
;; eval_temporal            — lookback through segments for cross timing
;; eval_calendar            — day of week, 4-hour block, trading session

;; ── Example thoughts ────────────────────────────────────────────────
;;
;; (bundle
;;   (seg rsi up 0.0234 dur=8 @0 ago=0)       ; RSI trending up, 8 candles, most recent
;;   (seg close down 134.5 dur=15 @1 ago=8)    ; close was falling, 15 candles, before that
;;   (zone rsi rsi-overbought beginning @0)    ; RSI entered overbought at segment 0 start
;;   (since crosses-above close sma50 2seg)    ; SMA50 cross was 2 segments ago
;;   (at-day friday)                            ; it's Friday
;;   (at-hour h20)                              ; 20:00-23:59 UTC block
;;   (at-session off-hours)                     ; thin liquidity period
;;   ...)

;; ── UNIQUE PROPERTY ─────────────────────────────────────────────────
;; Narrative is the only expert with calendar awareness. It knows
;; that Friday off-hours behaves differently from Tuesday US session.
;; This means the manager's temporal encoding (hour-of-day, session)
;; partially duplicates what narrative already sees.
;;
;; DISCOVERY: Is this duplication harmful or helpful? The narrative
;; expert encodes calendar as PART of its thought vector (bundled with
;; segment narrative). The manager encodes it as a SEPARATE fact.
;; The manager's version is bound with a manager-level atom, so it's
;; structurally distinct. The narrative's version is bound with
;; narrative-level atoms. They're in different hyperspaces — no
;; collision. But the manager is getting temporal signal twice:
;; once from the narrative expert's signed conviction (which
;; incorporates calendar effects) and once from its own temporal atoms.
;; Is the redundancy noise or reinforcement?

;; ── WINDOW SENSITIVITY ──────────────────────────────────────────────
;; Narrative is window-dependent through PELT segments and temporal
;; lookback. The "story" changes at different window sizes — a
;; 48-candle story has different chapters than a 500-candle story.
;; But calendar facts are window-independent (day of week doesn't
;; change with window size).

;; ── What narrative does NOT see ─────────────────────────────────────
;; - Comparisons (momentum, structure)
;; - Oscillator zones (momentum)
;; - RSI divergence (momentum)
;; - Volume (volume)
;; - Ichimoku / Fibonacci / Keltner (structure)
;; - Range position (structure)
;; - Advanced regime indicators (regime, momentum, structure)
