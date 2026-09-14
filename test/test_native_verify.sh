#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-native-verify-test.XXXXXX")

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/bin" "$test_dir/out" "$test_dir/prefix/bin"
cp "$repo_dir/test/fake-brew" "$test_dir/bin/brew"
chmod 755 "$test_dir/bin/brew"
cat > "$test_dir/prefix/bin/csound" <<'EOF'
#!/bin/sh
set -eu
output=
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then output=$2; shift 2; else shift; fi
done
test -n "$output"
printf '%s\n' smoke > "$output"
EOF
chmod 755 "$test_dir/prefix/bin/csound"
printf '%s\n' bottle > "$test_dir/csound--1.0.ventura.bottle.tar.gz"
sha=$(shasum -a 256 "$test_dir/csound--1.0.ventura.bottle.tar.gz" | awk '{print $1}')

PATH="$test_dir/bin:$PATH" \
BREW_LOG="$test_dir/brew.log" \
FAKE_FORMULA=csound \
FAKE_PREFIX="$test_dir/prefix" \
FAKE_INSTALLED_STATE="$test_dir/installed" \
  "$repo_dir/scripts/native-verify" csound \
  "$test_dir/csound--1.0.ventura.bottle.tar.gz" "$sha" "$test_dir/out" >/dev/null

test -s "$test_dir/out/csound.smoke.wav"
test -s "$test_dir/out/native-verification.txt"
grep -F -- 'install --formula ' "$test_dir/brew.log" >/dev/null

if PATH="$test_dir/bin:$PATH" \
  BREW_LOG="$test_dir/retry.log" \
  FAKE_FORMULA=csound \
  FAKE_PREFIX="$test_dir/prefix" \
  FAKE_INSTALLED_STATE="$test_dir/installed" \
    "$repo_dir/scripts/native-verify" csound \
    "$test_dir/csound--1.0.ventura.bottle.tar.gz" "$sha" "$test_dir/retry-out" >/dev/null 2>&1; then
  printf '%s\n' 'native-verify accepted a non-fresh runner' >&2
  exit 1
fi

printf '%s\n' ok
