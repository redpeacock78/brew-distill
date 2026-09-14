#!/bin/sh
set -eu

unset CDPATH
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-native-test.XXXXXX")

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/bin" "$test_dir/out" "$test_dir/prefix"
cp "$repo_dir/test/fake-brew" "$test_dir/bin/brew"
chmod 755 "$test_dir/bin/brew"
mkdir -p "$test_dir/prefix/bin"
cat > "$test_dir/prefix/bin/csound" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$CSOUND_LOG"
output=
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then output=$2; shift 2; else shift; fi
done
test -n "$output"
printf '%s\n' smoke > "$output"
EOF
chmod 755 "$test_dir/prefix/bin/csound"

if PATH="$test_dir/bin:$PATH" DISTILL_RELEASE_BUILD=1 \
  "$repo_dir/scripts/native-build" dummy "$test_dir/out" >/dev/null 2>&1; then
  printf '%s\n' "native-build accepted a non-strict release environment" >&2
  exit 1
fi

PATH="$test_dir/bin:$PATH" \
BREW_LOG="$test_dir/brew.log" \
FAKE_PREFIX="$test_dir/prefix" \
  "$repo_dir/scripts/native-build" dummy "$test_dir/out"

test -s "$test_dir/out/dummy--1.0.ventura.bottle.tar.gz"
test -s "$test_dir/out/dummy--1.0.ventura.bottle.json"
jq -e '.schema == 4 and .formula.name == "dummy" and (.artifact.sha256 | length == 64)' \
  "$test_dir/out/dummy--1.0.ventura.bottle.manifest.json" >/dev/null

grep -Fqx -- 'install --build-bottle --formula dummy' "$test_dir/brew.log"
grep -Fqx -- 'test dummy' "$test_dir/brew.log"
grep -Fqx -- 'linkage --test dummy' "$test_dir/brew.log"
grep -Fqx -- 'bottle --json dummy' "$test_dir/brew.log"

PATH="$test_dir/bin:$PATH" \
BREW_LOG="$test_dir/csound-brew.log" \
CSOUND_LOG="$test_dir/csound.log" \
FAKE_PREFIX="$test_dir/prefix" \
FAKE_FORMULA=csound \
FAKE_BOTTLE_REBUILD=1 \
  "$repo_dir/scripts/native-build" csound "$test_dir/csound-out" >/dev/null
test -s "$test_dir/csound-out/csound--1.0.ventura.bottle.1.tar.gz"
test -s "$test_dir/csound-out/csound--1.0.ventura.bottle.json"
test -s "$test_dir/csound-out/csound.smoke.wav"
test -s "$test_dir/csound.log"

printf '%s\n' "ok"
