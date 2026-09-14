#!/bin/sh
set -eu

export LC_ALL=C

repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-release-test.XXXXXX")

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/input"
printf '%s\n' "fixture bottle" > "$test_dir/input/dummy--1.0.ventura.bottle.tar.gz"
printf '%s\n' "private VM image" > "$test_dir/input/base.qcow2"
bottle_sha=$(shasum -a 256 "$test_dir/input/dummy--1.0.ventura.bottle.tar.gz" | awk '{print $1}')
printf '%s\n' '{}' > "$test_dir/input/dummy--1.0.ventura.bottle.json"
jq -n --arg sha "$bottle_sha" \
  '{schema:4,formula:{name:"dummy",version:"1.0",revision:0,formula_sha256:("d" * 64)},platform:{os:"macos",version:"13",arch:"x86_64",bottle_tag:"ventura"},builder:{provider:"test",backend:"native"},dependencies:{fingerprint:("e" * 64)},toolchain:{fingerprint:("f" * 64)},network:{artifact_domain:false,fallback:true},artifact:{path:"dummy--1.0.ventura.bottle.tar.gz",sha256:$sha}}' \
  > "$test_dir/input/dummy--1.0.ventura.bottle.manifest.json"

"$repo_dir/scripts/package-release" "$test_dir/input" "$test_dir/release" run-1 2
release_dir="$test_dir/release/distill-build-run-1-2"
test -s "$release_dir/manifest.json"
test -s "$release_dir/checksums.txt"
test -s "$release_dir/metadata.tar.gz"
(cd "$release_dir" && shasum -a 256 -c checksums.txt >/dev/null)
if find "$release_dir" -type f \( -name '*.qcow2' -o -name '*.img' -o -name '*.raw' \) -print | grep -q .; then
  printf '%s\n' 'package-release exported a VM image' >&2
  exit 1
fi
jq -e '.schema == 4 and .release == "distill-build-run-1-2" and (.bottles | length == 1)' \
  "$release_dir/manifest.json" >/dev/null

printf '%s\n' "ok"
