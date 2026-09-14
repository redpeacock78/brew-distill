#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-guest-formula-test.XXXXXX")

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/bin" "$test_dir/build" "$test_dir/verify" "$test_dir/remote"
printf '%s\n' overlay > "$test_dir/overlay.qcow2"
cat > "$test_dir/bin/boot" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$FAKE_BOOT_LOG"
EOF
cat > "$test_dir/bin/ssh" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$FAKE_REMOTE_LOG"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|-p) shift 2 ;;
    *) shift; break ;;
  esac
done
command=$*
case "$command" in
  *"uname -a"*)
    printf '%s\n' 'Darwin test-guest 23.0.0' 'ProductName: macOS' ;;
  *"sw_vers -productVersion"*)
    printf '%s\n' '13.6.1' ;;
  *"sw_vers -buildVersion"*)
    printf '%s\n' '22G313' ;;
  *"uname -m"*)
    printf '%s\n' 'x86_64' ;;
  *"xcodebuild -version"*)
    printf '%s\n' 'Xcode 15.0' 'Build version 15A240d' ;;
  *"clang --version"*)
    printf '%s\n' 'Apple clang version 15.0.0' ;;
  *"xcrun --sdk macosx --show-sdk-version"*)
    printf '%s\n' '13.3' ;;
  *"brew config"*)
    printf '%s\n' 'HOMEBREW_VERSION: 4.0.0' ;;
  *"brew doctor"*)
    printf '%s\n' 'Your system is ready to brew.' ;;
  *"brew linkage --test"*)
    printf '%s\n' 'linkage ok' ;;
  *"brew info --json=v2 --formula"*)
    cat > "$FAKE_REMOTE_INFO" <<'JSON'
{"formulae":[{"name":"dummy","versions":{"stable":"1.0"},"revision":0,"ruby_source_checksum":{"sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},"dependencies":[]}]}
JSON
    ;;
  *) ;;
esac
EOF
cat > "$test_dir/bin/scp" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$FAKE_REMOTE_LOG"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|-P) shift 2 ;;
    *) break ;;
  esac
done
source=$1
destination=$2
case "$destination" in
  *:*)
    mkdir -p "$FAKE_REMOTE_ROOT"
    cp "$source" "$FAKE_REMOTE_ROOT/$(basename -- "$source")"
    ;;
  *)
    destination=${destination%/}
    mkdir -p "$destination"
    case "$source" in
      *.bottle.tar.gz)
        printf '%s\n' 'fixture bottle' > "$destination/dummy--1.0.ventura.bottle.tar.gz"
        ;;
      *.bottle*.json)
        json_name=dummy--1.0.ventura.bottle.json
        if [ "${FAKE_BOTTLE_JSON_REBUILD:-0}" = "1" ]; then
          json_name=dummy--1.0.ventura.bottle.1.json
        fi
        printf '%s\n' '{}' > "$destination/$json_name"
        ;;
      */formula-info.json)
        cp "$FAKE_REMOTE_INFO" "$destination/formula-info.json"
        ;;
      *)
        printf '%s\n' 'unexpected remote source' >&2
        exit 1
        ;;
    esac
    ;;
esac
EOF
chmod 755 "$test_dir/bin/boot" "$test_dir/bin/ssh" "$test_dir/bin/scp"

run_with_fakes() {
  script=$1
  shift
  env \
    "DISTILL_GUEST_BOOT=$test_dir/bin/boot" \
    "DISTILL_SSH=$test_dir/bin/ssh" \
    "DISTILL_SCP=$test_dir/bin/scp" \
    DISTILL_SSH_TIMEOUT=2 \
    "FAKE_BOOT_LOG=$test_dir/boot.log" \
    "FAKE_REMOTE_LOG=$test_dir/remote.log" \
    "FAKE_REMOTE_ROOT=$test_dir/remote" \
    "FAKE_REMOTE_INFO=$test_dir/remote/formula-info.json" \
    FAKE_BOTTLE_JSON_REBUILD=1 \
    "$script" "$@"
}

run_with_fakes "$repo_dir/scripts/hvf/build-formula" dummy \
  "$test_dir/overlay.qcow2" "$test_dir/build" >/dev/null

bottle="$test_dir/build/dummy--1.0.ventura.bottle.tar.gz"
manifest="$test_dir/build/dummy--1.0.ventura.bottle.manifest.json"
test -s "$bottle"
test -s "$manifest"
jq -e '.schema == 4 and .formula.name == "dummy" and .platform.arch == "x86_64" and .artifact.path == "dummy--1.0.ventura.bottle.tar.gz"' \
  "$manifest" >/dev/null
grep -F -- 'brew install --build-bottle --formula dummy' "$test_dir/remote.log" >/dev/null
grep -F -- 'brew bottle --json' "$test_dir/remote.log" >/dev/null
grep -F -- 'brew info --json=v2 --formula' "$test_dir/remote.log" >/dev/null

printf '%s\n' overlay > "$test_dir/verify-overlay.qcow2"
: > "$test_dir/remote.log"
run_with_fakes "$repo_dir/scripts/hvf/verify-formula" dummy \
  "$test_dir/verify-overlay.qcow2" "$bottle" "$test_dir/verify" >/dev/null
if [ ! -s "$test_dir/verify/verify-guest-info.txt" ]; then
  cat "$test_dir/remote.log" >&2
  ls -l "$test_dir/verify" >&2
  exit 1
fi
test -s "$test_dir/verify/dummy.verify-linkage.txt"
grep -F -- 'brew install --formula' "$test_dir/remote.log" >/dev/null
grep -F -- 'brew test dummy' "$test_dir/remote.log" >/dev/null

printf '%s\n' ok
