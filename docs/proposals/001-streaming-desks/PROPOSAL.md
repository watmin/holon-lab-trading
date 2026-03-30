# Proposal 006: Streaming Desks — Multi-Asset Enterprise

Status: **DRAFT**

Scope: **userland** — uses existing primitives. No new language forms.

---

## 1. The Current State

The enterprise is a fold over a stream of candles (Proposal 002 accepted). One asset pair: BTC/USDC. One candle stream from SQLite. The heartbeat processes one candle at a time — experts encode, manager decides, treasury executes.

The treasury is already token-agnostic. It holds a `balances` map of arbitrary assets. It has `swap(from, to, amount, price, fee_rate)`. It has `price_map` and `total_value` that work for any number of assets. The treasury does not know what BTC is. It knows what it holds.

The enterprise has one stream, one set of observers, one manager, one risk branch. Everything assumes one pair.

## 2. The Problem

**2a. One pair is a special case.** BTC/USDC has one candle stream because USDC is a stablecoin pegged to 1.0. There is no USDC candle stream — its price never moves. Every other pair needs two streams. BTC/SOL needs BTC candles AND SOL candles. The enterprise cannot express this today.

**2b. The fold consumes one event type.** The heartbeat takes one candle per tick. A multi-asset enterprise receives candles from multiple assets at different timestamps. BTC candle at 12:00, SOL candle at 12:01, ETH candle at 12:03. The fold must process a merged stream where each event is tagged with its asset.

**2c. Desks are not yet values.** The current enterprise hardcodes the observers, manager, risk, and treasury calls in the heartbeat. Each desk — the unit that trades one asset pair — should be a value with its own observers, manager, risk branch, and tick method. The heartbeat becomes: for each desk, if it has fresh data, tick it.

**2d. Mixed-era data.** If BTC data starts in 2019 and SOL data starts in 2021, the merged stream has two years of BTC-only events before SOL arrives. A desk trading BTC/SOL cannot act during those years — one of its streams has no data. The desk must know when its data is stale.

**2e. Capital arrives over time.** The enterprise starts with an initial balance. But in reality, capital arrives — monthly deposits, profits from other systems, rebalancing from other portfolios. The event stream must carry deposits alongside candles.

## 3. The Proposed Design

### 3a. The Event Sum Type

The merged stream carries tagged events:

```scheme
;; The enterprise folds over a stream of these
(match event
  (Candle asset candle)     ;; a price candle for one asset
  (Deposit asset amount)    ;; capital injection
  (Withdraw asset amount))  ;; capital removal
```

Every event is tagged with its asset. The fold dispatches by event type and asset tag.

### 3b. The Desk as a Value

A desk trades one pair. It has two sides: the asset it is trading and the asset it is pricing against. Each side has a latest-candle slot.

```scheme
(define (make-desk name asset quote-asset dims recalib-interval staleness-limit)
  "A desk trades one pair. It has its own observers, manager, risk.
   It ticks only when both sides have fresh data."
  (let ((observers  (make-observers name dims recalib-interval))
        (manager    (make-manager name dims recalib-interval))
        (risk       (make-risk-branch dims))
        (latest     { :asset nil  :quote nil })   ;; latest candle per side
        (last-tick  { :asset 0    :quote 0 }))    ;; timestamp of last candle per side
    { :name            name
      :asset           asset
      :quote-asset     quote-asset
      :observers       observers
      :manager         manager
      :risk            risk
      :latest          latest
      :last-tick       last-tick
      :staleness-limit staleness-limit }))
```

### 3c. Desk Receives and Checks Freshness

When a candle event arrives, the enterprise routes it to every desk that cares about that asset. The desk updates its latest slot. Then it checks: do I have fresh data on both sides?

```scheme
(define (desk-receive desk asset candle)
  "Update the desk's latest candle for one side."
  (cond
    ((= asset (asset desk))       (set-latest desk :asset candle))
    ((= asset (quote-asset desk)) (set-latest desk :quote candle))
    (else desk)))  ;; not my asset, ignore

(define (desk-ready? desk current-time)
  "Both sides have data. Neither is stale."
  (and (some? (latest desk :asset))
       (some? (latest desk :quote))
       (< (- current-time (last-tick desk :asset))  (staleness-limit desk))
       (< (- current-time (last-tick desk :quote))  (staleness-limit desk))))
```

