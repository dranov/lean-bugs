<!-- Draft of a leanprover/lean4 issue. Not posted. Title:

`lean` silently replaces invalid UTF-8 in source files with U+FFFD, while `lake build` rejects the same file
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

The `lean` command line reads a source file as bytes and decodes it with `decodeLossyUTF8`, which replaces every invalid sequence with U+FFFD, and it does so without any diagnostic. A file containing a raw `0xFF` byte inside a string literal therefore compiles successfully, and the resulting `.olean` contains the replacement character `EF BF BD` instead of what is on disk. Lake reads the same file with `IO.FS.readFile` before parsing its imports, which rejects invalid UTF-8, so `lake build` fails on it with `Tried to read file '…' containing non UTF-8 data`. Whether a file with a source-encoding error compiles depends on the entry point: `lean`, `lean -o` and `lake env lean` accept it, `lake build` does not.

| Command                                  | Result                                                     | Exit |
| ---------------------------------------- | ---------------------------------------------------------- | ---: |
| `lean Repro.lean`                        | prints `#[239, 191, 189]`, no warning                      |    0 |
| `lake env lean Repro.lean`               | same                                                       |    0 |
| `lean -o Repro.olean Repro.lean`         | same, and writes an `.olean`                               |    0 |
| `lake build Repro`                       | `Tried to read file '…/Repro.lean' containing non UTF-8 data.` |    1 |
| `lean Valid.lean` / `lake build Valid`   | control with valid UTF-8 `é`: prints `#[195, 169]`         |    0 |


### Context

We want to use `lake` to build workspaces with tens of thousands of targets and ran into this while comparing what different entry points do with the same sources. Our elaborators embed other languages in Lean string literals and compile them to `.olean` files. An elaborator sees the replacement text and cannot tell it from an author-typed U+FFFD, so the `.olean` can silently describe different input than the file on disk.


### Steps to Reproduce

🤖 Details and `repro.sh` reproduction script [here](https://github.com/dranov/lean-bugs/tree/main/invalid-utf8-entrypoints). The script writes the two source files as bytes, so no editor or issue tracker has to preserve the invalid byte:

```sh
printf 'module\n\n#eval "\377".toUTF8.data\n' > Repro.lean
printf 'module\n\n#eval "\303\251".toUTF8.data\n' > Valid.lean
```

In readable form, `Repro.lean` is

```lean
module

#eval "<raw byte FF>".toUTF8.data
```

where the annotation stands for the single byte `0xFF`; it is not file contents. Lake only needs a `lean_lib` for each file:

```lean
import Lake
open Lake DSL

package utf8_repro

lean_lib Repro where
  srcDir := "out"

lean_lib Valid where
  srcDir := "out"
```

`lean out/Repro.lean` prints `#[239, 191, 189]` and exits 0. `lake build Repro` fails:

```
✖ [0/3] Running job computation
error: Repro: some modules have bad imports or could not be read
✖ [2/3] Running Repro
error: Tried to read file '…/out/Repro.lean' containing non UTF-8 data.
Some required targets logged failures:
- job computation
- Repro
error: build failed
```

`./repro.sh` runs all six commands, prints each with its exit status, and exits 0 only if this discrepancy reproduces.

**Expected behavior:** consistent handling of invalid source encoding across entry points. If the CLI deliberately recovers by replacing invalid bytes, it reports the replacement rather than silently compiling changed input.

**Actual behavior:** `lean` compiles the file and produces an `.olean`; `lake build` rejects it.

**Cause:** [`Lean.Shell`](https://github.com/leanprover/lean4/blob/5045d0056413266e57c625dcd7c365b10e377c52/src/Lean/Shell.lean#L514-L519) reads the source with `IO.FS.readBinFile` and passes it through `decodeLossyUTF8`, documented to replace invalid sequences with U+FFFD, and issues no diagnostic. [Lake's module input reader](https://github.com/leanprover/lean4/blob/5045d0056413266e57c625dcd7c365b10e377c52/src/lake/Lake/Build/Module.lean#L29-L35) uses `IO.FS.readFile`, which fails on invalid UTF-8, so Lake never invokes `lean` on the file. `lake env` runs the given command without this check.

**Possible fix:** align the policy. If lossy decoding stays for interactive or diagnostic use, have the frontend log an error (or at least a warning) at the first invalid byte, and make batch compilation, in particular `lean -o`, fail on invalid source encoding. This does not propose supporting invalid bytes inside Lean strings.


### Versions

v4.34.1, v4.35.0 and nightly-2026-10-27 (the same on each)

macOS 26.7.1 (25G241), arm64-apple-darwin24.6.0 (also observed on x86-64 Linux with v4.34.1)

### Impact

Add :+1: to [issues you consider important](https://github.com/leanprover/lean4/issues?q=is%3Aissue+is%3Aopen+sort%3Areactions-%2B1-desc). If others are impacted by this issue, please ask them to add :+1: to it.
