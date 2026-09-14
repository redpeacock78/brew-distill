#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-fetch-opencore-test.XXXXXX")

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/bin" "$test_dir/archive-root/bundle/EFI/BOOT" \
  "$test_dir/archive-root/bundle/EFI/OC" "$test_dir/archive-root/bundle/config"
cat > "$test_dir/archive-root/bundle/config.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
PLIST
printf '%s\n' boot > "$test_dir/archive-root/bundle/EFI/BOOT/BOOTx64.efi"
printf '%s\n' opencore > "$test_dir/archive-root/bundle/EFI/OC/OpenCore.efi"
(cd "$test_dir/archive-root" && zip -qr "$test_dir/opencore.zip" bundle)
expected=$(shasum -a 256 "$test_dir/opencore.zip" | awk '{print $1}')
cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
set -eu
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
test -n "$output"
cp "$FAKE_ARCHIVE" "$output"
EOF
chmod 755 "$test_dir/bin/curl"

PATH="$test_dir/bin:$PATH" FAKE_ARCHIVE="$test_dir/opencore.zip" \
  "$repo_dir/scripts/hvf/fetch-opencore" \
  https://example.invalid/opencore.zip "$expected" "$test_dir/output" >/dev/null
test -s "$test_dir/output/EFI/BOOT/BOOTx64.efi"
test -s "$test_dir/output/EFI/OC/OpenCore.efi"
test -s "$test_dir/output/EFI/OC/config.plist"
jq -e '.schema == 1 and .archive_sha256 == "'"$expected"'" and .vm_image == false' \
  "$test_dir/output/opencore-source.json" >/dev/null

if PATH="$test_dir/bin:$PATH" FAKE_ARCHIVE="$test_dir/opencore.zip" \
  "$repo_dir/scripts/hvf/fetch-opencore" \
  http://example.invalid/opencore.zip "$expected" "$test_dir/bad-url" >/dev/null 2>&1; then
  printf '%s\n' 'fetch-opencore accepted HTTP' >&2
  exit 1
fi

printf '%s\n' ok
