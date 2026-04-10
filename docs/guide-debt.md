# Guide Debt

Changes made to the wat and Rust that the guide doesn't know about yet.
These accumulate during debugging. When the guide absorbs them, they
are removed from this list. The order IS the discovery order.

## From the tenth inscription debugging session

1. **brokers table in ledger** — the binary registers a `brokers` table
   mapping slot_idx to (market_lens, exit_lens). The wat/bin/enterprise.wat
   was updated. The guide's Binary section doesn't mention this table.
   The guide says "meta table" and "log table" — it needs "brokers table."

2. **pmap → par_iter** — the wat uses `pmap` in post.wat lines 82 and 149.
   The guide says `par_iter` in the Performance section and step descriptions.
   The Rust currently uses sequential `.iter()`. When the Rust is fixed to
   use `rayon::par_iter`, the guide is already correct — but the inscribe
   spell was honed to enforce this. Track: the Rust fix is pending.

---

3. **Pipe architecture (Proposal 010)** — the enterprise decomposes into
   pipes connected by bounded(1) channels. Observer threads encode in
   parallel. Learn channels (unbounded) propagate back. The guide's
   Binary section needs the pipe wiring. The guide's Performance section
   needs the throughput journey (2/s → 5/s with learning, 104/s without).
   The four-step loop description needs to reflect that steps run on
   different threads connected by channels.

4. **Propagation bottleneck** — propagation is the cost of learning.
   ~40 resolutions/candle × 10000D × 3 recipients. The full CSP needs
   broker threads. The guide doesn't describe this yet.

5. **`ctx_scalar_encoder_placeholder`** — a static OnceLock invented by
   the inscribe agent. The wat never specified it. The guide doesn't
   mention it. The propagation path needs the scalar encoder from ctx,
   threaded through the call chain. Values, not statics.

6. **Exit observer distances not flowing to broker threads** — the N×M
   grid computes exit encoding on the main thread (rayon) but uses
   hardcoded default distances (0.015, 0.030) because the broker threads
   don't have access to exit observers for recommended_distances. The
   fix: compute recommended_distances on the main thread (it already has
   exit observer access) and include them in the BrokerInput message.

7. **Summary display broken** — observers and brokers are moved to
   threads. The post's registry and market_observers vecs are empty after
   thread spawn. The summary reads empty data. Fix: join threads at
   shutdown, restore observers and brokers to the post, then display.

8. **Learn-first ordering** — the guide doesn't specify that propagation
   signals must be drained BEFORE encoding the next candle. The pipe
   architecture discovered this: drain learn queue, then encode, then
   send. The learning must precede the prediction.

9. **No magic index — iterate posts** — the binary hardcodes `posts[0]`
   26 times. Not `pi = 0`. ITERATE. The outer loop routes candles to
   the right post by asset pair. Each post has its own observer threads,
   broker threads, channels. The treasury is shared. The binary never
   knows how many posts exist. It iterates.

10. **N candle streams** — future. One stream per asset pair. Each pair
    has its own data source (parquet or websocket). The outer loop
    merges N streams into one ordered fold. Each candle carries its
    pair identity. The routing IS the stream. Prepare for this but
    do not build it yet.

11. **Step 1 (settle) and Step 3c (update triggers) missing from binary**
    — the ignorant found these. The four-step loop is incomplete in the
    threaded binary. Step 1 never settles trades. Step 3c never updates
    stop levels. The stops don't breathe. Real trades can't complete.

*When the debugging session produces enough findings, batch-update the
guide. The guide absorbs what the compiler taught it. f(guide, compiler) = guide.*
