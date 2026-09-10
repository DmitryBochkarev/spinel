# `Thread` in Spinel

Spinel runs Ruby `Thread`s as **true parallelism with no GVL**. A threaded
program is scheduled onto `N` OS workers that run green threads over a
stop-the-world garbage collector, so CPU-bound threads make progress on
separate cores at the same time. This is the JRuby / TruffleRuby model, not
CRuby's: individual operations are **not** made atomic by a global lock.

This document describes what you can rely on when you use threads, which of the
`Thread` API is supported, and the semantics that differ from CRuby. The
implementation (the M:N scheduler, per-worker run queues, work stealing, the
preemption monitor) is a separate concern and lives in
[internals/thread-mn-design.md](internals/thread-mn-design.md) — nothing there
is a user guarantee.

## The execution model

- **N OS workers.** Worker count is `min(online cores, SPINEL_WORKERS)`.
  Set `SPINEL_WORKERS=1` to force the single-worker cooperative model, or a
  fixed number to cap parallelism. Absent the env var, Spinel autodetects the
  number of online cores.
- **Real parallelism, no GVL.** Two threads run Ruby code on two cores
  simultaneously. There is no implicit per-object lock, so unsynchronized
  shared mutation is a data race (see [By design](#by-design) below).
- **Green threads over a stop-the-world GC.** A `Thread` is a green thread; the
  workers multiplex many green threads onto few OS threads. A garbage
  collection stops all workers at a safepoint, so allocation stays correct
  under parallelism without per-object write barriers.
- **Preemption.** A monitor thread timeslices CPU-bound threads (~10 ms
  quantum) so a thread that loops without yielding cannot starve its siblings.
  Preemption is taken at **safepoint polls** (loop back-edges): a thread that
  spends a long time inside a single runtime call with no poll yields only when
  that call returns. The preemption signal is `SIGURG`, overridable with
  `SPINEL_PREEMPT_SIGNAL`.
- **The single-threaded archive is unchanged.** A program that never uses
  `Thread` compiles and runs byte-identically to before; none of the scheduler
  machinery is linked in.

## Supported API

### `Thread`

| method | notes |
|---|---|
| `Thread.new(*args) { \|*args\| ... }` | spawn; args become the block parameters |
| `#join` | block until finished, re-raising an unhandled exception in the caller |
| `#value` | `#join` plus the block's result |
| `#kill` / `#exit` / `#terminate` | terminate the thread |
| `#raise(...)` | raise an exception in the thread |
| `Thread.pass` | cooperative yield |
| `Thread.current` / `Thread.main` | the running / initial thread |
| `Thread.list` | live threads |
| `#alive?` / `#status` | `"run"` / `"sleep"` / `false` / `nil` |
| `#name` / `#name=` | a string or nil |
| `Thread#[]` / `#[]=` / `#key?` | fiber-local / thread-local storage by symbol |
| `Thread.report_on_exception` / `=` and the per-thread accessors | unhandled-exception reporting |

`Kernel#sleep` and blocking I/O are **scheduler-aware**: a sleeping or
I/O-blocked thread frees its OS worker for other green threads instead of
holding it idle, and the monitor wakes it when the deadline passes or the fd
becomes ready. A *timed* readiness wait on one IO -- `IO#wait_readable(t)`,
`IO#wait_writable(t)`, `IO.select([io], nil, nil, t)` -- parks the same way,
and wakes on whichever of the fd or the deadline comes first. `IO.select`
over several IOs still runs on `select(2)` and holds its worker for the
duration.

### Synchronization primitives

Real, blocking primitives — not busy-waits:

| type | methods |
|---|---|
| `Mutex` | `#lock` / `#unlock` / `#try_lock` / `#locked?` / `#owned?` (non-recursive) |
| `Queue` | `#push` / `#<<` / `#pop` / `#size` / `#empty?` / `#close` / `#closed?` / `#clear` (`#pop` blocks when empty) |
| `SizedQueue` | `Queue` plus `#max`; `#push` blocks when full |
| `ConditionVariable` | `#wait(mutex)` / `#signal` / `#broadcast` |

## By design

These are deliberate consequences of real parallelism, listed in
[limitations.md](limitations.md#by-design-deliberate-choices):

- **Data races are observable.** Two threads mutating the same
  `Array`/`Hash`/object without a `Mutex` race, similar to `Array`/`Hash` in
  JRuby and `Array` in TruffleRuby. CRuby's GVL makes individual operations
  appear atomic; Spinel does not, and adds no implicit per-object locking.
  Correctness across threads is the program's responsibility via
  `Mutex` / `Queue` / `ConditionVariable`.

  What "race" means here is worth stating rather than leaving as *undefined*,
  because the kinds of state differ (#4166):

  - **Objects never lose an ivar.** Every instance variable is a field of a
    generated C struct, fixed when the program is compiled: an object's ivar
    set cannot grow at run time, and `instance_variable_set` takes a literal
    symbol only (a name decided at run time raises NoMethodError). So two
    threads assigning two different ivars cannot lose either, and no ivar
    write can be lost to a write of a *different* ivar.
  - **A word-sized ivar never tears.** A racing read of an Integer, Float,
    String, or object-reference ivar answers a value some thread wrote --
    never one nobody wrote, and never a half-written pointer. Which write it
    sees is unordered, and a read may be stale.
  - **A multi-word ivar can tear.** `Range`, `Time`, `Complex` and `Rational`
    ivars are stored by value and copied field by field, so a racing read can
    see one field from one write and another field from another: a `Range`
    ivar written concurrently reads back with `first` and `last` from
    different assignments.
  - **Containers can crash the process.** `Array` and `Hash` have no such
    guarantee. Concurrent `<<` on one Array reaches the growth path, where a
    reallocation races with another thread's element store, and the observed
    outcomes are silently dropped elements, a heap-corruption abort, and
    SIGSEGV. A shared container needs a `Mutex`, or a `Queue`, which is
    itself thread-safe.
- **Interleaving is nondeterministic.** The ordering of `Thread.pass`,
  `Thread.list` membership, and the exact moment a `Thread#raise` / `#kill` is
  delivered are nondeterministic, where the single-worker model was
  deterministic.

## Environment variables

| variable | effect |
|---|---|
| `SPINEL_WORKERS` | number of OS workers; overrides the online-core autodetect (min 1). Read at the first `Thread.new`, so a program can set it itself: `ENV["SPINEL_WORKERS"] = "1"` before spawning caps its own pool, and `... = "1" unless ENV["SPINEL_WORKERS"]` declares a default the environment still overrides |
| `SPINEL_PREEMPT_SIGNAL` | the signal the monitor uses to preempt a busy worker (default `SIGURG`) |
| `SPINEL_GC_THRESHOLD_KB` | per-worker collection budget; raise it to trade memory for fewer stop-the-world pauses (default 256) |
| `SPINEL_GC_THRESHOLD_OBJ_KB` | the same budget for the OBJECT heap alone, overriding the pair above |
| `SPINEL_GC_THRESHOLD_STR_KB` | the same for the STRING heap alone |
| `SPINEL_GC_OBJ_BUDGET` | the default GATES the widening on what the last collection cost. `obj` pins it off (the object heap alone, as spinel did before 2026-09-09), `walk` pins it on (everything a mark walks). `fixed` is a separate axis: it stops re-aiming the budget after each collection and holds it at its floor |
| `SPINEL_GC_STR_BUDGET` | `fixed` does the same for the STRING budget |
| `SPINEL_GC_STR_MAJOR_KB` | the string OLD generation's own gate: how much old string it takes to make the next string sweep a MAJOR (default 1024). Only a major reclaims an old string |
| `SPINEL_GC_STR_MAJOR` | `fixed` holds that gate at its floor instead of re-aiming it to twice what the last major left. `interval` replaces the gate with a SCHEDULE (a major every N string sweeps, N adapted from the survival ratio) and demotes the size test to a backstop, which is how the object heap has always run its full collection |

`interval` is not the default and the measurements say why. Where the size gate
ratchets -- a live string set well above the floor, so promotion runs ahead of
the gate -- it is a decisive win: on `test/gc_str_major_interval.rb` at a 4 MB
floor it cut the old generation from 67.4 MB to 21.4 MB and peak RSS from
135 MB to 84 MB, and ran no slower. On `benchmark/bm_threaded_render.rb`, where
the ratchet earns the memory it holds, ten order-flipped passes a side put
median RSS at 770 MB against the default's 697 with wall time level, while
cutting the run-to-run spread from 36% to 16% and the worst case from 914 MB to
851 MB. Removing the tail by raising the floor is a trade, and which side of it
a program wants is not something the collector can read off the program.

The three `_KB` variables set where a budget STARTS; the collector re-aims it
from what the collection found. That is right for running a program and wrong
for asking what the re-aiming is responsible for, which is why `fixed` exists.
With it, the budget is whatever the floor says and stays there, so two builds
of one program differ by the change under test and not by two different pacing
histories.

It is a diagnostic and not a policy. Fixing the budget per worker makes the
aggregate scale with the worker count, which is exactly what the adaptive
budget is shaped to avoid: on a workload here the adaptive aggregate trigger
is 224 MB at one worker and 228 MB at eight, while a budget pinned at 64 MB
per worker is 128 MB at one and 576 MB at eight, and the resident set follows
it from 253 MB to 1.4 GB.


The two per-heap variables exist to answer a question the pair cannot. The
mark walks both live sets, and only one heap's trigger decides when it runs.
Raising both together speeds the program up without saying which of them was
pacing it; raising one says. Point `SPINEL_GC_STATS=1` at the result and the
`trigger` field reports the two separately:

```
[gc] 19 collections ... trigger 512.0 MB obj + 0.25 MB str/worker
```

The object figure is the pool-wide budget (the base times the worker count,
for the reason in the note below); the string figure is per worker, which is
why the string one is not multiplied.

The object budget is what may be allocated before the next collection, and
what pays for it is what that collection costs -- and a collection marks BOTH
heaps. Pricing the budget off the object live set alone therefore prices it
off the wrong quantity: a program can grow its string set without the
collection rate noticing, and the mark per unit of work climbs. Since
2026-09-09 the budget is priced off both, and `SPINEL_GC_OBJ_BUDGET=obj`
restores the old behaviour.

Measured on a threaded web application at two concurrencies: 26-44% more
requests per second, at within 5-10% of the memory a fixed
`SPINEL_GC_THRESHOLD_OBJ_KB` floor costs for the same work. The reason to
prefer it over that floor is that it tracks: it settles around 70-78 MB where
the floor would pin 128, and around 227-253 MB where the floor would be too
small. Any fixed number is wrong at one end of a concurrency range.

Since 2026-09-10 it also asks whether the mark is what you are paying for,
which the first version of this did not: it widened the budget by the mark set
either way, so a program holding a large live string set while collecting
cheaply paid memory and got nothing back.

The budget now widens by `alpha` times the string live set, where `alpha` is
the share of a collection the MARK is. `SPINEL_GC_STATS=1` reports it as
`mark share` on the `[gc]` line, so the policy a program is getting is
readable rather than inferred. A program whose collections are nearly all mark
gets what `walk` pins by hand; one whose collections are nearly all sweep gets
what `obj` pins; the two sit at opposite ends of one number instead of needing
different settings.

Two things about how alpha is computed are worth knowing, because both were
arrived at the hard way.

It is counted in OBJECTS MARKED and SLOTS SWEPT, not bytes. A cost ratio taken
per byte does not carry between programs: a cache of large strings and a churn
of small arrays hold the same megabytes with slot counts fifty times apart.
The sweep's cost is per slot and the mark's is per live object, so counted,
the coefficients belong to the collector rather than to a program's allocation
sizes.

And the coefficient relating them is an ORDER rather than a measurement.
Measured on one machine, a mark is 360-560 ns an object and a slot sweep is
about 8 ns serially against about 120 ns across eight workers, where the
parked-worker coordination and the string sweep fold in. Writing those numbers
down would pin one machine's ratio into the collector. Written as the order
they sit at -- about 64 serially, about 4 in parallel -- the answer barely
moves: on the pair of programs that motivated the gate the measured
coefficients give 0.012 and 0.57, the orders give 0.016 and 0.55. The decision
was never close enough for the precision to be worth claiming.

### A note on allocation-heavy threads

Collection stops every worker, so a program that allocates hard pays for
each pause N times over. The budget therefore scales with the worker
count: eight workers collect at eight times the heap size one worker
does, which costs a few megabytes of retained garbage and removes most
of the multi-worker penalty. On one allocation-bound benchmark that took
eight workers from 1.7x **slower** than a single worker to roughly par.

CPU-bound threads scale nearly linearly (measured 8.25x on eight
workers). Allocation-bound ones scale too, though not as steeply: the
object sweep runs on the parked workers, each freeing what it allocated,
which took eight workers from 0.36s to 0.13s on one benchmark. The string
sweep is still serial and is what now bounds that shape; raising
`SPINEL_GC_THRESHOLD_KB` is the other lever available today.
