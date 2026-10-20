import Lake
open Lake DSL

package collect

/-!
Each target makes `N` trivial input jobs, combines them into one job with a
`Job` collection combinator, waits for the result, and prints how long that
took. Nothing is compiled and no files are written. Environment variables:

* `N` (default 1000): number of input jobs.
* `INPUTS=pending` (default): every input waits on one promise. The collection
  is built while all inputs are still pending, as it is in a real build, and
  then the promise is resolved. `INPUTS=done`: every input has already
  finished when the collection is built.
* `LOGS=1`: every input job carries one log entry (default: no log entries).
* `FAIL=i`: input `i` fails (to compare error results between targets).
-/

def envNat? (var : String) : IO (Option Nat) :=
  return (← IO.getEnv var).bind String.toNat?

/--
Control: the result `Job.collectArray` computes (push each value, merge the job
states left to right, `.error 0` if any input failed), but computed by one fold
in one task once every input task has finished.
-/
def collectArrayLinear (jobs : Array (Job α)) (traceCaption := "<collection>") : Job (Array α) :=
  Job.ofTask <| Task.mapList (sync := true) (tasks := (jobs.map (·.task)).toList) fun rs =>
    let init : JobResult (Array α) := .ok (Array.mkEmpty jobs.size) {trace := .nil traceCaption}
    rs.foldl (init := init) fun
      | .ok a sa, .ok b sb => .ok (a.push b) (sa.merge sb)
      | ra, rb => .error 0 (ra.state.merge rb.state)

def timeCollect (label : String) (collect : Array (Job Nat) → Job α) : FetchM (Job Unit) := do
  let n := (← envNat? "N").getD 1000
  let inputs := (← IO.getEnv "INPUTS").getD "pending"
  let logs := (← IO.getEnv "LOGS") == some "1"
  let fail? ← envNat? "FAIL"
  let gate ← IO.Promise.new
  let jobs := (Array.range n).map fun i =>
    let log := if logs then Log.empty.push (.info s!"input {i}") else {}
    let r : JobResult Nat := if fail? == some i then .error 0 {log} else .ok i {log}
    if inputs == "done" then Job.ofTask (Task.pure r)
    else Job.ofTask <| gate.result!.map (sync := true) fun () => r
  let t0 ← IO.monoNanosNow
  let job ← IO.mkRef (collect jobs) -- builds the collection job here, before `resolve`
  let t1 ← IO.monoNanosNow
  gate.resolve ()
  let r ← (← job.get).wait
  let t2 ← IO.monoNanosNow
  let ok := match r with | .ok .. => "ok" | .error .. => "error"
  IO.println s!"RESULT {label} n={n} inputs={inputs} logs={logs} result={ok} \
    log_entries={r.state.log.size} trace_inputs={r.state.trace.inputs.size} \
    trace_hash={r.state.trace.hash} build_us={(t1 - t0) / 1000} wait_us={(t2 - t1) / 1000}"
  return Job.nil

target collectArray : Unit := timeCollect "collectArray" (Job.collectArray ·)
target mixArray : Unit := timeCollect "mixArray" (Job.mixArray ·)
target mixList : Unit := timeCollect "mixList" fun js => Job.mixList js.toList
target collectList : Unit := timeCollect "collectList" fun js => Job.collectList js.toList
target collectVector : Unit := timeCollect "collectVector" fun js =>
  (Job.collectVector js.toVector).map (·.toArray)
target linear : Unit := timeCollect "linear" (collectArrayLinear ·)
