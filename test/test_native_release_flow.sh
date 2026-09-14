#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-native-release-flow-test.XXXXXX")
test_dir=$(cd "$test_dir" && pwd)

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/bin" "$test_dir/prefix/bin"
cp "$repo_dir/test/fake-brew" "$test_dir/bin/brew"
chmod 755 "$test_dir/bin/brew"
export BREW_LOG="$test_dir/brew.log"

(
  cd "$test_dir"
  PATH="$test_dir/bin:$PATH" \
  FAKE_BOTTLE_REBUILD=1 \
  DISTILL_RELEASE_BUILD=1 \
  HOMEBREW_ARTIFACT_DOMAIN=https://artifacts.example.invalid \
  HOMEBREW_ARTIFACT_DOMAIN_NO_FALLBACK=1 \
    "$repo_dir/scripts/native-build" dummy out >/dev/null
  PATH="$test_dir/bin:$PATH" \
    "$repo_dir/scripts/package-release" out release run-1 1 >/dev/null
)

release_dir="$test_dir/release/distill-build-run-1-1"
bottle="$release_dir/dummy--1.0.ventura.bottle.1.tar.gz"
checksums="$release_dir/checksums.txt"
expected=$(awk -v file="$(basename "$bottle")" '$2 == file { print $1; exit }' "$checksums")
test -n "$expected"
test -s "$release_dir/manifest.json"
test -s "$release_dir/metadata.tar.gz"

PATH="$test_dir/bin:$PATH" \
DISTILL_RELEASE_BUILD=1 \
HOMEBREW_ARTIFACT_DOMAIN=https://artifacts.example.invalid \
HOMEBREW_ARTIFACT_DOMAIN_NO_FALLBACK=1 \
FAKE_INSTALLED_STATE="$test_dir/verify-installed" \
  "$repo_dir/scripts/native-verify" dummy "$bottle" "$expected" "$test_dir/verify" >/dev/null
test -s "$test_dir/verify/native-verification.txt"
test -s "$test_dir/verify-installed"

printf '%s\n' ok