The staleness limit is a configuration per desk. For 5-minute candles, a reasonable limit is one candle duration (300 seconds). If one side's latest candle is older than that, the desk bounces.

A stablecoin pair (BTC/USDC) has a degenerate case: the quote side is always "fresh" because its price is constant. The desk receives a synthetic candle for USDC at every BTC tick — price 1.0, volume 0. Or the staleness check for the quote side is disabled when the quote asset is the base asset. Either works.

### 3d. The Heartbeat Becomes a Dispatch

```scheme
(define (heartbeat state event)
  "The enterprise fold. One event at a time. Dispatch by type and asset."
  (match event
    (Candle asset candle)
      (let* (;; Update price map for treasury valuation
             (state (update-price state asset (close candle)))
             ;; Route candle to all desks that trade this asset
             (state (fold (lambda (s desk)
                           (let* ((desk (desk-receive desk asset candle))
                                  (desk (if (desk-ready? desk (ts candle))
                                            (desk-tick desk (treasury state))
                                            desk)))
                             (update-desk s desk)))
                         state
                         (desks state))))
        state)

    (Deposit asset amount)
      (deposit (treasury state) asset amount)

    (Withdraw asset amount)
      (withdraw (treasury state) asset amount)))
```

The heartbeat no longer knows about observers, managers, or risk. It knows about desks and treasury. Each desk is a self-contained unit that ticks when ready.

### 3e. Desk Tick

Inside the desk tick, the existing seven-layer architecture lives unchanged:

```scheme
(define (desk-tick desk treasury)
  "The desk heartbeat. Same layers as before, scoped to one pair."
  (let* ((asset-candle (latest desk :asset))
         (quote-candle (latest desk :quote))
         (price        (/ (close asset-candle) (close quote-candle)))

         ;; Layer 1: Experts encode and predict
         (expert-preds (map (lambda (e) (e (candles desk) (vm desk)))
                            (observers desk)))

         ;; Layer 2: Manager reads opinions
         (mgr-pred     ((manager desk) expert-preds price))

         ;; Layer 3: Risk assesses desk health
         (risk-mult    ((risk desk) treasury (positions desk) expert-preds))

         ;; Layer 4: Treasury executes (shared across desks)
         (_            (desk-execute desk treasury mgr-pred risk-mult price))

         ;; Layer 5: Manage positions
         (_            (manage-positions (positions desk) treasury price))

         ;; Layer 6: Learn from outcomes
         (_            (learn-desk desk price)))
    desk))
```

The desk computes its own pair price from the two candles. The treasury is shared — all desks draw from and return to the same pool.

### 3f. Stream Merging

The merged stream is sorted by timestamp across all asset feeds:

```
BTC 12:00:00  ←  fold processes this
SOL 12:00:03  ←  fold processes this
ETH 12:00:07  ←  fold processes this
BTC 12:05:00  ←  fold processes this
Deposit USDC 1000.0  ←  monthly deposit arrives
SOL 12:05:01  ←  fold processes this
...
```

The merge is the stream source's concern, not the enterprise's. SQLite: `ORDER BY timestamp`. Websocket: priority queue by arrival time. The enterprise sees one stream of events.

### 3g. Treasury Valuation

The treasury maintains a price map updated by every candle event. Valuation is always current:

```scheme
(define (update-price state asset price)
  "Every candle updates the price map. Treasury reads it for valuation."
  (set-price-map state asset price))

(define (total-value treasury price-map)
  "Sum of (balance + deployed) × price for every asset."
  (fold (lambda (total asset)
          (+ total (* (total-holding treasury asset)
                      (price-of price-map asset))))
        0.0
        (assets treasury)))
```

No separate valuation feeds. The candle stream IS the price feed.

