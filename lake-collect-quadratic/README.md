# Lake: `Job.collectArray` and `Job.mixArray` take quadratic time when their inputs are still running

## Summary

`Job.collectArray`, `Job.mixArray` and `Job.collectVector` combine N jobs with a
left fold of `Job.zipWith`. Each step of the fold appends to accumulated arrays:
the result array (`Array.push`), the log (`++`) and the trace's `inputs`
(`Array.push` in `BuildTrace.mix`). If the input jobs are still running when the
collection is built, which is the usual case in a build, each step runs in its
own task. The Lean runtime marks every value that passes between tasks as
multi-threaded, and `lean_is_exclusive` is always false for multi-threaded
objects. So every step copies the accumulated arrays, and collecting N jobs
costs O(N^2) time.

The reproduction below is a `lakefile.lean` with no sources. At 64,000 pending
inputs, `Job.collectArray` takes 13.4 s. A single fold over all the results
produces the same value, log, trace and error in 0.03 to 0.06 s. Each doubling
of N multiplies the time by about 4 (3.5 to 4.3). The behaviour is the same on
v4.34.1, v4.35.0 and nightly-2026-10-12.

If the inputs have already finished when the collection is built, the fold
takes the runtime's synchronous fast path, nothing is marked multi-threaded,
and `collectArray` is linear. A benchmark that collects finished jobs will not
show the problem.

`Job.collectList` and `Job.mixList` (right folds) are linear when the inputs
have no log entries. They are quadratic in the number of log entries whether
the inputs are pending or finished, because each step appends the accumulated
log onto the next input's log.

## Expected vs actual

Expected: combining N jobs costs O(N) time, as a single fold over the N
results does.

Actual: with pending inputs, `Job.collectArray`, `Job.mixArray` and
`Job.collectVector` cost O(N^2). `Job.collectList` and `Job.mixList` cost
O(N^2) in the total number of log entries.

## Reproduction

The whole reproduction is `lakefile.lean`. Each target makes `N` input jobs
that return `i : Nat`, combines them with one combinator, waits for the
combined job, and prints the time from building the combined job to its
completion. The time is measured inside the build, so loading the lakefile is
not included. The targets are:

| target          | combines the inputs with                                    |
|-----------------|-------------------------------------------------------------|
| `collectArray`  | `Job.collectArray`                                          |
| `mixArray`      | `Job.mixArray`                                              |
| `mixList`       | `Job.mixList`                                               |
| `collectList`   | `Job.collectList`                                           |
| `collectVector` | `Job.collectVector`                                         |
| `linear`        | control: `collectArrayLinear`, one fold in one task (below) |

Environment variables select the case:

- `N`: number of inputs (default 1000).
- `INPUTS=pending` (default): every input waits on one `IO.Promise`. The
  combined job is built while all inputs are pending, then the promise is
  resolved. This is the situation in a build, where the fetch pass builds the
  job graph before the jobs run. `INPUTS=done`: every input is already
  finished (`Task.pure`).
- `LOGS=1`: every input carries one log entry.
- `FAIL=i`: input `i` fails.

One run:

```
$ N=16000 lake build collectArray
ℹ [1/1] Ran collect/collectArray
info: stdout/stderr:
RESULT collectArray n=16000 inputs=pending logs=false result=ok log_entries=0 trace_inputs=16000 trace_hash=5c156af170b0c7bb build_us=7870 wait_us=819356
Build completed successfully (1 job).
```

`build_us` is the time to build the combined job, `wait_us` the time from
resolving the promise until the combined job has finished.

`repro.sh [TOOLCHAIN]` deletes `.lake`, loads the lakefile once, then sweeps N
for every combinator against the control and prints one table per combinator.
The array combinators are swept with `INPUTS=pending` and no log entries, the
list combinators with `INPUTS=pending` and `LOGS=1`, since those are the cases
where each is quadratic. It then prints a table of every combinator at one N for
all four combinations of `INPUTS` and `LOGS`. Every build has a time limit
(`LIMIT`, default 300 s). `SIZES` and `MATRIX_N` change the job counts. A full
run takes about two minutes on the machine below.

