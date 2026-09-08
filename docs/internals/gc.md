# The collector

Spinel's garbage collector is **mark and sweep, non-moving, and precise**:
every root is registered explicitly, so no stack or register is ever scanned
conservatively and no pointer is ever guessed at.

There are two heaps. This is the first thing to understand about the design,
because almost everything else follows from it.

|                | Object heap                                                   | String heap                                       |
|----------------|---------------------------------------------------------------|---------------------------------------------------|
| Allocator      | `sp_gc_alloc` (`lib/sp_alloc.c`)                              | `sp_str_alloc` (`lib/sp_alloc.c`)                 |
| Header         | 48-byte `sp_gc_hdr` immediately before the object             | 24-byte `sp_str_hdr` plus **one marker byte**     |
| What is handed out | `(char *)hdr + 48`                                        | `(char *)(hdr + 1) + 1` -- one past the marker     |
| Live bytes     | `sp_gc_bytes`                                                 | a separate counter, deliberately not folded in    |
| Swept          | inside `sp_gc_collect`                                        | through `sp_gc_str_sweep_hook`, on its own gate   |

A Ruby `String` is a plain `const char *` in generated C. There is nowhere to
put a header the caller can see, so a heap string is identified by **the byte
immediately before the pointer**. That single decision shapes the mark path,
and it is also the source of the collector's most persistent bug family (see
[Marker bytes](#marker-bytes)).

## Roots

`SP_GC_ROOT(v)` pushes `&v` onto a per-worker array of `void **` and relies on
GCC/clang's `cleanup` attribute to pop it when the declaring scope ends. There
is no manual unroot, and no way to leak a root by taking an early return.

The low two bits of the stored address are a tag:

| Tag | Macro               | Marked through                                    |
|-----|---------------------|---------------------------------------------------|
| 0   | `SP_GC_ROOT`        | `sp_gc_mark` -- a direct GC pointer                 |
| 1   | `SP_GC_ROOT_RBVAL`  | `sp_mark_rbval` -- the pointer lives in a union at a nonzero offset, and only for the STR/OBJ/BIGINT tags |
| 2   | `SP_GC_ROOT_STR`    | `sp_mark_string` -- touches nothing unless the marker byte is exactly `0xfe`, so it is safe on a stack buffer or an external `char *` |

`SP_GC_SAVE()` snapshots the root depth for a whole function; `SP_GC_RESTORE()`
returns to it.

Beyond the root array the mark walk consults three hook groups, in this order:

1. **fibers** -- `sp_gc_mark_suspended_fibers_hook`, the saved root stacks of
   suspended green threads;
2. **globals** -- `sp_gc_mark_globals_hook`, installed by the *generated*
   translation unit, which owns state the collector cannot see: the regexp
   match registers, `ARGV`, `$0`, the in-flight exception stack, reassigned
   standard streams;
3. **the mark stack drain**, below.

The root array holds `SP_GC_STACK_MAX` (65536) entries -- a 512 KB static
buffer, and the dominant static allocation in a minimal binary. Embedded
targets can shrink it with `-DSP_GC_STACK_MAX=<n>`, passing the same value when
building `lib/sp_gc.c` and the generated TU. **Overflow is silent and drops the
root**, which is a use-after-free; the bound is a real constraint, not a
formality.

## Marker bytes

`sp_gc_mark` reads `((unsigned char *)obj)[-1]` and dispatches:

| Byte   | Meaning                                            | Action                          |
|--------|----------------------------------------------------|---------------------------------|
| `0xfe` | heap string, unmarked                              | write `0xfc`, done              |
| `0xfc` | heap string, already marked                        | skip                            |
| `0xff` | a literal in static storage (rodata, `.bss`)       | skip                            |
| `0xfd` | an `sp_String` buffer                              | skip                            |
| `0xf1` | frozen                                             | skip                            |
| *anything else* | a real GC object                          | header at `obj - 48`, stamp, push |

The last row is unconditional: any pointer that reaches `sp_gc_mark` and does
not carry a known marker is **treated as a GC object**, its header read out of
whatever happens to precede it, and its `scan` function pointer called.

That is why raw and aliased pointers reaching a scanned slot are the
collector's recurring failure mode. A static singleton, a borrowed buffer, an
interior pointer into a string -- each fabricates a header and jumps through
garbage. Two properties make it hard to find:

- **Whether it faults is luck.** The byte before the object is whatever the
  linker put there. On Linux the fabricated `scan` is frequently NULL and the
  walk simply returns; the same binary shape crashes on macOS.
- **The corruption is silent when it does not fault.** A mark word written into
  rodata, or into a neighbouring allocation, shows up much later.

`SPINEL_GC_VERIFY=1` is therefore the reproducer for anything on the mark path,
not the segfault. It checks every marked object against the live registry and
reports the root group (`phase=root|fibers|globals|scan`) and the object before
invoking anything. New tests for this family assert under the flag; without it
they pass against the broken build.

## Marking

The mark phase is **full by default**. `sp_gc_mark_all` walks every root every
cycle, and only the *sweep* is generational -- a distinction worth stating
plainly, because "generational GC" usually implies the opposite.

`SPINEL_GC_MINOR=1` makes the mark generational too, through the write barrier
and the remembered set. It is opt-in, for a measured reason rather than a
doubtful one; see "The generational mark, and why it is opt-in" below.

Marks are a 30-bit generation stamp (`sp_gc_mark_gen`), so a new cycle unmarks
the whole heap without touching a single object. On the (rare) wrap the heap is
cleared once so no stale stamp can alias the reused value.

Tracing uses an explicit mark stack of 65536 entries. When it is full,
`sp_gc_mark` calls `scan` directly instead -- correct, but recursive, so a very
deep object graph falls back to the C stack.

## Sweeping

**Object heap.** Each worker owns a young list. Every collection sweeps young:
dead objects are freed (through `recycle` if the type supplies one, else
`finalize` + `free`), survivors are promoted onto the single shared old list.
The old list is walked only on a **full** cycle, every 8th
(`SP_GC_FULL_INTERVAL`). Between fulls an old object that dies is reclaimed
late -- delayed reclamation, not a leak.

**String heap.** The same young/old split, but gated on the string heap's own
threshold. The collector used to run the full live-string walk on *every*
object collection, making each one O(live strings) -- the dominant cost of
allocation-heavy programs (2.9 s of an 8.0 s GC total on one profile). Skipping
is safe because string marks accumulate: a dead string at worst survives to the
next string sweep, and that sweep resets the marks. The old string generation is
gated one level further, on a threshold of its own.

## Thresholds

| Heap                  | Initial | Under `SPINEL_GC_STRESS` |
|-----------------------|---------|--------------------------|
| Object                | 256 KB  | 2048 B                   |
| String (young)        | 256 KB  | 2048 B                   |
| String (old)          | 1 MB    | unchanged                |

After each collection the threshold is retuned from what the sweep actually
recovered:

- freed less than a quarter of the pre-collect bytes: the heap is genuinely
  growing, so `threshold = before * 2` and back off;
- otherwise `threshold = live * 4`, floored at the initial value.

A promoted string counts as a survivor, not a reclamation. Leaving it out would
read as a very productive sweep and shrink the trigger, collecting harder and
harder as the old generation grows.

## Threads

Under `SP_THREADS` collection is **stop-the-world**. `sp_stw_collect`
(`lib/sp_sched.c`) raises the safepoint flag, wakes idle workers so they park
and publish their roots rather than sit through the collection, waits for every
other worker, collects, and releases. A re-entrancy guard covers a finalizer
that allocates past the threshold during the sweep: the collector already holds
exclusive access, so that allocation proceeds rather than parking the collector
on itself.

Two things about the allocation path are there for measured reasons, not
tidiness:

- **Young lists are per worker and cache-line padded.** Removing the CAS on a
  shared head was not enough on its own -- adjacent workers' 8-byte slots shared
  a line, and the false sharing kept object-heavy parallel allocation from
  scaling. One padded line per worker isolates them.
- **The live-byte counter is batched.** It stays a single shared relaxed atomic
  (the collector's recompute and `GC.stat` both need one authoritative total),
  but each worker accumulates privately and flushes every 16 KB. A shared
  read-modify-write per allocation measured about 13x on the counter alone at
  four workers. The trigger then lags the true total by at most
  quantum x workers, which is bounded overshoot for a heuristic.

The string threshold is **per worker** in the threaded build: each worker fires
at the full value, so the aggregate bound scales with the worker count and the
stop-the-world frequency per worker stays independent of N. Checking a shared
aggregate against threshold/N instead multiplied the collection count by N and
left allocation-heavy parallel workloads stop-the-world bound.

## What a program can see

```ruby
GC.start     # collect now
GC.stat      # a Hash of counters
GC.compact   # accepted, but see below
```

`GC.stat` reports `bytes`, `old_bytes`, `threshold`, `cycle`, `full_runs`,
`str_bytes`, `str_count`. The string figures are there because the string heap
is excluded from `bytes`, and without them "RSS huge but bytes tiny" on a
string-heavy workload has no explanation.

`GC.compact` is accepted and collects. **Nothing moves** -- the collector is
non-moving, and the method exists so that code written for CRuby does not have
to be edited.

Environment variables:

| Variable              | Effect                                                                 |
|-----------------------|------------------------------------------------------------------------|
| `SPINEL_GC_STRESS`    | drops the thresholds to 2048 B, so nearly every allocation collects     |
| `SPINEL_GC_VERIFY`    | registry check on every mark, plus a SIGSEGV/SIGBUS reporter naming the phase and object |
| `SPINEL_GC_PHASES`    | adds a `[gcph]` line splitting collector time into mark / old sweep / slot sweep / remembered clear / string sweep / trim, named as the collector's own comments name them; arms the reporter on its own |
| `SPINEL_GC_MINOR`     | generational MARK: a non-full cycle walks the young objects and the remembered set instead of the whole live graph. Opt-in; see below |
| `SPINEL_MAX_HEAP_MB`  | RSS ceiling, checked at GC trigger points against `/proc/self/statm`; Linux only, off by default |

## The generational mark, and why it is opt-in

There **is** a write barrier now, and `SPINEL_GC_MINOR=1` turns on the mark
that uses it: `sp_gc_wb` records an old object that takes a young reference,
and a non-full cycle marks from the roots plus that remembered set rather than
tracing the whole live graph. It is off by default, and the reason is a
measured trade rather than doubt about the code:

- it wins where the retained heap is **large and stable** -- a 440 MB live
  object set here is ~5% faster with 4% less RSS, and the Campfire port at
  #4386 measured +4.0% on its room page;
- it loses where the shape is **churn with a small live set** -- optcarrot is
  ~2.7% slower, and a 50-program LangArena run in August was 13% slower overall
  (BWTEncode 4.3x, AStar 2.3x) against 27% less peak RSS.

Default-on was tried once and reverted (01bc08c8). The correctness side has
moved since: `gc-minor-test` holds one leg per barrier gap that shipped, and
`SPINEL_GC_VERIFY_GEN=1` names the holder of anything a barrier missed. The
performance side has not moved, which is why the flag is still a choice an
application makes rather than a default: an application that retains a lot can
measure the win and take it.

## Limits, and where the next work is

**The mark does not parallelize.** The young sweep is handed to the parked
workers, one slot each; the mark runs on the collector thread alone. Its cost
tracks the number of IN-FLIGHT fibers, not the worker count -- every live
fiber's saved roots are walked serially by `sp_mark_suspended_fibers` -- so on
a server it grows with concurrency: mark went 0.317 -> 0.812 ms/request from
4 to 64 connections with the worker count held fixed, while slot sweep stayed
flat (#4384). A terminated fiber already costs nothing there (its snapshot is
dropped at termination, since it points into unwound frames). Slicing the fiber
list to the parked workers is the obvious lever and is not a small change:
`sp_gc_mark` writes `h->marked` and pushes a shared mark stack.

Also absent:

- **compaction** -- nothing moves, so fragmentation is the allocator's problem;
- **incremental or concurrent marking** -- the pause is the whole mark;
- **`ObjectSpace.define_finalizer`** -- `finalize` and `recycle` are internal
  hooks on `sp_gc_hdr`, with no Ruby-level surface.

A nursery has been attempted twice and abandoned both times. The string heap's
generational sweep, by contrast, worked (-6% runtime and -25% RSS on one
benchmark) -- strings are leaves in the object graph, so the reason the nursery
failed did not apply to them.

The write barrier that section used to call the next step now exists (see
above). The warning it carried is worth keeping, because it turned out to be
right: the barrier sits on every ivar and container store, which is the hottest
code the compiler emits, and the frame-rate figure this project gates on is
sensitive enough to code layout that a real cost and a layout accident are easy
to mistake for each other. Settle how a change will be measured before writing
it -- interleave the arms, and prefer flipping an environment variable on ONE
binary over comparing two builds.
