# Lake: concurrent `fetch` from running jobs builds the same target more than once

## Summary

When several running jobs call `fetch` on the same build key at the same time
(a dependency discovered inside a job body, rather than during the synchronous
recursive fetch that builds the job graph), Lake can run that key's build
function, and so its job, more than once in a single `lake build`. The build
store memoises fetches with `fetchOrCreate`, which looks the key up and inserts
the result as two separate operations with the `create` action in between. Every
fetcher that looks the key up before the first one has stored its result misses
and builds the target again. The reproduction below is a 32-line `lakefile.lean`
in which 64 jobs fetch one target. On an 18-core machine that target runs 2 to 18
times per build, and duplicates appear in every run. The bug reproduces on
v4.34.1, v4.35.0 and nightly-2026-10-12.

## Expected vs actual

Expected: within one `lake build`, each build key is created once, and every
fetch of that key returns the same job, whether the fetch is made while the job
graph is being built or from inside a running job.

Actual: when the fetches come from concurrently running jobs, the key is created
once per fetcher that misses, up to about the number of worker threads. Each copy
is a separate job. It runs the target's side effects again, is reported again
(`Ran race/shared` appears many times with `-v`), and adds to the job count.

## Reproduction

The whole reproduction is in `lakefile.lean`. It contains no Lean sources and no
dependencies.

```lean
import Lake
import Std.Sync.Mutex
open Lake DSL

package race

/-- Each run of this target's job appends one line to `.lake/build/shared.log`. -/
target shared pkg : Unit := Job.async do
  IO.FS.createDirAll pkg.buildDir
  IO.FS.withFile (pkg.buildDir / "shared.log") .append (·.putStrLn "built")

/-- Bug: 64 jobs, each fetching `shared` from inside its running job body. -/
target dynamic : Unit := do
  let jobs ← (Array.range 64).mapM fun _ => Job.async do
    let job ← shared.fetch
    discard job.await
  return Job.mixArray jobs

/-- Workaround: as `dynamic`, but the fetches are serialised by a mutex. -/
target serialised : Unit := do
  let mutex ← Std.Mutex.new ()
  let jobs ← (Array.range 64).mapM fun _ => Job.async do
    let job ← mutex.atomically shared.fetch
    discard job.await
  return Job.mixArray jobs

/-- Control: the same 64 fetches, made while the job graph is being built. -/
target static : Unit := do
  let jobs ← (Array.range 64).mapM fun _ => do
    let job ← shared.fetch
    job.mapM fun _ => pure ()
  return Job.mixArray jobs
```

- `dynamic` shows the bug. Each of 64 jobs calls `shared.fetch` from its own
  job body.
- `static` is the control. It makes the same 64 fetches on the fetch thread,
  while it builds the job graph, which is how Lake's built-in facets fetch.
- `serialised` is the workaround: the `dynamic` pattern with the fetch made under
  a mutex.

`shared` has no trace, so every `lake build` runs it again. The number of lines
in `.lake/build/shared.log` after one build is the number of times its job ran in
that build. The correct number is 1.

`repro.sh [TOOLCHAIN] [RUNS]` builds each target `RUNS` times (default 10). It
deletes `.lake` before every build and prints the count for each build. The
toolchain defaults to `lean-toolchain` (v4.34.1) and is passed to elan as
`lake +TOOLCHAIN`.

```
$ ./repro.sh
Lake version 5.0.0-src+5045d00 (Lean version 4.34.1)
dynamic    shared built: 5 17 17 17 13 18 17 17 17 17  (runs with duplicates: 10/10)
serialised shared built: 1 1 1 1 1 1 1 1 1 1  (runs with duplicates: 0/10)
static     shared built: 1 1 1 1 1 1 1 1 1 1  (runs with duplicates: 0/10)

$ ./repro.sh leanprover/lean4:v4.35.0
Lake version 5.0.0-src+eb6cafb (Lean version 4.35.0)
dynamic    shared built: 17 4 10 17 10 8 17 2 4 4  (runs with duplicates: 10/10)
serialised shared built: 1 1 1 1 1 1 1 1 1 1  (runs with duplicates: 0/10)
static     shared built: 1 1 1 1 1 1 1 1 1 1  (runs with duplicates: 0/10)

$ ./repro.sh leanprover/lean4-nightly:nightly-2026-10-12
Lake version 5.0.0-src (Lean version 4.36.0-nightly-2026-10-12)
dynamic    shared built: 13 17 17 3 14 17 12 2 17 4  (runs with duplicates: 10/10)
serialised shared built: 1 1 1 1 1 1 1 1 1 1  (runs with duplicates: 0/10)
static     shared built: 1 1 1 1 1 1 1 1 1 1  (runs with duplicates: 0/10)
```

