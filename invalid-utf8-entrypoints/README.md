# Invalid UTF-8 is silently replaced by `lean`, but rejected by `lake build`

## Summary

The `lean` CLI accepts a source file containing a raw invalid UTF-8 byte inside
a string literal. It silently replaces that byte with U+FFFD before parsing.
The same file is rejected by `lake build` before elaboration.
`lake env lean` behaves like the direct CLI invocation.

This reproducer has no dependencies beyond Lean and Lake. It uses an ordinary
Lean string literal, with no macros, custom elaborators, or external tools.

## Expected vs actual

Expected: consistent handling of invalid source encoding across compilation
entry points. If the CLI deliberately recovers by replacing invalid bytes,
it should report the replacement rather than silently compile changed input.

Actual on Lean 4.34.1:

| Command | Result | Exit |
| --- | --- | --- |
| `lean out/Repro.lean` | Prints `#[239, 191, 189]`, without a warning | 0 |
| `lake env lean out/Repro.lean` | Prints the same replacement bytes, without a warning | 0 |
| `lean -o out/Repro.olean out/Repro.lean` | Prints the replacement bytes and produces an `.olean` | 0 |
| `lake build Repro` | Rejects the file as non-UTF-8 | 1 |
| `lean out/Valid.lean` | Prints `#[195, 169]` | 0 |
| `lake build Valid` | Prints `#[195, 169]` and builds successfully | 0 |

The raw `FF` byte is invalid UTF-8. U+FFFD is valid UTF-8 encoded as
`EF BF BD`, or decimal `[239, 191, 189]`.
The control contains `C3 A9`, valid UTF-8 for `é`.

## Reproduction

```sh
./repro.sh
./repro.sh leanprover/lean4:v4.34.1
```

Requires Bash and an elan installation with the selected toolchain available.
The default toolchain is pinned in `lean-toolchain`.
Other toolchains can be selected with the argument; only v4.34.1 has been tested.

The script writes the two source files as bytes:

```sh
mkdir -p out
printf 'module\n\n#eval "\377".toUTF8.data\n' > out/Repro.lean
printf 'module\n\n#eval "\303\251".toUTF8.data\n' > out/Valid.lean
```

This avoids relying on an editor or issue tracker to preserve an invalid byte.
In readable form, the failing file is:

```lean
module

#eval "<raw byte FF>".toUTF8.data
```

The angle-bracket annotation is explanatory text, not the file contents.

The script prints every command, its output, and its exit status.
It saves logs and generated sources under `out/`.
It checks the byte arrays, the absence of diagnostics from the three direct
Lean invocations, the `.olean` output, the specific Lake rejection, and the
valid UTF-8 control. Exit 0 means the reported discrepancy reproduced.

The relevant Lake error is:

```text
error: Tried to read file '…/out/Repro.lean' containing non UTF-8 data.
```

## Root cause

Links are pinned to Lean 4.34.1, commit
`5045d0056413266e57c625dcd7c365b10e377c52`.

[Lean's CLI loader](https://github.com/leanprover/lean4/blob/5045d0056413266e57c625dcd7c365b10e377c52/src/Lean/Shell.lean#L514-L519)
reads the source with `IO.FS.readBinFile` and passes the bytes through
`decodeLossyUTF8` before invoking the frontend.
The decoder explicitly documents replacement of invalid sequences with U+FFFD.
The loader does not issue a diagnostic for that replacement.

[Lake's module input reader](https://github.com/leanprover/lean4/blob/5045d0056413266e57c625dcd7c365b10e377c52/src/lake/Lake/Build/Module.lean#L29-L35)
instead uses `IO.FS.readFile` to read the module before parsing its imports.
That API rejects invalid UTF-8, so Lake never invokes Lean on the failing file.
`lake env` runs the supplied command without this module input check.

## Why it matters

The compiler can successfully produce an `.olean` from silently changed source.
An elaborator that embeds another language sees the replacement text and cannot
distinguish it from a genuinely authored U+FFFD character.
Rejecting the same file during a normal Lake build makes the outcome depend on
the entry point used to compile it.

## Suggested resolution

Align the source-encoding policy across the CLI and Lake.
If lossy recovery remains available for diagnostics or interactive use,
report decoding errors and make successful batch compilation require valid
source encoding. This report does not propose supporting invalid bytes inside
Lean strings.

## Environment

- x86-64 Linux.
- Lean 4.34.1, commit `5045d0056413266e57c625dcd7c365b10e377c52`.
- Lake 5.0.0-src+5045d00.
- No external Lean packages or andProof dependency.
