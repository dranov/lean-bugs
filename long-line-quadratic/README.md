# Parsing `.lean` and writing `.ilean` are quadratic in line length

Filed as [leanprover/lean4#15646](https://github.com/leanprover/lean4/issues/15646).

## Summary

For a large term on a single `.lean` source line, both parsing it and writing
the `.ilean` reference index (`lean -i`, which `lake build` always passes) take
time quadratic in the line's length. The same term with line breaks takes
linear time. Reproduced on v4.34.1 and nightly-2026-10-12.

We generate large terms (hundreds of KB) programmatically. For a ~500 KB term,
writing the `.ilean` took about 150 s when the term was on one line and a few
seconds when it had line breaks.

## Expected vs actual

Expected: both files take about the same time, roughly linear in the input
size, however the source is split into lines.

Actual: the one-line file is quadratic, about 4× per doubling of N. Wall
seconds on nightly-2026-10-12:

| N | line bytes | one line | one line `-i` | multi-line | multi-line `-i` |
|--:|--:|--:|--:|--:|--:|
| 4000 | 125,834 | 6.5 | 12.6 | 1.4 | 1.4 |
| 8000 | 253,834 | 23.2 | 48.8 | 3.4 | 3.3 |
| 16000 | 521,836 | 90.4 | 197.9 | 7.4 | 7.6 |

Results are the same on v4.34.1 (N = 16000: 82.2 / 188.8 / 8.2 / 8.5).

## Reproduction

`repro.sh` writes two files for each N, `out/N/OneLine.lean` and
`out/N/MultiLine.lean`. They differ only in line breaks:

```lean
set_option maxRecDepth 100000

structure Foo where
  x : Nat
  y : Nat

def big : List Foo := [{ x := id 0, y := id 0 }, { x := id 1, y := id 1 }, ...]
```

In `OneLine.lean` the whole list is on one line. In `MultiLine.lean` there is
one element per line. The script then times `lean FILE` and
`lean FILE -i FILE.ilean` on each file:

```sh
./repro.sh                               # toolchain from lean-toolchain
./repro.sh leanprover/lean4:v4.34.1      # another elan toolchain
SIZES="4000 8000 16000" ./repro.sh       # the sizes in the table above
```

The default sizes (2000, 4000, 8000) run in about two minutes. The
N = 16000 row alone takes about five minutes.

The structure instances are needed for the parsing half. `[...]` parses its
elements `withoutPosition`, so a plain list of applications such as
`[Foo.mk 0 0, ...]` has no saved position. The indentation checks then return
immediately. A file like that shows only the `.ilean` half.

## Root cause

Links are to `db7f10e90a` (nightly-2026-10-12).

[`FileMap.toPosition`](https://github.com/leanprover/lean4/blob/db7f10e90a71899cfd531a040360b1365f5fd92f/src/Lean/Data/Position.lean#L74-L80)
finds a position's line by binary search, then counts codepoints from the start
of the line
([`toColumn`](https://github.com/leanprover/lean4/blob/db7f10e90a71899cfd531a040360b1365f5fd92f/src/Lean/Data/Position.lean#L78-L80)).
[`FileMap.leanPosToLspPos`](https://github.com/leanprover/lean4/blob/db7f10e90a71899cfd531a040360b1365f5fd92f/src/Lean/Data/Lsp/Utf16.lean#L87-L89)
then walks the line from its start again to get the UTF-16 offset
([`codepointPosToUtf16PosFromAux`](https://github.com/leanprover/lean4/blob/db7f10e90a71899cfd531a040360b1365f5fd92f/src/Lean/Data/Lsp/Utf16.lean#L37-L39)).
So each call costs time linear in the column. Two hot paths call these once per
syntax element:

- **Parsing:**
  [`checkColEqFn`](https://github.com/leanprover/lean4/blob/db7f10e90a71899cfd531a040360b1365f5fd92f/src/Lean/Parser/Basic.lean#L1479-L1486),
  [`checkColGeFn`](https://github.com/leanprover/lean4/blob/db7f10e90a71899cfd531a040360b1365f5fd92f/src/Lean/Parser/Basic.lean#L1496-L1503)
  and
  [`checkColGtFn`](https://github.com/leanprover/lean4/blob/db7f10e90a71899cfd531a040360b1365f5fd92f/src/Lean/Parser/Basic.lean#L1516-L1523)
  call `toPosition` on both the current and the saved position. They run
  before every function-application argument (via
  [`argument`](https://github.com/leanprover/lean4/blob/db7f10e90a71899cfd531a040360b1365f5fd92f/src/Lean/Parser/Term.lean#L1021-L1024))
  and for the fields of structure instances.
- **`.ilean`:**
  [`runFrontend`](https://github.com/leanprover/lean4/blob/db7f10e90a71899cfd531a040360b1365f5fd92f/src/Lean/Elab/Frontend.lean#L394-L396)
  →
  [`findReferences`](https://github.com/leanprover/lean4/blob/db7f10e90a71899cfd531a040360b1365f5fd92f/src/Lean/Server/References.lean#L260-L271)
  →
  [`Syntax.Range.toLspRange`](https://github.com/leanprover/lean4/blob/db7f10e90a71899cfd531a040360b1365f5fd92f/src/Lean/Server/Utils.lean#L212-L213)
  →
  [`utf8PosToLspPos`](https://github.com/leanprover/lean4/blob/db7f10e90a71899cfd531a040360b1365f5fd92f/src/Lean/Data/Lsp/Utf16.lean#L91-L92)
  converts both ends of every reference.

A `sample` profile (macOS) of the slow runs is almost entirely
`FileMap.toPosition.toColumn`, `lean_string_utf8_next` and
`codepointPosToUtf16PosFromAux`, called from the functions above.

## Workaround

Emit generated terms with line breaks. Lines of a few hundred bytes are enough.

## Environment

- macOS 26, Apple M5 Max (arm64).
- Lean 4.36.0-nightly-2026-10-12 (`db7f10e90a`) and Lean 4.34.1 (`5045d005`).
