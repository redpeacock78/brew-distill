#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-bootstrap-test.XXXXXX")

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/Install macOS Test.app/Contents/Resources" "$test_dir/out"
cp "$repo_dir/test/fake-startosinstall" \
  "$test_dir/Install macOS Test.app/Contents/Resources/startosinstall"
chmod 755 "$test_dir/Install macOS Test.app/Contents/Resources/startosinstall"

if DISTILL_GUEST=0 "$repo_dir/scripts/hvf/bootstrap-guest" \
  "$test_dir/Install macOS Test.app" "$test_dir/out" >/dev/null 2>&1; then
  printf '%s\n' "bootstrap-guest ignored the guest guard" >&2
  exit 1
fi

DISTILL_GUEST=1 STARTOSINSTALL_LOG="$test_dir/startosinstall.log" \
  "$repo_dir/scripts/hvf/bootstrap-guest" \
  "$test_dir/Install macOS Test.app" "$test_dir/out"
grep -Fqx -- '--agreetolicense' "$test_dir/startosinstall.log"

printf '%s\n' "ok"
