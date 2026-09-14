#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-publish-test.XXXXXX")
test_dir=$(cd "$test_dir" && pwd)

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/release" "$test_dir/bin"
printf '%s\n' bottle > "$test_dir/release/dummy--1.0.ventura.bottle.tar.gz"
printf '%s\n' bottle-json > "$test_dir/release/dummy--1.0.ventura.bottle.json"
printf '%s\n' manifest > "$test_dir/release/dummy.manifest.json"
printf '%s\n' aggregate > "$test_dir/release/manifest.json"
printf '%s\n' metadata > "$test_dir/release/metadata.tar.gz"
(cd "$test_dir/release" && shasum -a 256 \
  dummy--1.0.ventura.bottle.tar.gz dummy--1.0.ventura.bottle.json \
  dummy.manifest.json manifest.json metadata.tar.gz > checksums.txt)
cat > "$test_dir/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1" = release ] && [ "$2" = view ]; then
  exit 1
fi
EOF
chmod 755 "$test_dir/bin/gh"

PATH="$test_dir/bin:$PATH" GH_LOG="$test_dir/gh.log" DISTILL_PUBLISH=1 \
  "$repo_dir/scripts/publish-release" "$test_dir/release" distill-build-1-1 owner/repo >/dev/null
grep -F -- 'release create distill-build-1-1 --repo owner/repo' "$test_dir/gh.log" >/dev/null

if PATH="$test_dir/bin:$PATH" "$repo_dir/scripts/publish-release" \
  "$test_dir/release" distill-build-1-2 owner/repo >/dev/null 2>&1; then
  printf '%s\n' 'publish-release ignored its explicit publish gate' >&2
  exit 1
fi

printf '%s\n' ok
