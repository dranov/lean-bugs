# Lake deadlocks on a build cycle that closes inside running jobs

## Summary

Lake detects build cycles by checking whether a key is already on the call
stack of the current recursive fetch (`guardCycle`). If a job fetches another
target from inside its body (a dependency it only discovers while running) and
that target's job already exists in the build store, the fetch returns the
existing job without any cycle check that could see the whole loop. When two
or more such jobs wait for each other, `lake build` hangs forever, using no
CPU, instead of failing with `build cycle detected`. The same cycle expressed
as ordinary dependencies, fetched while the job graph is built, is reported
correctly. Reproduced with Lean v4.34.1, v4.35.0 and nightly-2026-10-12.

## Expected vs actual

`lakefile.lean` declares two custom targets. The job of `dynA` fetches `dynB`
and waits for it; the job of `dynB` fetches `dynA` and waits for it:

```lean
target dynA pkg : Unit := Job.async do
  IO.sleep 1000
  discard (← fetchNamed pkg `dynB).wait

target dynB pkg : Unit := Job.async do
  IO.sleep 1000
  discard (← fetchNamed pkg `dynA).wait
```

(`fetchNamed` fetches a target of the package by name; `IO.sleep` is explained
below.)

- Expected: `lake build dynA dynB` fails with `build cycle detected`, as it
  does for the control targets `staticA`/`staticB`, which fetch each other
  outside the job body.
- Actual: `lake build dynA dynB` prints nothing and never terminates. The
  process sits at 0% CPU until it is killed.

## Reproduction

Requirements: elan, and the toolchain in `lean-toolchain`
(`leanprover/lean4:v4.34.1`) or any other installed toolchain.

```sh
./repro.sh                                         # toolchain from lean-toolchain
./repro.sh leanprover/lean4:v4.35.0                # any installed toolchain
./repro.sh leanprover/lean4-nightly:nightly-2026-10-12
LIMIT=60 ./repro.sh                                # longer time limit (default 20 s)
```

The script deletes `.lake`, loads the lakefile once, then runs one
`lake build` per case under a time limit, kills any build that exceeds it, and
classifies the outcome as `deadlock (timed out)`, `cycle reported`, `built`,
or another failure. It exits with 0 if every case reported the cycle and 1
otherwise. It needs only POSIX `sh` (no `timeout` binary).

The direct commands, if you prefer (use your own time limit):

```sh
lake build staticA staticB    # control: reports the cycle
lake build dynA dynB          # bug: hangs
```

Output on v4.34.1 (identical on v4.35.0 and nightly-2026-10-12 apart from the
version line):

```
Lake version 5.0.0-src+5045d00 (Lean version 4.34.1)

bug      lake build dynA dynB
         -> deadlock (timed out after 20s)

control  lake build staticA staticB
         -> cycle reported
         | ✖ [1/2] Running «cycle-deadlock»/staticB
         | error: build cycle detected:
         |   «cycle-deadlock»/staticA
         |   «cycle-deadlock»/staticB
         |   «cycle-deadlock»/staticA
         | Some required targets logged failures:
         | - «cycle-deadlock»/staticB
         | error: build failed

one-root lake build dynA
         -> cycle reported
         | ✖ [2/2] Running «cycle-deadlock»/dynB
         | error: build cycle detected:
         |   «cycle-deadlock»/dynA
         |   «cycle-deadlock»/dynB
         |   «cycle-deadlock»/dynA
         | Some required targets logged failures:
         | - «cycle-deadlock»/dynB
         | error: build failed

self     lake build self
         -> cycle reported
         | ✖ [1/1] Running «cycle-deadlock»/self
         | error: build cycle detected:
         |   «cycle-deadlock»/self
         |   «cycle-deadlock»/self
         | Some required targets logged failures:
         | - «cycle-deadlock»/self
         | error: build failed

three    lake build tri1 tri2 tri3
         -> deadlock (timed out after 20s)
```

The cases:

| Case | Command | Cycle | Result |
| --- | --- | --- | --- |
| bug | `lake build dynA dynB` | dynA → dynB → dynA, fetched in job bodies, both jobs created by the CLI | hangs |
| control | `lake build staticA staticB` | same cycle, fetched outside job bodies | reported |
| one-root | `lake build dynA` | same as bug, but dynB's job is created from inside dynA's job | reported |
| self | `lake build self` | a job fetches its own target | reported |
| three | `lake build tri1 tri2 tri3` | tri1 → tri2 → tri3 → tri1, fetched in job bodies | hangs |

`lake build tri1 tri2` (two of the three roots) also hangs: one store hit on
a job created along a different path is enough.

The `IO.sleep 1000` in the dynamic targets only orders events: it lets
`lake build dynA dynB` create both jobs before either body fetches the other.
Without it, `dynA`'s body fetched `dynB` first in 8 of 8 runs, `dynB`'s job is then
created from inside `dynA`'s job, and the cycle is reported, as in the
one-root case. The deadlock does not depend on the sleep's length; the hang
was observed in every run (with time limits of 8 s to 60 s).

## Root cause

Code references are to tag `v4.34.1` (commit `5045d0056413`); the files below
are unchanged in `v4.35.0` and on `master` as of 2026-10-12 (`caf3cb08d091`),
except for an unrelated cancellation change in `Job/Monad.lean` and a
one-line change to module targets in `CLI/Build.lean`.

- `src/lake/Lake/Util/Cycle.lean`, `guardCycle` (line 79): throws if the key
  is already on the current call stack, otherwise pushes it.
- `src/lake/Lake/Build/Topological.lean`, `recFetchAcyclic` (line 94): wraps
  every fetch in `guardCycle`.
- `src/lake/Lake/Build/Index.lean`, `recBuildWithIndex` (line 29): for a
  target, calls `fetchOrCreate key` (`src/lake/Lake/Util/Store.lean`, line 47),
  which returns the job already in the build store if there is one, and
  otherwise runs the target's fetch function and stores the new job.
- `src/lake/Lake/Build/Job/Monad.lean`, `Job.async` (line 169): the job body
  runs with the call stack captured when the job was spawned, that is, the
  stack of the fetch that created the job, ending in the job's own key.

So the call stack seen inside a job body is the path along which that job was
*created*. For `lake build dynA dynB`, `buildSpecs`
(`src/lake/Lake/CLI/Build.lean`, line 54) fetches the two targets one after
the other from the same top-level fetch:

1. Fetch `dynA` with stack `[]`. `guardCycle` pushes `dynA`; the job is
   spawned with stack `[dynA]` and stored.
2. Fetch `dynB` with stack `[]`. The job is spawned with stack `[dynB]` and
   stored.
3. `dynA`'s body fetches `dynB` with stack `[dynA]`. `dynB` is not on that
   stack, so `guardCycle` passes; `fetchOrCreate` returns the stored `dynB`
   job, and `dynA` blocks waiting for it.
4. `dynB`'s body fetches `dynA` with stack `[dynB]`. Again no cycle on the
   stack; it gets the stored `dynA` job and blocks.

Neither job can finish, so the top-level job never finishes and Lake waits
for it forever.

A call-stack check only sees a cycle that lies on a single creation path. The
build store records which job exists for each key, but not who fetched or is
waiting for it. When a fetch returns an existing job, the edge "current key
depends on that key" is never compared against what that job itself depends
on, so a cycle that closes through an already-created job is invisible. The
other cases follow from this:

- self: the body runs with its own key on the stack, so fetching itself is
  caught.
- one-root: `dynB`'s job is created by the fetch in `dynA`'s body, so its
  body runs with stack `[dynB, dynA]` and its fetch of `dynA` is caught.
- control: static fetches happen inside the creating fetch, before the job is
  stored, so every edge of a static cycle is on one call stack. For a purely
  static graph `guardCycle` is complete; only fetches made after a job was
  stored, which in practice means from a running job, can close a cycle
  through a store hit.

## Why it matters

Lake supports fetching from inside running jobs: `JobM` is a `FetchT`, so a
job body can call `fetch`, and Lake's own facets do so (for example
`Module.computeExportInfo` in `Lake/Build/Module.lean` fetches and awaits
jobs inside a `mapM` continuation). This is the natural way to express
dependencies that are only known once a job has started. An example is a code
generator in which each unit is a Lake job that learns which other units it
uses only while processing its input; it fetches those units' jobs and waits
for them. Mutually dependent units are a user error that should produce a
clear message.

