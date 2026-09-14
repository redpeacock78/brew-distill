#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-bootstrap-homebrew-test.XXXXXX")

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/bin" "$test_dir/out"
cat > "$test_dir/bin/uname" <<'EOF'
#!/bin/sh
printf '%s\n' Darwin
EOF
cat > "$test_dir/bin/brew" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$BREW_LOG"
case "${1:-}" in
  --version) printf '%s\n' 'Homebrew 4.0.0' ;;
  config) printf '%s\n' 'HOMEBREW_VERSION: 4.0.0' ;;
  doctor) printf '%s\n' 'Your system is ready to brew.' ;;
esac
EOF
chmod 755 "$test_dir/bin/uname" "$test_dir/bin/brew"

if PATH="$test_dir/bin:$PATH" DISTILL_GUEST=0 BREW_LOG="$test_dir/guard.log" \
  "$repo_dir/scripts/hvf/bootstrap-homebrew" "$test_dir/guard" >/dev/null 2>&1; then
  printf '%s\n' 'bootstrap-homebrew ignored the guest guard' >&2
  exit 1
fi

PATH="$test_dir/bin:$PATH" DISTILL_GUEST=1 BREW_LOG="$test_dir/brew.log" \
  "$repo_dir/scripts/hvf/bootstrap-homebrew" "$test_dir/out" >/dev/null
test -s "$test_dir/out/brew-version.txt"
test -s "$test_dir/out/brew-config.txt"
test -s "$test_dir/out/brew-doctor.txt"
grep -Fqx -- '--version' "$test_dir/brew.log"
grep -Fqx -- 'config' "$test_dir/brew.log"
grep -Fqx -- 'doctor' "$test_dir/brew.log"

printf '%s\n' ok
