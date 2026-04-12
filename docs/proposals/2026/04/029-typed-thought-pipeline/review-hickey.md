# Review: Proposal 029 — Rich Hickey

**Verdict:** ACCEPTED

## Assessment

This proposal corrects a real bug — the 6x extraction scope — and the
correction reveals the right shape. That's how you know a fix is
honest: it simplifies.

The communication type is right. `(ThoughtAST, Vector)` is a value.
It has no behavior. It doesn't know who holds it or what they'll do
with it. The consumer decides. This is the property that makes
composition possible. You cannot compose things that know too much
about each other. The proposal found this accidentally by fixing a
bug, which is the best way to find the right shape — not by designing
it up front.

The `extract` primitive is now simple. A flat batch of cosines against
a frozen vector. The hierarchy from proposal 028 was a premature
optimization of a problem that didn't exist yet. Hierarchical descent
to find the "right level" of composition is a clever solution to a
question nobody asked. Who told us the consumer wants compositions?
The consumer has the AST. If the consumer wants compositions, they can
construct them. The extraction's job is to measure. Give me the
leaves. Give me honest numbers. Let the consumer decide what to do
with them. Proposal 029 gets this right.

The typed thought structs are the most important part of this proposal,
and they're almost buried. A `MomentumThought` is not a `RegimeThought`.
These are different things. Today the type system permits you to lie
about that. The compiler lets you pipe one where the other is expected.
That's the 600-atom bug in a nutshell — the wrong thing passed where
the right thing was expected, and nobody caught it until the run. Typed
structs make this category of mistake impossible. The compiler becomes
a proofreader. This is what types are for: encoding true distinctions
so the machine can enforce them.

The pipeline shape — each stage produces `(ThoughtAST, Vector)`, each
consumer receives the prior stage's pair — is a correct linearization
of dependencies. No shared state. No broadcast. No implicit coupling.
The market observer doesn't know the exit exists. The exit doesn't know
the broker exists. Each stage sees its inputs and produces its outputs.
Values up.

The scoping fix is the real deliverable. N×M exit encodings instead of
M. More compute. But the prior approach was wrong — it was claiming to
do per-observer composition while actually doing per-type composition.
Honesty costs. Pay it.

## Concerns

**The `ToAst` trait carries two concerns.** `to_ast()` and `forms()`
are not the same operation. `to_ast()` encodes this instance — the
values matter. `forms()` produces query templates — the values don't
matter, only the structure does. These are different things in one
interface. Consider separating them. The encoding trait says "turn me
into geometry." The query trait says "here are the forms I know how to
ask about." One trait doing both is a small complecting. Not fatal. But
watch it.

**The exit's noise subspace question is deferred but not answered.**
Question 2 in the proposal notices the exit is the only stage without
noise stripping. That's not a coincidence to wave at. If the exit
accumulates a noise subspace, it strips the background from its own
encoded thought before passing it to the broker. The broker then
extracts from a noise-stripped exit vector. If the exit doesn't have a
noise subspace, the broker extracts from raw encoding. These are
different semantics. The proposal correctly surfaces this question but
leaves it hanging. The answer shapes what the broker receives. Resolve
it before implementing the broker's extraction path.

**`forms()` coupling.** The proposal says "the consumer calls
`extract(anomaly, thought.forms(), encoder)` to query all of them. Or
the consumer filters `forms()` first." The second path is fine — filter
then query. But passing the full `forms()` to extract and then
filtering the output is wasteful. If you're going to filter, filter
before encoding. The cache helps but you're still encoding forms you
don't use. This is a performance concern, not a correctness concern. The
interface is still right. Note it and move on.

**The `ToAst` forms vocabulary must be stable.** The `forms()` method
defines what a consumer can ask about. If the vocabulary evolves —
you add `close_sma100` to `MomentumThought` next week — the forms
change. Consumers that learned on the old forms are now asking about
different vectors. The reckoner's accumulated experience was built on
one set of queries. You changed the queries. The accumulated experience
is now incorrect. This is a semantic versioning problem dressed as a
struct field addition. Know that you're carrying this. Don't let it
accumulate silently.

## On the questions

**Question 1: Should we implement extract + scoping first and defer
typed structs?**

No. Do not defer typed structs. The scoping fix without typed structs
is a bug fix that leaves the next bug in place. The next person will
pipe the wrong observer's output somewhere and you won't find out until
a run. The structs are what make the scoping fix stick. They're what
make the compiler witness that this exit takes this market, not any
market. The refactor is large. Do it anyway. The fear of a large
refactor is not a reason to leave the system in a state where it can
lie to you.

**Question 2: Should the exit have its own noise subspace?**

Yes. Eventually. Not immediately. But the principle is: every observer
that produces a `(ThoughtAST, Vector)` pair for downstream consumption
should strip its own noise before passing the vector. The vector is the
message. Passing unstripped noise as a message is passing garbage. The
exit's consumer — the broker — deserves to receive a noise-stripped
signal from the exit just as much as the exit deserves a noise-stripped
signal from the market. The symmetry is the answer. Implement it when
the exit has enough history to build a meaningful subspace.

**Question 3: Should the broker also receive the exit's `(ast, anomaly)`
pair so it can extract from both stages independently?**

Yes. The broker's job is accountability. It binds one market observer
to one exit observer. It can only do that job honestly if it sees
both. If the broker receives only the composed exit vector — which
already absorbed market context — then the broker cannot distinguish
"the market said X, the exit agreed" from "the exit independently
concluded X without market input." Those are different situations.
The broker should receive both pairs. Let the broker decide what to
extract and from whom. The consumer's freedom applies to the broker
too.