```
$ ./repro.sh
Lake version 5.0.0-src+5045d00 (Lean version 4.34.1)
cores: 18

Each table: INPUTS=pending, collection time in ms (measured inside the build) of a
combinator against the linear control. The array combinators are quadratic with no
log entries; the list combinators only when the inputs have log entries.

collectArray (LOGS=0):

|      N | collectArray ms | linear ms |  ratio |
|-------:|----------------:|----------:|-------:|
|   1000 |             3.8 |       1.1 |     3x |
|   2000 |            12.8 |       1.9 |     7x |
|   4000 |            48.6 |       3.6 |    14x |
|   8000 |           191.4 |       6.9 |    28x |
|  16000 |           776.9 |      13.3 |    58x |
|  32000 |          3270.2 |      28.3 |   116x |
|  64000 |         13445.7 |      58.4 |   230x |

mixArray (LOGS=0):

|      N |     mixArray ms | linear ms |  ratio |
|-------:|----------------:|----------:|-------:|
|   1000 |             3.3 |       1.1 |     3x |
|   2000 |            10.8 |       1.9 |     6x |
|   4000 |            39.9 |       3.6 |    11x |
|   8000 |           158.1 |       6.9 |    23x |
|  16000 |           635.8 |      13.3 |    48x |
|  32000 |          2644.5 |      28.3 |    93x |
|  64000 |         10737.4 |      58.4 |   184x |

collectVector (LOGS=0):

|      N | collectVector ms | linear ms |  ratio |
|-------:|----------------:|----------:|-------:|
|   1000 |             4.5 |       1.1 |     4x |
|   2000 |            15.1 |       1.9 |     8x |
|   4000 |            59.6 |       3.6 |    17x |
|   8000 |           239.0 |       6.9 |    35x |
|  16000 |           963.4 |      13.3 |    72x |
|  32000 |          4140.2 |      28.3 |   146x |
|  64000 |         17215.7 |      58.4 |   295x |

collectList (LOGS=1):

|      N |  collectList ms | linear ms |  ratio |
|-------:|----------------:|----------:|-------:|
|   1000 |             2.9 |       1.2 |     2x |
|   2000 |            10.6 |       2.2 |     5x |
|   4000 |            38.2 |       4.4 |     9x |
|   8000 |           147.8 |       8.4 |    18x |
|  16000 |           599.6 |      16.6 |    36x |
|  32000 |          2470.1 |      31.9 |    77x |
|  64000 |          9903.0 |      65.3 |   152x |

mixList (LOGS=1):

|      N |      mixList ms | linear ms |  ratio |
|-------:|----------------:|----------:|-------:|
|   1000 |             2.9 |       1.2 |     2x |
|   2000 |            10.2 |       2.2 |     5x |
|   4000 |            38.3 |       4.4 |     9x |
|   8000 |           144.8 |       8.4 |    17x |
|  16000 |           580.4 |      16.6 |    35x |
|  32000 |          2466.9 |      31.9 |    77x |
|  64000 |         10026.5 |      65.3 |   154x |

Each combinator at N=16000 (collection time in ms):

| combinator     | pending, no logs |    pending, logs |    done, no logs |       done, logs |
|----------------|------------------|------------------|------------------|------------------|
| collectArray   |            800.4 |           1445.1 |              6.2 |              8.1 |
| mixArray       |            649.7 |           1198.5 |              6.2 |              8.1 |
| collectVector  |            983.9 |           1612.7 |              6.5 |              8.3 |
| collectList    |             11.0 |            584.0 |              6.6 |            266.8 |
| mixList        |             10.9 |            579.5 |              6.4 |            266.7 |
| linear         |             13.7 |             16.3 |             10.5 |             12.5 |
```

How to read this:

- Pending inputs: `collectArray` grows by a factor of about 4 per doubling of
  N. The control grows by a factor of about 2. The ratio to the control grows
  with N, from 3x at N = 1,000 to 230x at N = 64,000.
- `mixArray` has no result array, but it is still quadratic, because the
  trace `inputs` array accumulates in the same way, and so does the log when
  the inputs have log entries. `collectVector` is
  slightly slower than `collectArray`, because every step copies a vector of
  the full length N.
- Finished inputs: every left fold is linear.
- `collectList` and `mixList` are linear without logs. With one log entry per input it is
  quadratic, whether the inputs are pending or finished.
