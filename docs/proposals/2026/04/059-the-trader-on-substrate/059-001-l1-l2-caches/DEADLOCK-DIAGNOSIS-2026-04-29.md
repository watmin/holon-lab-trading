# proof_004 — circuit trace (RESOLVED 2026-04-29)

## Symptom
Test hung with NO CPU — three threads all blocked. Looked like a
classic deadlock cycle.

## Real cause (NOT a deadlock)
The lab's reporter (`wat/cache/reporter.wat`) called
`(:wat::holon::Atom stats)` — but `:wat::holon::Atom` does not
accept Struct values. When the cadence fired (every 10 requests),
the cache thread T2 panicked on this line.

## Why it manifested as a HANG instead of a clear panic
1. T2 panics. Cache loop dies. cache-req-tx channel disconnects.
2. T0's subsequent `(:wat::kernel::send cache-req-tx ...)` returns
   `:None` (Option<()>) — silently. The lab's drive-requests
   binds it to `_ :wat::kernel::Sent` and discards.
3. T0 continues to the FIRST Get (i=20). Sends Request::Get(k,
   reply-tx) — returns `:None`. The reply-tx is NOT moved into
   the channel (the send failed). reply-tx remains alive in T0's
   inner scope binding.
4. T0 then `(:wat::kernel::recv reply-rx)`. Because T0 still holds
   reply-tx in its own scope, the reply channel has a live Sender.
   The channel does NOT disconnect. recv blocks forever.
5. The foldl never completes. `_cache-join` is never reached. The
   panic from T2 sits unread in the cache-driver's outcome
   channel. The test hangs.

The user's intuition was exactly right: "a let binding problem
where a close signal can't propagate." The let-bound reply-tx
in drive-requests' caller kept the reply channel alive past the
moment T2 died.

## Stepping stones that diagnosed it

Wrote 5 stepping stones in the same directory. Each is an
independent deftest, smallest-thing-first:

| Step | Composition | Result |
|------|-------------|--------|
| A | rundb only — spawn, batch-log, join | ✅ 50ms |
| B | cache only with null-reporter | ✅ 10ms |
| C | both, no closure between them | ✅ 50ms |
| D | reporter closes over rundb but cadence never fires | ✅ 45ms |
| E | reporter fires on first tick (1 Put → 1 fire) | ❌ panic surfaced — `:wat::holon::Atom: ...got Struct` |

E's failure was a clean error (no hang) because in E the foldl is
length 1, completes immediately, and `_cache-join` propagates the
panic from T2 to T0.

The full proof_004 has length-30 foldl with Gets after Puts — the
hang surfaces only there. E gave us the panic message; that
panic message gave us the line; that line gave us the fix.

## Fix
`holon-lab-trading/wat/cache/reporter.wat`:

```scheme
;; before — broken: Atom doesn't accept Struct
((data-ast :wat::holon::HolonAST) (:wat::holon::Atom stats))

;; after — correct: struct->form + from-watast (arc 091 slice 8 / arc 093 slice 3)
((stats-form :wat::WatAST) (:wat::core::struct->form stats))
((data-ast :wat::holon::HolonAST) (:wat::holon::from-watast stats-form))
```

## Verification
```
running 6 tests
test 004-cache-telemetry.wat                  ... ok (62ms)
test 004-step-A-rundb-alone.wat               ... ok (51ms)
test 004-step-B-cache-alone.wat               ... ok (8ms)
test 004-step-C-both-null-reporter.wat        ... ok (46ms)
test 004-step-D-reporter-never-fires.wat      ... ok (44ms)
test 004-step-E-reporter-fires-once.wat       ... ok (50ms)
test result: ok. 6 passed; 0 failed; finished in 330ms
```

DB content (proof-004-{epoch}.db, log table) — 3 rows:
```
:trading.cache|:cache.reporter|:info|Stats/new 0  0  0  10 10  ;; after 10 Puts
:trading.cache|:cache.reporter|:info|Stats/new 0  0  0  10 20  ;; after 20 Puts
:trading.cache|:cache.reporter|:info|Stats/new 10 10 0  0  20  ;; after 10 Gets
```

Stats fields (lookups, hits, misses, puts, cache-size) — matches
the workload exactly.

## Substrate-side observation (future work)

When a `:wat::kernel::send` returns `:None` (channel disconnected),
the test's `:wat::kernel::Sent` binding silently absorbs it.
If callers don't check, they keep going on a dead service. That's
why this surfaced as HANG instead of error.

Two possible future improvements (not done in this session):
1. Provide a `send!` variant that errors on disconnect (rather than
   returning Option<()>).
2. Make the lab's drive-requests check the Sent and exit on :None.

Neither is necessary for the proof to prove. The reporter fix is
the actual cause; the cascade is downstream.

## Discipline that worked

The user's framing: "we do not one shot.. we iterate, prove our
stepping stones as we walk to the solution." Five stepping stones
in 200 lines of new wat. Each named what it proved. The first one
that failed pinpointed the exact line — no mental tracing of three
threads' Arc<Sender> ownership needed.
