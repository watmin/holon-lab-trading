# Review: Proposal 016 — Adaptive Buckets
**Reviewer:** Rich Hickey
**Verdict:** No. Keep fixed K. The data says so.

## The questions

**1. Is one split threshold simpler than fixed K + range?**

No. It is easier to explain, but it is not simpler. Fixed K + range are two
values with known behavior: K controls resolution, range bounds the domain.
The split threshold is one value with emergent behavior — it controls K
indirectly through a variance heuristic that interacts with data distribution,
observation count, and time. You removed two knobs and added a dynamical system.
A dynamical system with one parameter is not simpler than two parameters with
known semantics. It is more complex with fewer controls.

**2. Should K be capped or grow forever?**

The question answers itself. K does not stabilize. That means the cost function
is unbounded in time. "The CSP scheduling will handle it" is deferring a
structural decision to an operational mechanism. You would be building a system
whose query cost you cannot predict from its configuration. That is the
definition of incidental complexity — complexity that does not serve the problem.

**3. Is 0.09% error acceptable to eliminate two parameters?**

The parameters you are eliminating are not burdensome. The range is known — the
proposal itself says the output is bounded. K=10 was measured at the knee of
the error curve. These are not magic numbers discovered by grid search. They
are structural properties of the domain: the output range is a fact, and K=10
is the empirical resolution of that range. Eliminating facts is not simplification.
It is willful ignorance.

The adaptive reckoner at its best (K=17, min_split=150) is 9% worse in error
and 2× slower than fixed K=10. It arrives at a worse answer through a more
complex mechanism. The only thing it eliminates is the need to state what you
already know.

**4. Is the discrete/continuous asymmetry a problem?**

No. Discrete has fixed K because categories do not split. Continuous has fixed K
because the output range is bounded and the resolution was measured. Different
domains, same property: the structure is known. The asymmetry would be a problem
if one grew and the other did not — that would mean they obey different laws.
Keep them both fixed and they obey the same law: K is a property of the output
space, not the input stream.

## Verdict

**Keep fixed K=10. Do not implement adaptive buckets.**

The experiment was worth running. It proved that the data can discover structure.
That is a real finding. But "can" is not "should." The adaptive reckoner
trades known behavior for emergent behavior, pays 2× in latency, and gets
worse accuracy. The fixed reckoner is a value. The adaptive reckoner is a process.
When a value suffices, do not substitute a process.

I reversed my position on D vs B because the data showed D was categorically
wrong. The data here shows fixed K is categorically right. The adaptive version
is a solution to a problem you do not have.