- Each copy is freed at the next step, so the cost is CPU time and
  allocation, not memory. By arithmetic (not measured), `collectArray` at
  N = 64,000 copies about 4·10^9 pointers, about 33 GB.
- The control runs in the interpreter, because it is defined in the lakefile,
  while the Lake combinators are compiled. That is why the control is slower
  than `collectArray` when the inputs have finished. It does not affect the
  growth rates.

The control computes the same result. With `LOGS=1 FAIL=7 N=50`, `collectArray`,
`mixArray`, `collectVector` and `linear` all report
`result=error log_entries=50 trace_inputs=50` and the same `trace_hash`.

## Root cause

Line numbers are for tag v4.34.1. The Lake code involved is the same in v4.35.0
and nightly-2026-10-12 apart from line offsets (v4.35.0 added cancellation
checks to `Job.mapM` and `Job.bindM`, which these combinators do not use). The
runtime code is in `src/runtime/object.cpp` and `src/include/lean/lean.h`.

### The fold

`src/lake/Lake/Build/Job/Monad.lean`, line 275:

```lean
public def collectArray (jobs : Array (Job α)) (traceCaption := "<collection>") : Job (Array α) :=
  jobs.foldl (zipWith (sync := true) Array.push) (traceRoot (Array.mkEmpty jobs.size) traceCaption)
```

`zipWith` (line 243) calls `zipResultWith` (line 231), whose job task is

```lean
self.task.bind (prio := prio) (sync := true) fun rx =>
other.task.map (prio := prio) (sync := sync) fun ry =>
f rx ry
```

and whose `f` returns `.ok (Array.push a b) (sa.merge sb)`. Each step updates
three accumulators:

- the result array: `Array.push a b`;
- the log: `JobState.merge` (`Lake/Build/Job/Basic.lean`, line 83) sets
  `log := a.log ++ b.log`;
- the trace: `JobState.merge` sets `trace := mixTrace a.trace b.trace`, and
  `BuildTrace.mix` (`Lake/Build/Trace.lean`, line 366) sets
  `inputs := t1.inputs.push t2`. The trace of the combined job has one input
  per collected job.

These updates are in place only if the accumulator is exclusive.

### Why the accumulator is never exclusive when inputs are pending

- `lean_is_exclusive` (`lean.h`, line 729) returns `false` for every object
  marked multi-threaded (MT), whatever its reference count:

  ```c
  static inline bool lean_is_exclusive(lean_object * o) {
      if (LEAN_LIKELY(lean_is_st(o))) {
          return lean_internal_get_rc(o) == 1;
      } else {
          return false;
      }
  }
  ```

- `lean_array_push` (`object.cpp`, line 2768) copies a non-exclusive array.
  Since the elements are shared, it also increments the reference count of
  each element, and these are atomic increments when the elements are MT.
  `a ++ b` pushes the elements of `b` onto `a`, so it copies `a` in the same
  way.
- Values become MT when they pass between tasks. `alloc_task` (line 1180) marks
  a new task's closure MT, including everything the closure captures. In
  `zipResultWith`, the `map` closure captures `rx`, which is the accumulated
  result. `resolve_core` (line 938) marks every task result MT.
- When the inputs are pending at the time the fold runs, `lean_task_bind_core`
  (line 1284) and `lean_task_map_core` (line 1222) allocate real tasks. Step k
  is then a task whose input is the MT result of step k-1, or a closure that
  captured it. `push` and `++` therefore copy arrays of length k, and the
  total is O(N^2).
- When an input has already finished, `sync := true` takes the fast path:
  `lean_task_bind_core` applies the continuation directly, and
  `lean_task_map_core` wraps the result with `lean_task_pure`, which does not
  mark it MT. The accumulator stays single-threaded and exclusive, and the fold
  is linear. This is the `INPUTS=done` column.

Once one step is a real task, every later step is too, because each later
`bind` is created on a pending task. So every step from the first input that
is still running when the collection is built copies the accumulator.

### Affected combinators

All five are in `Lake/Build/Job/Monad.lean` (lines 263 to 284 at v4.34.1):

