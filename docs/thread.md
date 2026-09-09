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
| `SPINEL_GC_OBJ_BUDGET` | `walk` prices the object budget off objects PLUS strings -- everything a mark walks -- instead of the object heap alone (default: the object heap alone) |

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

`SPINEL_GC_OBJ_BUDGET=walk` is the third lever and the one to reach for last.
The budget is what may be allocated before the next collection, and what pays
for it is what that collection costs -- and a collection marks BOTH heaps. So
an object budget taken from the object live set alone is priced off the wrong
quantity: a program can grow its string set without the collection rate
noticing, and the mark per unit of work climbs. `walk` prices it off both.

It is off by default because the argument is better than the evidence. The
measurement it comes from (#4384) raised the object FLOOR to a fixed 16 MB per
worker and gained 47% on a threaded server; a floor stops the budget getting
small, which is not the same policy as making it proportional to a live set
that can be enormous. On two shapes reproducible in this tree -- one
single-threaded, one across eight workers, both holding a string set twenty
times the object set -- `walk` bought no time at all and doubled RSS. Measure
it on your own workload before you keep it.

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