You can see the same thing without the script, since Lake reports each copy as
its own job:

```
$ rm -rf .lake && lake build -v dynamic
✔ [0/18] Ran job computation
✔ [1/18] Ran race/shared
✔ [2/18] Ran race/shared
...
✔ [11/18] Ran race/dynamic
✔ [12/18] Ran race/shared
...
✔ [18/18] Ran race/shared
Build completed successfully (18 jobs).
```

`lake build static` and `lake build serialised` both report
`Build completed successfully (2 jobs).`

The number of duplicates is bounded by the number of worker threads running
fetches at the same moment:

| `LEAN_NUM_THREADS` | `shared` runs per build over 10 builds (v4.34.1) |
|---|---|
| 2 | 2 1 1 2 1 1 2 2 1 2 |
| 4 | 4 3 3 3 3 3 3 4 3 3 |
| default (18 cores) | 5 17 17 17 13 18 17 17 17 17 |

## Root cause

Line numbers are for tag v4.34.1. The same code is present, unchanged, in v4.35.0
and nightly-2026-10-12.

`src/lake/Lake/Util/Store.lean`, `fetchOrCreate` (line 47):

```lean
@[inline] public def fetchOrCreate
  [Monad m] (key : κ) [MonadStore1Of key α m] (create : m α)
: m α := do
  if let some val ← fetch? key then
    return val
  else
    let val ← create
    store key val
    return val
```

The build store is an `IO.Ref BuildStore`, which `RecBuildT` holds as a
`StateRefT' IO.RealWorld BuildStore` (`Lake/Build/Fetch.lean`, line 47).
`fetch?` and `store` are each a single `modifyGet`/`modify` on that ref
(`Lake/Util/StoreInsts.lean`, line 22), so each is atomic by itself. The
composition is not. Between a miss and the `store` that follows it there is a
window: the whole of `create`. Any other thread that looks the key up during that
window also misses, runs its own `create`, and stores its own job, and the last
writer wins.

The path taken by `shared.fetch` is:

`BuildInfo.fetch` → `recFetchWithIndex` (`Lake/Build/Index.lean:58`) →
`recFetchAcyclic` (`Lake/Build/Topological.lean:94`, `guardCycle` on the call
stack) → `recBuildWithIndex`, `.target` case (`Lake/Build/Index.lean:35`):
`fetchOrCreate key do (decl.targetConfig h).fetchFn pkg`.

Facets reach the same race through `Index.lean:48` (`fetchOrCreate key recFetch`)
and `recFetchMemoize` (`Topological.lean:123`).

The race needs fetches on more than one thread. `Job.async`, `Job.mapM` and
`Job.bindM` (`Lake/Build/Job/Monad.lean`, from line 169) give the job body the
same store ref they were spawned with, so a `fetch` inside a job body runs on a
task-pool worker against the shared store. In the usual case all fetches run on
one thread, during the recursive pass that `lake build` makes to build the job
graph, and lookups and inserts cannot interleave. That is why ordinary builds do
not show the bug. Lake's built-in facets follow this design on purpose. The
comment in `Module.recFetchPreSetup` (`Lake/Build/Module.lean`, around line 551)
says that it uses `await` on the fetch thread rather than `bindM`, to keep import
graph processing on a single thread.

Some built-in code does fetch from inside jobs. For example,
`Module.recFetchSetup` runs `mkModuleSetup`, and so `fetchTransImportArts`, inside
`presetup.mapM`. As far as I can tell, the keys it fetches (`input`,
`exportInfo`) have already been created during the synchronous pass, so those
lookups hit. I have not audited every built-in facet for this.

In the reproduction, `create` for `shared` only spawns one `Job.async`, which is
fast, yet duplicates still appear in every run. In real targets `create` usually
takes longer, because it recursively fetches the target's own dependencies before
it returns a job. That widens the window.

## Why it matters

- **Dynamic dependencies.** Some targets learn their dependencies only after they
  start running, so they have to fetch from inside the job. Examples are a source
  file whose imports are found by scanning it, a code generator whose inputs are
  listed in a file it produces, and any build where a per-unit job reads a
  manifest and then fetches the units it names. With fan-out, many such jobs
  often fetch the same shared key (a common dependency, a shared configuration, a
  toolchain probe) at about the same time.
- **Duplicated side effects.** Each duplicate runs the target's job again. Two
  jobs that write the same output file race with each other. Logs, cache
  uploads, counters and reported job counts are also duplicated.
- **Duplicated expensive work.** A compile, download or test that should run
  once runs once per worker thread.
- **Inconsistent results.** Different dependents hold different `Job` objects
  for the same key, and the store keeps whichever was written last. If the
  target's output is not deterministic (timestamps, nonces, temporary paths),
  dependents can see different results for the same key within one build.

