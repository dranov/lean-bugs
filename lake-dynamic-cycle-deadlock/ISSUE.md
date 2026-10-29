<!-- Draft of a leanprover/lean4 issue. Not posted. Title:

Lake: a build cycle that closes inside running jobs hangs instead of reporting `build cycle detected`
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

Lake detects a build cycle by checking whether a key is already on the call stack of the current recursive fetch. When a job fetches another target from inside its body and that target's job already exists, the fetch returns the existing job without a check that can see the whole loop. If two or more such jobs wait for each other, `lake build` hangs forever at 0% CPU instead of failing with `build cycle detected`. The same cycle expressed as ordinary dependencies, fetched while the job graph is built, is reported correctly.

### Context

We want to use `lake` to build workspaces with tens of thousands of targets which are dynamically discovered and ran into this issue. A target that learns its dependencies only after it starts running has to fetch them from inside its job and wait for them. Mutually dependent targets are a user error, which should produce a clear message rather than a build that looks like a slow one.

### Steps to Reproduce

🤖 Details and `repro.sh` reproduction script [here](https://github.com/dranov/lean-bugs/tree/main/lake-dynamic-cycle-deadlock). The `lakefile.lean` is below:

```lean
import Lake
open Lake DSL

package «cycle-deadlock»

/-- Fetch a target of this package by name. The result type is ignored. -/
def fetchNamed (pkg : Package) (name : Lean.Name) : FetchM OpaqueJob := do
  let info := pkg.target name
  have : FamilyOut BuildData info.key (BuildData info.key) := ⟨rfl⟩
  return (← info.fetch).toOpaque

/-- Bug: each job fetches the other target from inside its body and waits for it.
The sleep makes sure both jobs exist before either body fetches the other. -/
target dynA pkg : Unit := Job.async do
  IO.sleep 1000
  discard (← fetchNamed pkg `dynB).wait

target dynB pkg : Unit := Job.async do
  IO.sleep 1000
  discard (← fetchNamed pkg `dynA).wait

/-- Control: the same cycle, fetched while the job graph is built. -/
target staticA pkg : Unit := do
  return (← fetchNamed pkg `staticB).map fun _ => ()

target staticB pkg : Unit := do
  return (← fetchNamed pkg `staticA).map fun _ => ()
```

`lake build staticA staticB` reports the cycle:

```
✖ [1/2] Running «cycle-deadlock»/staticB
error: build cycle detected:
  «cycle-deadlock»/staticA
  «cycle-deadlock»/staticB
  «cycle-deadlock»/staticA
Some required targets logged failures:
- «cycle-deadlock»/staticB
error: build failed
```

`lake build dynA dynB` prints nothing and never terminates. `./repro.sh` runs each case under a time limit (default 20 s) and classifies the outcome:

```
bug      lake build dynA dynB
         -> deadlock (timed out after 20s)

control  lake build staticA staticB
         -> cycle reported

three    lake build tri1 tri2 tri3
         -> deadlock (timed out after 20s)
```

(`three` is the same pattern with a three-target cycle; it is in the linked `lakefile.lean`.) Cycles that close through a job created from inside the running job are still reported: `lake build dynA` alone, and a job that fetches its own target.

**Expected behavior:** `lake build dynA dynB` fails with `build cycle detected`, as it does for `staticA`/`staticB`.

**Actual behavior:** `lake build dynA dynB` hangs.

**Cause:** the edge "current key depends on the fetched key" is never compared against what the fetched job itself depends on, so a cycle that closes through an already-created job is invisible. For a purely static graph the call-stack check is complete; only a fetch made after a job was stored, in practice from a running job, can close a cycle through a store hit.

**Possible fix:** record fetch edges in the build store (parent → fetched key). When a fetch returns an existing job, check whether the parent is reachable from the fetched key and report `build cycle detected` with that path if so. The check and the update must be atomic, since the fetches that close the cycle run concurrently.

### Versions

v4.34.1, v4.35.0 and nightly-2026-10-12 (the same on each)

macOS 26.7.1 (25G241), arm64-apple-darwin24.6.0, 18 cores

### Impact

Add :+1: to [issues you consider important](https://github.com/leanprover/lean4/issues?q=is%3Aissue+is%3Aopen+sort%3Areactions-%2B1-desc). If others are impacted by this issue, please ask them to add :+1: to it.
