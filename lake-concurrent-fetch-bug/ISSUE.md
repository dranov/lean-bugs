<!-- Draft of a leanprover/lean4 issue. Not posted. Title:

Lake: `fetchOrCreate` can create the same build key more than once when fetches run concurrently
-->

### Prerequisites

<!-- Please put an X between the brackets as you perform the following steps: -->

* [x] Check that your issue is not already filed:
      https://github.com/leanprover/lean4/issues
* [x] Reduce the issue to a minimal, self-contained, reproducible test case.
      Avoid dependencies to Mathlib or Batteries.
* [x] Test your test case against the latest nightly release, for example on
      https://live.lean-lang.org/#project=lean-nightly
      (You can also use the settings there to switch to “Lean nightly”)
* [ ] When reporting a perceived soundness bug: Does it affect `lake check --paranoid`?
      If in doubt, please reach out on security@lean-fro.org for responsible disclosure.


### Description

When several running jobs call `fetch` on the same build key at the same time, Lake can run that key's build function, and so its job, more than once in a single `lake build`. `fetchOrCreate` looks the key up and stores the result as two separate steps, with `create` in between, so every fetcher that looks the key up before the first one has stored its job misses and creates its own. Each copy is a separate job: it reruns the target's side effects and is reported and counted separately. In the reproduction below, 64 jobs fetch one target, and that target runs between 2 and 18 times per build on an 18-core machine. Duplicates appear in every run.

This is the same race as cause 2 in #15435, where the fetches come from `bindM` continuations. Here it needs no `needs`, no facets and no sources, only a `fetch` made from inside a running job body.

|     LEAN_NUM_THREADS | `shared` runs per build, 10 builds (v4.34.1) |
|---------------------:|:---------------------------------------------|
|                    2 | 2 1 1 2 1 1 2 2 1 2                          |
|                    4 | 4 3 3 3 3 3 3 4 3 3                          |
| default (18 cores)   | 5 17 17 17 13 18 17 17 17 17                 |


### Context

We want to use `lake` to build workspaces with tens of thousands of targets which are dynamically discovered and ran into this issue while experimenting with it. A target that learns its dependencies only after it starts running has to `fetch` them from inside its job, and many such jobs fetch the same shared key at about the same time.

### Steps to Reproduce

🤖 Details and `repro.sh` reproduction script [here](https://github.com/dranov/lean-bugs/tree/main/lake-concurrent-fetch-bug). The `lakefile.lean` is below:

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

`shared` has no trace, so every `lake build` runs it again. The number of lines in `.lake/build/shared.log` after one build is the number of times its job ran in that build. You can then run, e.g. `rm -rf .lake && lake build -v dynamic`:

```
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

`lake build static` and `lake build serialised` both report `Build completed successfully (2 jobs).` `./repro.sh` builds each target 10 times from a clean `.lake` and prints the count for each build:

```
dynamic    shared built: 5 17 17 17 13 18 17 17 17 17  (runs with duplicates: 10/10)
serialised shared built: 1 1 1 1 1 1 1 1 1 1  (runs with duplicates: 0/10)
static     shared built: 1 1 1 1 1 1 1 1 1 1  (runs with duplicates: 0/10)
```

**Expected behavior:** within one `lake build`, each build key is created once, and every fetch of that key returns the same job, whether the fetch is made while the job graph is being built or from inside a running job.

**Actual behavior:** the key is created once per fetcher that misses, up to about the number of worker threads.

**Cause:** `Lake/Util/Store.lean`, `fetchOrCreate` (line 47 at v4.34.1):

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

`fetch?` and `store` are each one atomic `modifyGet`/`modify` on the build store's `IO.Ref`, but between a miss and the `store` that follows there is a window: the whole of `create`. Any other thread that looks the key up in that window also misses, runs its own `create`, and stores its own job, and the last writer wins. In the usual case all fetches run on one thread, during the recursive pass that builds the job graph, so lookups and inserts cannot interleave. `Job.async`, `Job.mapM` and `Job.bindM` give the job body the store ref they were spawned with, so a `fetch` inside a job body runs on a pool worker against the shared store.

**Possible fix:** insert a placeholder for the key in the same atomic step as the lookup, before `create` runs, so that only one fetcher creates the job and every other fetcher waits on the placeholder. This needs an atomic get-or-insert on `MonadDStore`, a way to resolve the placeholder to a failed job when `create` throws, and some care for cycle detection: a cycle split across two concurrent fetchers would become a deadlock instead of `build cycle detected`. An "insert if absent" after `create` does not prevent the duplicate work, because `create` has usually spawned its job already.

**Workaround:** serialise the fetches with a mutex shared by every job that fetches (the `serialised` target). The lock only needs to cover `fetch`, not `job.await`. It only protects fetches that go through the same mutex, and `Std.Mutex` is not reentrant, so a fetch under the lock that synchronously waits on a job whose body takes the lock deadlocks.

### Versions

v4.34.1, v4.35.0 and nightly-2026-10-12 (10/10 builds duplicate on each)

macOS 26.7.1 (25G241), arm64-apple-darwin24.6.0, 18 cores

### Impact

Add :+1: to [issues you consider important](https://github.com/leanprover/lean4/issues?q=is%3Aissue+is%3Aopen+sort%3Areactions-%2B1-desc). If others are impacted by this issue, please ask them to add :+1: to it.