| combinator            | fold                              | quadratic when                                             |
|-----------------------|-----------------------------------|------------------------------------------------------------|
| `Job.collectArray`    | `foldl` of `zipWith Array.push`   | inputs pending (value, log, trace inputs)                  |
| `Job.mixArray`        | `foldl` of `Job.mix`              | inputs pending (log, trace inputs)                         |
| `Job.collectVector`   | `fold` of `zipWith Vector.set`    | inputs pending (a full-length vector is copied every step) |
| `Job.collectList`     | `foldr` of `zipWith List.cons`    | inputs have log entries, pending or finished               |
| `Job.mixList`         | `foldr` of `Job.mix`              | inputs have log entries, pending or finished               |

`mixList` is not a target in the lakefile. It has the same fold as
`collectList`, with `fun _ _ => ()` for `List.cons`.

`collectList` and `mixList` are right folds:
`merge job.state acc.state`. `List.cons` is O(1). `BuildTrace.mix` pushes the
whole accumulated trace as one input of the job's own trace, which is also
O(1), so the trace becomes a nested tree of depth N. The log, however, is
`job.log ++ acc.log`. At every step this pushes all accumulated entries onto a
copy of the input job's log, whether or not anything is MT.

A single `Job.mix` or `Job.add` is cheap. The cost is quadratic only when they
are folded over many jobs, as these combinators and the built-in code below
do.

Lake's built-in facets use these combinators, or the same fold, over
collections that grow with the size of a package. I have not measured these
end to end:

- `LeanLib.recBuildLean` (`Lake/Build/Library.lean`, line 67) folds `job.mix`
  over every module of a library. This is the default build facet of a
  `lean_lib`. In nightly-2026-10-12 the same fold appears in
  `LeanLib.recBuildElabArts` and `LeanLib.recBuildIRArts`.
- `LeanLib.recBuildStatic` (`Library.lean`, line 93):
  `Job.collectArray (oJobs ++ moreOJobs)` over the object files of every
  module.
- `buildStaticLib`, `buildSharedLib`, `buildLeanSharedLib` and `buildLeanExe`
  (`Lake/Build/Common.lean`, lines 877, 996, 1051 and 1109) collect all link
  objects with `Job.collectArray`.
- `inputDir` (`Common.lean`, line 823) collects one job per file in a
  directory.
- `TargetArray.fetchIn` (`Lake/Build/Target/Fetch.lean`, line 155).
- In `Lake/Build/Module.lean`, `fetchImportLibs` (line 163),
  `fetchImportInfo` (line 444, `collectVector`), `Module.recFetchPreSetup`
  (line 574) and `recComputeModuleLinkInfo` (line 1311) collect over a
  module's imports or link dependencies.

## Why it matters

A build that creates many jobs dynamically and then needs all of their results
in one place pays this cost once per collection. Examples are tens of thousands
of per-file jobs gathered into a library, an archive or a report, a `lean_lib`
with many modules, and an `input_dir` with many files. The collected job is
created during the fetch pass, while the inputs are still being built, which is
the slow case. The cost is CPU time on worker threads. In the reproduction all
inputs finish at the same moment, so all of it lies on the critical path. In a
real build the steps run as the inputs finish, so part of the cost overlaps
with other work, but the steps for the last inputs, which copy the longest
arrays, delay everything that depends on the collection. From the table: about
0.2 s at 8,000 jobs, 0.78 s at 16,000, 3.3 s at 32,000 and 13 s at 64,000. The
control takes under 0.1 s at every size.

Below a few thousand jobs the cost is a few milliseconds, which may be why this
has not been noticed.

## Workaround

Collect all results in one task with one fold (this is the `linear` target):

```lean
def collectArrayLinear (jobs : Array (Job α)) (traceCaption := "<collection>") : Job (Array α) :=
  Job.ofTask <| Task.mapList (sync := true) (tasks := (jobs.map (·.task)).toList) fun rs =>
    let init : JobResult (Array α) := .ok (Array.mkEmpty jobs.size) {trace := .nil traceCaption}
    rs.foldl (init := init) fun
      | .ok a sa, .ok b sb => .ok (a.push b) (sa.merge sb)
      | ra, rb => .error 0 (ra.state.merge rb.state)
```

