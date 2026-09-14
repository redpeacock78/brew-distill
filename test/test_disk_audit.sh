#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-disk-test.XXXXXX")

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

DISTILL_DISK_CANDIDATES=
export DISTILL_DISK_CANDIDATES
"$repo_dir/scripts/hvf/disk-audit" "$test_dir" 0 before >/dev/null
jq -e '.snapshot == "before" and .sufficient == true' "$test_dir/disk-before.json" >/dev/null
test -s "$test_dir/disk-before.txt"

if "$repo_dir/scripts/hvf/disk-audit" "$test_dir" 999999 after >/dev/null 2>&1; then
  printf '%s\n' "disk-audit accepted insufficient disk" >&2
  exit 1
fi
jq -e '.snapshot == "after" and .sufficient == false' "$test_dir/disk-after.json" >/dev/null

printf '%s\n' "ok"
