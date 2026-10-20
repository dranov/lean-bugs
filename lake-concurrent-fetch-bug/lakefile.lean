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