`Task.mapList` waits for the tasks one after another, consing each result onto
a list, which is O(1) per task. The fold then runs in one task on an
accumulator that it allocates itself, which is single-threaded and exclusive,
so every `push` and `++` is in place. The input results are MT, but they are
only read or stored as elements, never updated. The fold is the same function
as `collectArray`'s `zipWith` step, applied in the same order, so the value,
the log, the trace (including its hash) and the error behaviour are the same.
On failure, the result is `.error 0` with the merged state of all inputs, after
all inputs have finished.

For `mixArray`, use `fun _ _ => ()` in place of `push`, with `()` as the
initial value. If the trace's `inputs` are not needed, which is likely for a
report, the trace work can also be dropped.

## Suggested fix

Implement `collectArray`, `mixArray` and `collectVector` as one fold over all
results in one task, as in the workaround. The result is the same as today's,
as checked above. A shared helper:

```lean
-- Type-checks against Lake v4.34.1 (outside Lake, under another namespace).
@[inline] def foldResults (jobs : Array (Job α)) (init : β) (f : β → α → β)
    (traceCaption := "<collection>") : Job β :=
  Job.ofTask <| Task.mapList (sync := true) (tasks := jobs.toList.map (·.task)) fun rs =>
    rs.foldl (init := .ok init {trace := .nil traceCaption}) fun
      | .ok b sb, .ok a sa => .ok (f b a) (sb.merge sa)
      | rb, ra => .error 0 (rb.state.merge ra.state)

def collectArray (jobs : Array (Job α)) (traceCaption := "<collection>") : Job (Array α) :=
  foldResults jobs (Array.mkEmpty jobs.size) Array.push traceCaption

def mixArray (jobs : Array (Job α)) (traceCaption := "<collection>") : Job Unit :=
  foldResults jobs () (fun _ _ => ()) traceCaption
```

`collectVector` can fold with an index, or call `collectArray` and convert the
result. `LeanLib.recBuildLean` can call `Job.mixArray` on the module jobs in
place of its own `job.mix` fold.

Notes:

- Today the fold does its work step by step as inputs finish. With the change,
  all the merging happens once, after the last input has finished. That is
  O(N) work at the end, compared with O(N^2) spread over the build. In both
  cases the combined job cannot finish before its last input.
- `collectList` and `mixList` build a nested trace (right fold). To keep their
  trace hashes, build the log left to right in one pass and the trace with a
  right fold over the collected states. Both are linear. If the trace shape
  may change, they can call the array versions, which produce a flat trace.
  The hashes of dependents would then change once, and those dependents would
  be rebuilt once.
- A balanced tree of `zipWith` keeps the step-by-step merging and reduces the
  copying to O(N log N). The single fold is simpler and linear.
- The root cause is general: any left fold that updates an accumulator across
  task boundaries copies it at every step. Whether `lean_is_exclusive` could
  treat an MT object with a reference count of one as exclusive is a runtime
  question, outside the scope of this report.

## Environment

- macOS 26.7.1 (25G241), Apple M5 Max (arm64), 18 cores.
- elan 4.2.4.
- Toolchains tested, all already installed under `~/.elan/toolchains`. Times
  are from `./repro.sh TOOLCHAIN`, with `INPUTS=pending` and no logs:

| Toolchain | Lean / Lake version | `collectArray` 16k / 32k / 64k (ms) | factor per doubling | control at 64k (ms) |
|---|---|---|---|---|
| `leanprover/lean4:v4.34.1` | Lean 4.34.1, Lake 5.0.0-src+5045d00 | 851 / 3527 / 14661 | 3.5 to 4.2 | 62 |
| `leanprover/lean4:v4.35.0` | Lean 4.35.0, Lake 5.0.0-src+eb6cafb | 848 / 3574 / 14783 | 3.7 to 4.3 | 30 |
| `leanprover/lean4-nightly:nightly-2026-10-12` | Lean 4.36.0-nightly-2026-10-12, Lake 5.0.0-src | 832 / 3516 / 14483 | 3.6 to 4.2 | 27 |

All three toolchains give the same per-combinator picture as the v4.34.1 table
above. `lean_is_exclusive` is the same in all three `lean.h` files.
`Job/Monad.lean` is identical in v4.35.0 and nightly-2026-10-12. The
`collectArray`, `mixArray`, `collectList`, `mixList` and `collectVector`
definitions and `BuildTrace.mix` are unchanged from v4.34.1.
