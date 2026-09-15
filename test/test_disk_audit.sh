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

mkdir -p "$test_dir/candidate" "$test_dir/bin"
cat > "$test_dir/bin/du" <<'EOF'
#!/bin/sh
printf '%s\n' called >> "$DISTILL_DU_LOG"
EOF
chmod 755 "$test_dir/bin/du"
PATH="$test_dir/bin:$PATH" DISTILL_DU_LOG="$test_dir/du.log" \
  DISTILL_DISK_CANDIDATES="$test_dir/candidate" \
  "$repo_dir/scripts/hvf/disk-audit" "$test_dir" 0 before >/dev/null
test ! -e "$test_dir/du.log"

if "$repo_dir/scripts/hvf/disk-audit" "$test_dir" 999999 after >/dev/null 2>&1; then
  printf '%s\n' "disk-audit accepted insufficient disk" >&2
  exit 1
fi
jq -e '.snapshot == "after" and .sufficient == false' "$test_dir/disk-after.json" >/dev/null

printf '%s\n' "ok"