## Workaround

Serialise fetches made from inside jobs with a mutex shared by every job that
fetches (the `serialised` target):

```lean
import Std.Sync.Mutex
...
  let mutex ← Std.Mutex.new ()
  let jobs ← (Array.range 64).mapM fun _ => Job.async do
    let job ← mutex.atomically shared.fetch
    discard job.await
```

The lock only needs to cover `fetch`, which returns a job without waiting for it.
Waiting with `job.await` happens outside the lock. There are two caveats:

- The workaround only protects fetches that go through the same mutex.
- `Std.Mutex` is not reentrant. If a fetch made under the lock synchronously
  waits on another job whose body also takes the lock, the build deadlocks.
  This happens, for example, if the target's `create` calls `await` on a job
  that itself fetches under the mutex.

## Suggested fix

The fix is to make lookup and insert a single atomic operation that inserts a
placeholder before `create` runs, so that only one fetcher creates the job and
every other fetcher waits on the placeholder:

```lean
-- Sketch only, not compiled against Lake.
let promise ← IO.Promise.new                    -- will hold the real job
let placeholder := Job.ofPromise promise        -- task: promise.result >>= (·.task)
let prev? ← storeRef.modifyGet fun s =>         -- one atomic step on the store ref
  match s.get? key with
  | some job => (some job, s)
  | none     => (none, s.insert key placeholder)
match prev? with
| some job => return job                        -- existing job or someone else's placeholder
| none =>
  try
    let job ← create
    promise.resolve job
    return job
  catch e =>
    promise.resolve (failedJob e)               -- waiters must not hang
    throw e
```

Notes:

- `MonadStore1Of`/`MonadDStore` only offer separate `fetch?` and `store`. The
  fix needs an atomic get-or-insert, for example a `fetchOrInsert`/`modifyGet`
  method on `MonadDStore`, which the `StateRefT'` instance can implement with
  one `modifyGet` on the ref.
- A placeholder `Job` needs the job's `kind` and caption, which are normally
  known only after `create`. Two ways around this are to store an indirection
  (the promise) and resolve to the real job, or to derive those fields from the
  key.
- **Errors.** Today, if `create` throws synchronously, nothing is stored, and a
  later fetch tries again. With a placeholder, the placeholder must either be
  resolved to a failed job or be removed. Otherwise anything waiting on it hangs.
- **Cycle detection.** `guardCycle` runs in `recFetchAcyclic` before the store
  lookup and checks the current call stack, and `Job.async` and its relatives
  pass the spawning call stack into the job. A cycle within a single chain of
  fetches is therefore still caught before the placeholder is reached. A cycle
  split across two concurrent fetchers is different. If thread 1 creates `A`,
  which fetches `B`, while thread 2 creates `B`, which fetches `A`, then today
  each thread follows the cycle on its own stack and reports
  `build cycle detected`. With placeholders, each thread gets the other's
  placeholder instead, and the build deadlocks rather than reporting a cycle.
  This happens either through tasks that wait on each other or, if `create`
  uses `await`, through blocked fetch threads. To keep the error, a placeholder
  could record its creator's call stack and be checked against a wait-for
  relation. At minimum, this case should be documented.
- An "insert if absent, otherwise keep the existing job" step after `create`
  makes the store consistent, but it does not prevent the duplicate work,
  because `create` has usually spawned its job already (`Job.async` starts
  immediately). The placeholder has to be inserted before `create`.
- A single global lock around every `fetch` would also fix the race, but it can
  deadlock when a `create` synchronously waits on a job that fetches, as in
  `Module.recFetchPreSetup`'s `extraDepJob.await`.

## Environment

- macOS 26.7.1 (25G241), Apple M5 Max, 18 cores (6 performance + 12 efficiency).
- elan 4.2.4.
- Toolchains tested, all already installed under `~/.elan/toolchains`:

| Toolchain | Lean / Lake version | Reproduces |
|---|---|---|
| `leanprover/lean4:v4.34.1` | Lean 4.34.1, Lake 5.0.0-src+5045d00 | yes, 10/10 builds |
| `leanprover/lean4:v4.35.0` | Lean 4.35.0, Lake 5.0.0-src+eb6cafb | yes, 10/10 builds |
| `leanprover/lean4-nightly:nightly-2026-10-12` | Lean 4.36.0-nightly-2026-10-12 | yes, 10/10 builds |

`Lake/Util/Store.lean`, `Lake/Util/StoreInsts.lean`, `Lake/Build/Index.lean`,
`Lake/Build/Topological.lean` and `Lake/Build/Fetch.lean` are identical in
v4.34.1 and nightly-2026-10-12.