A hang is much worse than an error. The build prints nothing, consumes no
CPU, and gives no indication of which targets are involved, so it looks like
a slow build. In CI it costs the whole job time limit. Locally a user has to
notice, kill the process, and guess the cause.

## Workaround

Code that fetches from inside job bodies can keep its own waits-for map and
check it before blocking. Each job body knows its own key (for example
`BuildKey.packageTarget pkg.keyName name`). Keep a process-wide map from a
key to the key its job is currently blocked on, protected by a mutex:

```lean
-- Sketch, not tested as written.
-- waitsFor : IO.Ref (Std.HashMap BuildKey BuildKey), guarded by a mutex
def awaitDep (self dep : BuildKey) (job : Job α) : JobM (JobResult α) := do
  withMutex do                                -- check and insert atomically
    if dep == self then error s!"build cycle detected: {[self, self]}"
    let mut k := dep
    let mut path := #[self, dep]
    while let some k' := (← waitsFor.get)[k]? do -- follow the chain of waits
      if k' == self then error s!"build cycle detected: {path.push self}"
      path := path.push k'; k := k'
    waitsFor.modify (·.insert self dep)
  try job.wait finally withMutex (waitsFor.modify (·.erase self))
```

Each job waits for at most one other job at a time, so the waits-for graph
is a set of chains, and following one chain is enough. Because the check and
the insert are atomic, the last wait that would close a loop always sees it,
and that job fails with an error instead of blocking. Its failure releases
the job waiting on it, and so on around the loop, so the build terminates.

