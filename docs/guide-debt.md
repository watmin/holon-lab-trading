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

*When the debugging session produces enough findings, batch-update the
guide. The guide absorbs what the compiler taught it. f(guide, compiler) = guide.*
