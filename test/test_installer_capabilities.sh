#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-installer-test.XXXXXX")

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/Install macOS Test.app/Contents/Resources" "$test_dir/out"
cp "$repo_dir/test/fake-startosinstall" \
  "$test_dir/Install macOS Test.app/Contents/Resources/startosinstall"
chmod 755 "$test_dir/Install macOS Test.app/Contents/Resources/startosinstall"

"$repo_dir/scripts/hvf/installer-capabilities" \
  "$test_dir/Install macOS Test.app" "$test_dir/out" >/dev/null
jq -e '.usage_status == 0 and .options.agreetolicense == true and .options.nointeraction == true and .options.volume == false and .options.newvolumename == true and .options.rebootdelay == true and .options.pidtosignal == true' \
  "$test_dir/out/installer-capabilities.json" >/dev/null
grep -Fq -- '--eraseinstall,' "$test_dir/out/startosinstall-usage.txt"

printf '%s\n' "ok"
