# Review: Rich Hickey

Verdict: CONDITIONAL

---

## What hangs straight

The decomposition of the problem is correct. The proposal identifies that the cache is doing two things — memoization and sharing — and proposes to separate them. Memoization is local. Sharing requires coordination. Putting local memoization behind a pipe is complecting "do I already know this?" with "does anyone else know this?" Those are different questions with different coordination costs. Separating them is the right move.

The L1 is a HashMap. Good. Not a "local cache framework." Not an "entity-scoped memoization layer." A HashMap. The simplest possible thing that does the job. It lives on the entity's thread. It needs no lock, no channel, no driver. The entity puts a thing in, the entity gets a thing out. A place, yes — but a thread-local place with no sharing, which means no coordination, which means no complecting.

The encode flow is well-sequenced: check L1 (instant), batch L1 misses to L2 (one round-trip), compute remaining misses (parallel), install results into both layers. Four phases. Each does one thing. Each produces values consumed by the next. No interleaving. No callbacks. No "check L2 while computing." The data flows in one direction through the pipeline. That's simple.

The algebraic invariant is preserved. The six primitives don't change. The ThoughtAST doesn't change. The encoding produces the same vectors. L1 and L2 are deployment concerns, not algebraic ones. The proposal is clear about this, and it matters — too many "performance" proposals smuggle semantic changes through the implementation door.

## What's complected

**The rayon proposal complects the cache problem with the parallelism problem.** The proposal correctly identifies two bottlenecks: pipe latency (95% of encode time) and idle cores. L1 solves the first. Rayon solves the second. These are independent changes with independent risks. The proposal binds them into one proposal. Ship L1 alone. Measure. If the cores are still idle after L1 drops L2 traffic by 20x, *then* you have evidence that parallel compute matters. Right now, you're solving the second problem before you've measured the effect of solving the first.

This isn't a small point. After L1, the L2 sees 1,584 lookups instead of 31,680. The driver thread goes from 100% CPU to potentially 5% CPU. The pipe latency per round-trip drops because the pipe is nearly empty. The 33 entity threads may no longer be blocked at all. You might find the system is fast enough without rayon. You might find the bottleneck moves somewhere you didn't predict. You won't know until you measure. The proposal assumes the bottleneck survives L1. That assumption should be tested, not assumed.

**The L1 memory estimate is imprecise and the parameters are dangling.** 33 entities times 8K entries times "~10KB" equals 2.6GB. But what is 10KB? A `Vector` at 4096 dimensions of `i8` is 4KB. The `ThoughtAST` key is a tree of `Arc`s — its size depends on depth, which varies per entity. "~10KB" is a guess wearing the clothes of a measurement. And 8K entries is a parameter without a derivation. The proposal says the working set is ~1300 nodes per encode. If the hot set is 1300 and it repeats across candles with drift, then 4K entries gives you 3 candles of runway. 8K gives you 6. 16K gives you 12. Which one matters? The proposal doesn't say because it hasn't measured the reuse distance. The right answer: start with the smallest power-of-two that exceeds the working set (2048), instrument hit rate, and let the measurement decide.

**The rayon scope has a hidden dependency on the AST's shape.** The proposal says "a Bundle with 20 unknown children spawns 20 tasks." But ThoughtAST children share subtrees via `Arc`. If child 3 and child 7 share a sub-expression (same indicator at different depth), two rayon tasks will compute the same subtree independently. Neither checks L1 during compute — the proposal explicitly says "no cache, just math." This means rayon tasks can duplicate work that L1 would have prevented if the tasks had access to it. The "fully independent" purity is clean, but it might cost more than the coordination it avoids. The proposal should acknowledge this tradeoff explicitly.

## The questions, answered

**1. L1-per-entity or shared L1?** Per-entity is correct. The moment you share L1, you need coordination, and you've rebuilt the L2. The whole point of L1 is that it's unshared. If brokers and market observers share indicator rhythm subtrees, that sharing is the L2's job. Don't merge the layers.

**2. Rayon global pool vs per-entity pools?** Global pool. Per-entity pools would create 33 thread pools on a machine with 8-16 cores. That's not parallelism, that's contention wearing a concurrency costume. Rayon's global pool is work-stealing across all cores. One pool. The tasks find the cores. This question answers itself.

**3. LRU eviction?** LRU is fine for this access pattern. The entity re-visits recent subtrees and forgets old ones as the window slides. LRU matches this naturally. Don't overthink it.

**4. Should rayon tasks read L1?** This is the real question, and the proposal punts on it. If tasks are fully independent, they duplicate shared subtree work. If tasks can read L1, they need `&HashMap` access during parallel execution, which Rust allows for shared references but means L1 must be populated before the rayon scope and cannot be written during it. The right answer: populate L1 from L2 results *before* entering the rayon scope. Inside the scope, tasks take `&HashMap` (read-only) and return `Vec<(ThoughtAST, Vector)>` (values up). After the scope, install all returned results into L1. Read-only sharing during compute, write after compute. Values up, not places down.

**5. L1 size?** Measure, don't guess. See above.

## The condition

Ship L1 alone. No rayon. Measure the throughput, the L2 traffic reduction, the entity thread utilization, the driver CPU. If the system is fast enough, stop. If the cores are still idle and the bottleneck is confirmed to be compute (not pipe, not L2, not something new), then bring rayon in a second proposal with the measured evidence. Two changes, two measurements, two decisions. Not one change that solves two problems and measures neither independently.
