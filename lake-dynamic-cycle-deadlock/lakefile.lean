import Lake
open Lake DSL

package «cycle-deadlock»

/-- Fetch a target of this package by name. The result type is ignored. -/
def fetchNamed (pkg : Package) (name : Lean.Name) : FetchM OpaqueJob := do
  let info := pkg.target name
  have : FamilyOut BuildData info.key (BuildData info.key) := ⟨rfl⟩
  return (← info.fetch).toOpaque

/-! ## Bug: `lake build dynA dynB` hangs

Each job learns its dependency only while it runs, fetches it and waits for
it. The sleep only makes sure that `lake build dynA dynB` has created both
jobs before either body fetches the other one. -/

target dynA pkg : Unit := Job.async do
  IO.sleep 1000
  discard (← fetchNamed pkg `dynB).wait

target dynB pkg : Unit := Job.async do
  IO.sleep 1000
  discard (← fetchNamed pkg `dynA).wait

/-! ## Control: `lake build staticA staticB` reports the cycle

The same cycle, but each dependency is fetched while the job graph is
built, outside the job body. -/

target staticA pkg : Unit := do
  return (← fetchNamed pkg `staticB).map fun _ => ()

target staticB pkg : Unit := do
  return (← fetchNamed pkg `staticA).map fun _ => ()

/-! ## Variants -/

/-- A job that fetches and waits for itself (`lake build self`). -/
target self pkg : Unit := Job.async do
  discard (← fetchNamed pkg `self).wait

/-! A three-target cycle (`lake build tri1 tri2 tri3`). -/

target tri1 pkg : Unit := Job.async do
  IO.sleep 1000
  discard (← fetchNamed pkg `tri2).wait

target tri2 pkg : Unit := Job.async do
  IO.sleep 1000
  discard (← fetchNamed pkg `tri3).wait

target tri3 pkg : Unit := Job.async do
  IO.sleep 1000
  discard (← fetchNamed pkg `tri1).wait
