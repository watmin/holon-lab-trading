;; wat/treasury/treasury.wat — Treasury lib (pure helpers on the
;; :trading::treasury::Treasury value).
;;
;; Lab experiment 008 (2026-04-26). Implements the per-event work
;; the Treasury performs. All ops are values-up (per Proposal 055
;; and the substrate's zero-mutex discipline): mutating helpers
;; return a new Treasury + a result; original Treasury unchanged.
;;
;; The service wrapper at `wat/services/treasury.wat` calls into
;; these helpers from its select loop; the test driver at
;; `wat-tests-integ/experiment/008-treasury-program/explore-treasury.wat`
;; exercises them through the service.
;;
;; v1 (experiment 008): fixed deadline (288 candles) — no ATR
;; field on Treasury. ATR-adjusted deadline lands when candles
;; are wired in (009+).
;;
;; ── Surface ──
;;   :trading::treasury::Treasury::fresh entry-fee exit-fee balances
;;     -> Treasury
;;   :trading::treasury::Treasury::issue-paper t owner from to price candle deadline-candles
;;     -> (Treasury, Receipt)
;;   :trading::treasury::Treasury::issue-real t owner from to price candle deadline-candles
;;     -> (Treasury, Option<Receipt>)
;;   :trading::treasury::Treasury::validate-exit t paper-id current-price
;;     -> Option<f64>
;;   :trading::treasury::Treasury::resolve-grace t paper-id current-price
;;     -> (Treasury, Option<Verdict>)
;;   :trading::treasury::Treasury::check-deadlines t current-candle current-price
;;     -> (Treasury, Verdicts)
;;   :trading::treasury::Treasury::gate-predicate record
;;     -> bool
;;   :trading::treasury::Treasury::active-paper-count t
;;     -> i64

(:wat::load-file! "types.wat")


;; ─── Treasury::fresh — empty constructor ──────────────────────────
;;
;; All four maps start empty. id counters at 0. Caller passes
;; entry-fee / exit-fee (e.g. 0.0035 = 0.35%) and an initial
;; balances map.
(:wat::core::define
  (:trading::treasury::Treasury::fresh
    (entry-fee :wat::core::f64)
    (exit-fee  :wat::core::f64)
    (balances  :trading::treasury::Balances)
    -> :trading::treasury::Treasury)
  (:trading::treasury::Treasury/new
    (:wat::core::HashMap :(i64,trading::treasury::Paper))
    (:wat::core::HashMap :(i64,trading::treasury::Real))
    (:wat::core::HashMap :(i64,trading::treasury::ProposerRecord))
    balances
    0    ; next-paper-id
    0    ; next-real-id
    entry-fee
    exit-fee))


;; ─── ProposerRecord::fresh — zero-counter constructor ─────────────
(:wat::core::define
  (:trading::treasury::ProposerRecord::fresh
    -> :trading::treasury::ProposerRecord)
  (:trading::treasury::ProposerRecord/new
    0   ; paper-submitted
    0   ; paper-survived
    0   ; paper-failed
    0.0 ; paper-grace-residue
    0   ; real-submitted
    0   ; real-survived
    0   ; real-failed
    0.0 ; real-grace-residue
    0.0)) ; real-violence-loss


;; ─── Helpers — record lookup / increment ──────────────────────────
;;
;; Get the proposer-record for `owner`, or a fresh-zero one if absent.
(:wat::core::define
  (:trading::treasury::Treasury/get-or-fresh-record
    (t :trading::treasury::Treasury)
    (owner :wat::core::i64)
    -> :trading::treasury::ProposerRecord)
  (:wat::core::match
    (:wat::core::get
      (:trading::treasury::Treasury/proposer-records t)
      owner)
    -> :trading::treasury::ProposerRecord
    ((Some r) r)
    (:None (:trading::treasury::ProposerRecord::fresh))))


;; ─── Treasury::issue-paper — always succeeds ──────────────────────
;;
;; Per Proposal 055: papers are proof of thoughts. No capital moves.
;; Fixed amount = $10,000 reference. Returns (Treasury', Receipt).
(:wat::core::define
  (:trading::treasury::Treasury::issue-paper
    (t :trading::treasury::Treasury)
    (owner :wat::core::i64)
    (from-asset :wat::core::String)
    (to-asset :wat::core::String)
    (price :wat::core::f64)
    (candle :wat::core::i64)
    (deadline-candles :wat::core::i64)
    -> :(trading::treasury::Treasury,trading::treasury::Receipt))
  (:wat::core::let*
    (((id :wat::core::i64) (:trading::treasury::Treasury/next-paper-id t))
     ((amount :wat::core::f64) 10000.0)
     ((entry-fee :wat::core::f64) (:trading::treasury::Treasury/entry-fee t))
     ((fee :wat::core::f64) (:wat::core::* amount entry-fee))
     ((units :wat::core::f64) (:wat::core::/ (:wat::core::- amount fee) price))
     ((deadline :wat::core::i64) (:wat::core::+ candle deadline-candles))
     ((paper :trading::treasury::Paper)
      (:trading::treasury::Paper/new
        id owner from-asset to-asset
        amount units price candle deadline
        :trading::treasury::PositionState::Active))
     ((receipt :trading::treasury::Receipt)
      (:trading::treasury::Receipt/new
        id owner from-asset to-asset
        amount units price candle deadline))
     ((papers' :trading::treasury::Papers)
      (:wat::core::assoc (:trading::treasury::Treasury/papers t) id paper))
     ((record :trading::treasury::ProposerRecord)
      (:trading::treasury::Treasury/get-or-fresh-record t owner))
     ((record' :trading::treasury::ProposerRecord)
      (:trading::treasury::ProposerRecord/new
        (:wat::core::+ (:trading::treasury::ProposerRecord/paper-submitted record) 1)
        (:trading::treasury::ProposerRecord/paper-survived record)
        (:trading::treasury::ProposerRecord/paper-failed record)
        (:trading::treasury::ProposerRecord/paper-grace-residue record)
        (:trading::treasury::ProposerRecord/real-submitted record)
        (:trading::treasury::ProposerRecord/real-survived record)
        (:trading::treasury::ProposerRecord/real-failed record)
        (:trading::treasury::ProposerRecord/real-grace-residue record)
        (:trading::treasury::ProposerRecord/real-violence-loss record)))
     ((records' :trading::treasury::ProposerRecords)
      (:wat::core::assoc
        (:trading::treasury::Treasury/proposer-records t) owner record'))
     ((t' :trading::treasury::Treasury)
      (:trading::treasury::Treasury/new
        papers'
        (:trading::treasury::Treasury/reals t)
        records'
        (:trading::treasury::Treasury/balances t)
        (:wat::core::+ id 1)
        (:trading::treasury::Treasury/next-real-id t)
        (:trading::treasury::Treasury/entry-fee t)
        (:trading::treasury::Treasury/exit-fee t))))
    (:wat::core::tuple t' receipt)))


;; ─── Treasury::gate-predicate — does this record pass the gate? ──
;;
;; Per Proposal 055: paper-submitted >= 50 AND survival_rate > 0.5.
;; Reads PAPER stats only (paper is proof of thoughts; gate decides
;; whether the broker has earned real-capital trust).
(:wat::core::define
  (:trading::treasury::Treasury::gate-predicate
    (record :trading::treasury::ProposerRecord)
    -> :wat::core::bool)
  (:wat::core::let*
    (((submitted :wat::core::i64)
      (:trading::treasury::ProposerRecord/paper-submitted record))
     ((survived :wat::core::i64)
      (:trading::treasury::ProposerRecord/paper-survived record))
     ((failed :wat::core::i64)
      (:trading::treasury::ProposerRecord/paper-failed record))
     ((resolved :wat::core::i64) (:wat::core::+ survived failed))
     ((survival-rate :wat::core::f64)
      (:wat::core::if (:wat::core::> resolved 0) -> :wat::core::f64
        (:wat::core::/ (:wat::core::i64::to-f64 survived)
                       (:wat::core::i64::to-f64 resolved))
        0.0)))
    (:wat::core::and
      (:wat::core::>= submitted 50)
      (:wat::core::> survival-rate 0.5))))


;; ─── Treasury::issue-real — gated on proven record + balance ──────
;;
;; Real positions move actual capital. Treasury decides amount
;; (v1: $50 fixed, capped at available balance). Per Proposal 055:
;; broker doesn't request a number, only a direction.
;;
;; Returns (Treasury', Option<Receipt>). None if denied (no record /
;; gate fail / insufficient balance).
(:wat::core::define
  (:trading::treasury::Treasury::issue-real
    (t :trading::treasury::Treasury)
    (owner :wat::core::i64)
    (from-asset :wat::core::String)
    (to-asset :wat::core::String)
    (price :wat::core::f64)
    (candle :wat::core::i64)
    (deadline-candles :wat::core::i64)
    -> :(trading::treasury::Treasury,Option<trading::treasury::Receipt>))
  (:wat::core::let*
    (((maybe-record :Option<trading::treasury::ProposerRecord>)
      (:wat::core::get
        (:trading::treasury::Treasury/proposer-records t) owner)))
    (:wat::core::match maybe-record
      -> :(trading::treasury::Treasury,Option<trading::treasury::Receipt>)
      (:None (:wat::core::tuple t :None))
      ((Some record)
        (:wat::core::if
          (:wat::core::not (:trading::treasury::Treasury::gate-predicate record))
          -> :(trading::treasury::Treasury,Option<trading::treasury::Receipt>)
          (:wat::core::tuple t :None)
          ;; Gate passed — check balance.
          (:wat::core::let*
            (((maybe-balance :Option<f64>)
              (:wat::core::get
                (:trading::treasury::Treasury/balances t) from-asset)))
            (:wat::core::match maybe-balance
              -> :(trading::treasury::Treasury,Option<trading::treasury::Receipt>)
              (:None (:wat::core::tuple t :None))
              ((Some balance)
                (:wat::core::if (:wat::core::<= balance 0.0)
                  -> :(trading::treasury::Treasury,Option<trading::treasury::Receipt>)
                  (:wat::core::tuple t :None)
                  ;; Treasury picks amount: min(50, balance).
                  (:wat::core::let*
                    (((amount :wat::core::f64)
                      (:wat::core::if (:wat::core::< balance 50.0)
                                      -> :wat::core::f64 balance 50.0))
                     ((id :wat::core::i64) (:trading::treasury::Treasury/next-real-id t))
                     ((entry-fee :wat::core::f64) (:trading::treasury::Treasury/entry-fee t))
                     ((fee :wat::core::f64) (:wat::core::* amount entry-fee))
                     ((units :wat::core::f64) (:wat::core::/ (:wat::core::- amount fee) price))
                     ((deadline :wat::core::i64) (:wat::core::+ candle deadline-candles))
                     ((real :trading::treasury::Real)
                      (:trading::treasury::Real/new
                        id owner from-asset to-asset
                        amount units price candle deadline
                        :trading::treasury::PositionState::Active))
                     ((receipt :trading::treasury::Receipt)
                      (:trading::treasury::Receipt/new
                        id owner from-asset to-asset
                        amount units price candle deadline))
                     ((reals' :trading::treasury::Reals)
                      (:wat::core::assoc
                        (:trading::treasury::Treasury/reals t) id real))
                     ((balances' :trading::treasury::Balances)
                      (:wat::core::assoc
                        (:trading::treasury::Treasury/balances t)
                        from-asset
                        (:wat::core::- balance amount)))
                     ((t' :trading::treasury::Treasury)
                      (:trading::treasury::Treasury/new
                        (:trading::treasury::Treasury/papers t)
                        reals'
                        (:trading::treasury::Treasury/proposer-records t)
                        balances'
                        (:trading::treasury::Treasury/next-paper-id t)
                        (:wat::core::+ id 1)
                        entry-fee
                        (:trading::treasury::Treasury/exit-fee t))))
                    (:wat::core::tuple t' (Some receipt))))))))))))


;; ─── Treasury::validate-exit — pure check, no mutation ────────────
;;
;; Returns Some(residue) if: paper exists AND state is Active AND
;; residue > 0 after exit fee. Else None (denied).
;;
;; residue = units * current-price - amount - exit-fee
;;         = units * current-price * (1 - exit-fee) - amount
;;
;; Note: works on PAPERS only in v1. Real-position resolve-grace
;; takes a separate path (uses balances). 008 doesn't exercise reals.
(:wat::core::define
  (:trading::treasury::Treasury::validate-exit
    (t :trading::treasury::Treasury)
    (paper-id :wat::core::i64)
    (current-price :wat::core::f64)
    -> :Option<f64>)
  (:wat::core::match
    (:wat::core::get (:trading::treasury::Treasury/papers t) paper-id)
    -> :Option<f64>
    (:None :None)
    ((Some paper)
      (:wat::core::match (:trading::treasury::Paper/state paper) -> :Option<f64>
        (:trading::treasury::PositionState::Active
          (:wat::core::let*
            (((units :wat::core::f64) (:trading::treasury::Paper/units-acquired paper))
             ((amount :wat::core::f64) (:trading::treasury::Paper/amount paper))
             ((current-value :wat::core::f64) (:wat::core::* units current-price))
             ((exit-fee :wat::core::f64) (:trading::treasury::Treasury/exit-fee t))
             ((fee :wat::core::f64) (:wat::core::* current-value exit-fee))
             ((residue :wat::core::f64)
              (:wat::core::- (:wat::core::- current-value amount) fee)))
            (:wat::core::if (:wat::core::> residue 0.0) -> :Option<f64>
              (Some residue)
              :None)))
        (_ :None)))))


;; ─── Treasury::resolve-grace — broker-proposed exit, validated ────
;;
;; Calls validate-exit. If approved: marks state Grace, increments
;; record's paper-survived + paper-grace-residue. Returns
;; (Treasury', Option<Verdict>).
(:wat::core::define
  (:trading::treasury::Treasury::resolve-grace
    (t :trading::treasury::Treasury)
    (paper-id :wat::core::i64)
    (current-price :wat::core::f64)
    -> :(trading::treasury::Treasury,Option<trading::treasury::Verdict>))
  (:wat::core::match
    (:trading::treasury::Treasury::validate-exit t paper-id current-price)
    -> :(trading::treasury::Treasury,Option<trading::treasury::Verdict>)
    (:None (:wat::core::tuple t :None))
    ((Some residue)
      (:wat::core::let*
        (((paper :trading::treasury::Paper)
          (:wat::core::match
            (:wat::core::get (:trading::treasury::Treasury/papers t) paper-id)
            -> :trading::treasury::Paper
            ((Some p) p)
            ;; Unreachable — validate-exit already confirmed presence.
            ;; Build a sentinel; if execution reaches here the substrate
            ;; has a bug elsewhere.
            (:None
              (:trading::treasury::Paper/new
                paper-id 0 "" "" 0.0 0.0 0.0 0 0
                :trading::treasury::PositionState::Active))))
         ((owner :wat::core::i64) (:trading::treasury::Paper/owner paper))
         ((paper' :trading::treasury::Paper)
          (:trading::treasury::Paper/new
            (:trading::treasury::Paper/paper-id paper)
            owner
            (:trading::treasury::Paper/from-asset paper)
            (:trading::treasury::Paper/to-asset paper)
            (:trading::treasury::Paper/amount paper)
            (:trading::treasury::Paper/units-acquired paper)
            (:trading::treasury::Paper/entry-price paper)
            (:trading::treasury::Paper/entry-candle paper)
            (:trading::treasury::Paper/deadline paper)
            (:trading::treasury::PositionState::Grace residue)))
         ((papers' :trading::treasury::Papers)
          (:wat::core::assoc
            (:trading::treasury::Treasury/papers t) paper-id paper'))
         ((record :trading::treasury::ProposerRecord)
          (:trading::treasury::Treasury/get-or-fresh-record t owner))
         ((record' :trading::treasury::ProposerRecord)
          (:trading::treasury::ProposerRecord/new
            (:trading::treasury::ProposerRecord/paper-submitted record)
            (:wat::core::+ (:trading::treasury::ProposerRecord/paper-survived record) 1)
            (:trading::treasury::ProposerRecord/paper-failed record)
            (:wat::core::+ (:trading::treasury::ProposerRecord/paper-grace-residue record) residue)
            (:trading::treasury::ProposerRecord/real-submitted record)
            (:trading::treasury::ProposerRecord/real-survived record)
            (:trading::treasury::ProposerRecord/real-failed record)
            (:trading::treasury::ProposerRecord/real-grace-residue record)
            (:trading::treasury::ProposerRecord/real-violence-loss record)))
         ((records' :trading::treasury::ProposerRecords)
          (:wat::core::assoc
            (:trading::treasury::Treasury/proposer-records t) owner record'))
         ((t' :trading::treasury::Treasury)
          (:trading::treasury::Treasury/new
            papers'
            (:trading::treasury::Treasury/reals t)
            records'
            (:trading::treasury::Treasury/balances t)
            (:trading::treasury::Treasury/next-paper-id t)
            (:trading::treasury::Treasury/next-real-id t)
            (:trading::treasury::Treasury/entry-fee t)
            (:trading::treasury::Treasury/exit-fee t)))
         ((verdict :trading::treasury::Verdict)
          (:trading::treasury::Verdict::Grace paper-id residue)))
        (:wat::core::tuple t' (Some verdict))))))


;; ─── Treasury::check-deadlines — autonomous Violence per tick ─────
;;
;; The treasury's only autonomous action (per Proposal 055). Walks
;; every Active paper; any with deadline ≤ current-candle becomes
;; Violence. Returns (Treasury', Verdicts).
;;
;; v1 (008): papers only. Real positions get the same treatment in
;; 009+ (will need to also restore balances per resolve-violence-real).
;;
;; Implementation: foldl over `(values papers)`, accumulating two
;; pieces — the updated papers map and the verdicts vec.
(:wat::core::define
  (:trading::treasury::Treasury::check-deadlines
    (t :trading::treasury::Treasury)
    (current-candle :wat::core::i64)
    (current-price :wat::core::f64)
    -> :(trading::treasury::Treasury,trading::treasury::Verdicts))
  (:wat::core::let*
    (((papers :trading::treasury::Papers)
      (:trading::treasury::Treasury/papers t))
     ;; Initial accumulator: (papers, verdicts, records)
     ((acc-init :(trading::treasury::Papers,trading::treasury::Verdicts,trading::treasury::ProposerRecords))
      (:wat::core::tuple
        papers
        (:wat::core::vec :trading::treasury::Verdict)
        (:trading::treasury::Treasury/proposer-records t)))
     ((final-acc
       :(trading::treasury::Papers,trading::treasury::Verdicts,trading::treasury::ProposerRecords))
      (:wat::core::foldl (:wat::core::values papers) acc-init
        (:wat::core::lambda
          ((acc :(trading::treasury::Papers,trading::treasury::Verdicts,trading::treasury::ProposerRecords))
           (paper :trading::treasury::Paper)
           -> :(trading::treasury::Papers,trading::treasury::Verdicts,trading::treasury::ProposerRecords))
          (:wat::core::let*
            (((papers-acc :trading::treasury::Papers) (:wat::core::first acc))
             ((verdicts-acc :trading::treasury::Verdicts) (:wat::core::second acc))
             ((records-acc :trading::treasury::ProposerRecords) (:wat::core::third acc))
             ((state :trading::treasury::PositionState)
              (:trading::treasury::Paper/state paper))
             ((id :wat::core::i64) (:trading::treasury::Paper/paper-id paper))
             ((deadline :wat::core::i64) (:trading::treasury::Paper/deadline paper))
             ((owner :wat::core::i64) (:trading::treasury::Paper/owner paper))
             ((expired? :wat::core::bool)
              (:wat::core::and
                (:wat::core::match state -> :wat::core::bool
                  (:trading::treasury::PositionState::Active true)
                  (_ false))
                (:wat::core::>= current-candle deadline))))
            (:wat::core::if expired? -> :(trading::treasury::Papers,trading::treasury::Verdicts,trading::treasury::ProposerRecords)
              (:wat::core::let*
                (((paper' :trading::treasury::Paper)
                  (:trading::treasury::Paper/new
                    id owner
                    (:trading::treasury::Paper/from-asset paper)
                    (:trading::treasury::Paper/to-asset paper)
                    (:trading::treasury::Paper/amount paper)
                    (:trading::treasury::Paper/units-acquired paper)
                    (:trading::treasury::Paper/entry-price paper)
                    (:trading::treasury::Paper/entry-candle paper)
                    deadline
                    :trading::treasury::PositionState::Violence))
                 ((papers' :trading::treasury::Papers)
                  (:wat::core::assoc papers-acc id paper'))
                 ((verdicts' :trading::treasury::Verdicts)
                  (:wat::core::conj verdicts-acc
                    (:trading::treasury::Verdict::Violence id)))
                 ((record :trading::treasury::ProposerRecord)
                  (:wat::core::match (:wat::core::get records-acc owner)
                    -> :trading::treasury::ProposerRecord
                    ((Some r) r)
                    (:None (:trading::treasury::ProposerRecord::fresh))))
                 ((record' :trading::treasury::ProposerRecord)
                  (:trading::treasury::ProposerRecord/new
                    (:trading::treasury::ProposerRecord/paper-submitted record)
                    (:trading::treasury::ProposerRecord/paper-survived record)
                    (:wat::core::+ (:trading::treasury::ProposerRecord/paper-failed record) 1)
                    (:trading::treasury::ProposerRecord/paper-grace-residue record)
                    (:trading::treasury::ProposerRecord/real-submitted record)
                    (:trading::treasury::ProposerRecord/real-survived record)
                    (:trading::treasury::ProposerRecord/real-failed record)
                    (:trading::treasury::ProposerRecord/real-grace-residue record)
                    (:trading::treasury::ProposerRecord/real-violence-loss record)))
                 ((records' :trading::treasury::ProposerRecords)
                  (:wat::core::assoc records-acc owner record')))
                (:wat::core::tuple papers' verdicts' records'))
              ;; Not expired (or not Active) — accumulator unchanged.
              acc))))))
    (:wat::core::let*
      (((papers' :trading::treasury::Papers) (:wat::core::first final-acc))
       ((verdicts :trading::treasury::Verdicts) (:wat::core::second final-acc))
       ((records' :trading::treasury::ProposerRecords) (:wat::core::third final-acc))
       ((t' :trading::treasury::Treasury)
        (:trading::treasury::Treasury/new
          papers'
          (:trading::treasury::Treasury/reals t)
          records'
          (:trading::treasury::Treasury/balances t)
          (:trading::treasury::Treasury/next-paper-id t)
          (:trading::treasury::Treasury/next-real-id t)
          (:trading::treasury::Treasury/entry-fee t)
          (:trading::treasury::Treasury/exit-fee t))))
      (:wat::core::tuple t' verdicts))))


;; ─── Treasury::active-paper-count — count Active papers ───────────
;;
;; Telemetry helper. Walks the papers map, counts entries with
;; PositionState::Active. O(N) in the map size; called per Tick
;; for the "active_papers" metric.
(:wat::core::define
  (:trading::treasury::Treasury::active-paper-count
    (t :trading::treasury::Treasury)
    -> :wat::core::i64)
  (:wat::core::foldl
    (:wat::core::values (:trading::treasury::Treasury/papers t))
    0
    (:wat::core::lambda
      ((acc :wat::core::i64) (paper :trading::treasury::Paper) -> :wat::core::i64)
      (:wat::core::match (:trading::treasury::Paper/state paper) -> :wat::core::i64
        (:trading::treasury::PositionState::Active (:wat::core::+ acc 1))
        (_ acc)))))
