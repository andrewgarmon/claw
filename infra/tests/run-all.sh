#!/usr/bin/env bash
# Run every infra test (infra/brokers/*/test.sh and infra/tests/*.test.sh) in parallel, then print
# each one's output in order with how long it took. Exit 1 if any failed. CI runs this; so can you.
# Each test fakes what it needs in its own temp dir, so they don't share state.
# usage: infra/tests/run-all.sh [-j N]    (default N: the number of CPUs)
# On GitHub Actions each test's output is a collapsible group and a failure is an ::error:: line.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
jobs=$(nproc 2>/dev/null || echo 2)
if [ "${1:-}" = -j ]; then jobs=${2:?usage: run-all.sh [-j N]}; fi
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { echo "usage: run-all.sh [-j N]" >&2; exit 2; }
shopt -s nullglob
# brokers first: the calendar test's end-to-end part (CI only) is the slowest, so start it early
tests=(infra/brokers/*/test.sh infra/tests/*.test.sh)
[ ${#tests[@]} -gt 0 ] || { echo "no tests found" >&2; exit 1; }
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT

run_one() {  # run_one <index> <test>: output to $out/<index>.log, "<exit status> <seconds>" to .rc
  local start=$SECONDS rc=0
  bash "$2" > "$out/$1.log" 2>&1 || rc=$?
  echo "$rc $((SECONDS - start))" > "$out/$1.rc"
}

start=$SECONDS running=0
for i in "${!tests[@]}"; do
  if [ "$running" -ge "$jobs" ]; then wait -n; running=$((running - 1)); fi
  run_one "$i" "${tests[$i]}" &
  running=$((running + 1))
done
wait

gha=${GITHUB_ACTIONS:-}
failed=()
for i in "${!tests[@]}"; do
  t=${tests[$i]} rc=1 secs='?'
  [ -s "$out/$i.rc" ] && read -r rc secs < "$out/$i.rc"
  status=ok; [ "$rc" = 0 ] || { status="FAILED (exit $rc)"; failed+=("$t"); }
  if [ "$gha" = true ]; then echo "::group::$t: $status, ${secs}s"; else echo "=== $t: $status, ${secs}s"; fi
  cat "$out/$i.log"
  [ "$gha" = true ] && echo "::endgroup::"
  [ "$rc" = 0 ] || { [ "$gha" = true ] && echo "::error::$t failed"; }
done
echo
echo "${#tests[@]} test files in $((SECONDS - start))s with $jobs at a time"
if [ ${#failed[@]} -gt 0 ]; then
  printf 'FAILED: %s\n' "${failed[@]}"
  exit 1
fi
echo "all passed"
