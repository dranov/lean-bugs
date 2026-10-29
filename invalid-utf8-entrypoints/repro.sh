#!/usr/bin/env bash
# Usage: ./repro.sh [TOOLCHAIN]
set -euo pipefail
cd "$(dirname "$0")"
toolchain=${1:-$(cat lean-toolchain)}
LEAN=(lean "+$toolchain")
LAKE=(lake "+$toolchain")

mkdir -p out
printf 'module\n\n#eval "\377".toUTF8.data\n' > out/Repro.lean
printf 'module\n\n#eval "\303\251".toUTF8.data\n' > out/Valid.lean

"${LEAN[@]}" --version
"${LAKE[@]}" --version

run() {
  local label=$1 expected=$2 status=0
  shift 2
  printf '\n$'
  printf ' %q' "$@"
  printf '\n'
  "$@" > "out/$label.log" 2>&1 || status=$?
  cat "out/$label.log"
  printf 'exit: %s\n' "$status"
  if [ "$status" -ne "$expected" ]; then
    printf 'Expected exit %s; the recorded behavior did not reproduce.\n' "$expected" >&2
    exit 1
  fi
}

run lean 0 "${LEAN[@]}" out/Repro.lean
run lake-env 0 "${LAKE[@]}" env lean out/Repro.lean
run compile 0 "${LEAN[@]}" -o out/Repro.olean out/Repro.lean
run lake-build 1 "${LAKE[@]}" build Repro
run valid-lean 0 "${LEAN[@]}" out/Valid.lean
run valid-lake 0 "${LAKE[@]}" build Valid

for label in lean lake-env compile; do
  [ "$(< "out/$label.log")" = '#[239, 191, 189]' ]
done
test -s out/Repro.olean
grep -Fq 'containing non UTF-8 data' out/lake-build.log
[ "$(< out/valid-lean.log)" = '#[195, 169]' ]
grep -Fq '#[195, 169]' out/valid-lake.log
printf '\nReproduced: Lean silently replaces FF; Lake build rejects it; valid UTF-8 passes both.\n'