## Suggested fix

Track dependency edges in the build store rather than relying only on the
call stack. Two options:

1. Record fetch edges. Every fetch already knows its parent (the head of the
   call stack in `recFetchAcyclic`). Record the edge parent → fetched key in
   the store. When `fetchOrCreate` returns an existing job, check whether the
   parent is reachable from the fetched key through recorded edges, and if
   so throw the existing `build cycle detected` error with that path. Edges
   out of finished jobs can be dropped, since a finished job cannot be part
   of a hang. This keeps the existing meaning (a fetch is a dependency, as in
   the static control) and needs no change to how jobs wait.
2. Record waits. For each in-progress key, record which key it is blocked
   on, set by a `JobM`-level wait on a fetched job and cleared when the wait
   returns, and report a cycle when a new wait would close a loop (as in the
   workaround above). This is cheaper per fetch, but only covers waits that
   go through the new API, not a raw `Job.wait`.

In both cases the check and the update must be atomic with respect to other
jobs, since the fetches that close the cycle run concurrently.

## Environment

- macOS 26.7.1 (build 25G241), arm64, Apple M5 Max, 18 CPUs (`hw.ncpu`).
- elan-managed toolchains, each tested with `./repro.sh <toolchain>`:

| Toolchain | Lake | Reproduces |
| --- | --- | --- |
| leanprover/lean4:v4.34.1 | 5.0.0-src+5045d00 | yes (bug and three hang; control, one-root, self report) |
| leanprover/lean4:v4.35.0 | 5.0.0-src+eb6cafb | yes (same) |
| leanprover/lean4-nightly:nightly-2026-10-12 (commit db7f10e90a71) | 5.0.0-src | yes (same) |

## Files

- `lakefile.lean`: the targets for every case.
- `repro.sh`: runs every case under a time limit and classifies the outcome.
- `lean-toolchain`: pinned to `leanprover/lean4:v4.34.1`.