### 3h. Capital Events

Deposits and withdrawals are events in the stream, processed by the fold like any other event:

```scheme
(Deposit "USDC" 1000.0)   ;; monthly DCA arrives
(Withdraw "USDC" 500.0)   ;; take profits
```

The treasury handles these atomically. Desks are unaware — they see the treasury balance change on their next tick.

## 4. The Algebraic Question

**Does this compose with the existing monoid (bundle/bind)?**

Yes. Each desk uses the same vector algebra as the current enterprise. Observers bind role-filler pairs. Managers bundle expert opinions. Nothing changes inside the desk. The desk IS the current enterprise, scoped to one pair.

**Does the merged stream compose with fold?**

The enterprise remains `(fold heartbeat initial-state events)`. The stream type changes from `Candle` to `Event` (a sum type). The fold function dispatches by tag. This is standard — fold does not constrain the event type.

**Does this compose with the state monad (journal)?**

Each desk has its own journals. Desk A's observers do not share journals with Desk B's observers. The journals are scoped to the desk value. The manager journal within each desk learns from that desk's pair, not from the whole enterprise.

**Does this introduce a new algebraic structure?**

No. The desk is a product type (a record of existing types). The event is a sum type (tagged union of existing types). Both are standard. The staleness check is a predicate, not an algebraic operation. The merged stream is a sorted interleaving, not a new combinator.

## 5. The Simplicity Question

**Is this simple or easy?**

Simple. The desk is a value — it has no lifecycle, no channels, no callbacks. It receives data, checks readiness, ticks or waits. The merged stream is a sorted list. The fold processes one event at a time. No concurrency, no synchronization, no async.

**What is being complected?**

Nothing new. The desk bundles the same things the enterprise already bundles (observers + manager + risk), but scopes them to a pair. The staleness check adds one predicate. The event sum type adds one dispatch.

The alternative — multiple enterprise folds running in parallel with message passing — would complect significantly. Channels, synchronization, shared treasury access. The designers already rejected async in Proposal 001's review. This proposal stays within the sequential fold.

**Could existing primitives solve it?**

Yes. That is the point. The six primitives are unchanged. `fold` (accepted in Proposal 002) is the driver. Desks use `atom`, `bind`, `bundle`, `cosine`, `journal`, `curve` exactly as before. The only new thing is the event sum type and the desk record — both are data, not computation.

## 6. Questions for Designers

1. **Is the stablecoin degenerate case clean enough?** A BTC/USDC desk needs only one real stream. Two options: (a) inject synthetic candles for USDC at every BTC tick, keeping the "two streams" invariant uniform. (b) Allow the quote side staleness check to be disabled when the quote is the base asset. Option (a) is uniform but wasteful. Option (b) is a special case but honest. Which is simpler?

2. **Should desks share a cross-desk manager?** The current proposal gives each desk its own manager. But a cross-desk manager could learn correlations — "when BTC desk is bullish and SOL desk is bearish, reduce SOL sizing." This is the multi-asset allocation question. Should it be in this proposal or deferred?

3. **Is staleness the right word for mixed-era streams?** When BTC data starts in 2019 and SOL starts in 2021, the SOL stream is not "stale" — it has not begun. The desk is not bouncing a late update; it is waiting for data that does not yet exist. Should the desk distinguish "no data yet" from "data arrived but is old"? Or is the staleness predicate sufficient for both cases (nil latest = infinite staleness)?

4. **How should the enterprise allocate capital across desks?** The treasury is shared. If BTC/USDC desk and ETH/USDC desk both want to deploy at the same tick, who gets priority? Options: (a) first desk in the list wins. (b) desks request, enterprise allocates proportionally. (c) each desk has a capital budget. This is the cross-asset manager question — it may belong in a follow-up proposal.

5. **Should the price map live in the treasury or in the enterprise state?** The treasury already has `price_map` and `total_value`. But the price map is updated by candle events, which the treasury does not see — the heartbeat updates it. Should the price map be part of the enterprise state passed to the treasury, or should the treasury own it and receive price updates directly?
