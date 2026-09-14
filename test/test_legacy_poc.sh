#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-legacy-poc-test.XXXXXX")

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/bin" "$test_dir/opencore/EFI/OC" "$test_dir/Applications" "$test_dir/output"
printf '%s\n' config > "$test_dir/opencore/EFI/OC/config.plist"
cat > "$test_dir/bin/qemu-system-x86_64" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
  --version) printf '%s\n' 'QEMU emulator version 9.0.0' ;;
  -accel) printf '%s\n' tcg hvf ;;
  *) exit 2 ;;
esac
EOF
cat > "$test_dir/bin/qemu-img" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
  create)
    if [ "$#" -eq 5 ]; then
      output=$4
    else
      output=$8
    fi
    printf '%s\n' overlay > "$output"
    ;;
  check)
    printf '%s\n' check-ok
    ;;
  *) exit 2 ;;
esac
EOF
cat > "$test_dir/bin/softwareupdate" <<'EOF'
#!/bin/sh
set -eu
mkdir -p "$DISTILL_INSTALLER_ROOT/Install macOS Ventura.app/Contents/Resources"
cat > "$DISTILL_INSTALLER_ROOT/Install macOS Ventura.app/Contents/Resources/startosinstall" <<'INNER'
#!/bin/sh
exit 0
INNER
chmod 755 "$DISTILL_INSTALLER_ROOT/Install macOS Ventura.app/Contents/Resources/startosinstall"
EOF
cat > "$test_dir/bootstrap" <<'EOF'
#!/bin/sh
set -eu
test "$#" -eq 4
test -f "$2"
printf '%s\n' bootstrapped > "$2"
EOF
cat > "$test_dir/builder" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' bottle > "$3/$1--1.0.ventura.bottle.tar.gz"
EOF
chmod 755 "$test_dir/bin/qemu-system-x86_64" "$test_dir/bin/qemu-img" \
  "$test_dir/bin/softwareupdate" "$test_dir/bootstrap" "$test_dir/builder"
cat > "$test_dir/bin/sysctl" <<'EOF'
#!/bin/sh
case "${2:-}" in
  kern.hv_support) printf '%s\n' 1 ;;
  machdep.cpu.brand_string) printf '%s\n' 'Test CPU' ;;
  *) exit 1 ;;
esac
EOF
chmod 755 "$test_dir/bin/sysctl"
jq -n '{formulas:["csound"]}' > "$test_dir/batch.json"

PATH="$test_dir/bin:$PATH" \
QEMU_SYSTEM_X86_64="$test_dir/bin/qemu-system-x86_64" \
QEMU_IMG="$test_dir/bin/qemu-img" \
DISTILL_SOFTWAREUPDATE="$test_dir/bin/softwareupdate" \
DISTILL_INSTALLER_ROOT="$test_dir/Applications" \
DISTILL_OPENCORE_DIR="$test_dir/opencore" \
DISTILL_INSTALLER_VERSION=13.6.1 \
DISTILL_LEGACY_OUTPUT_DIR="$test_dir/output" \
DISTILL_MIN_FREE_GIB=0 DISTILL_DISK_CANDIDATES='' \
DISTILL_LEGACY_BOOTSTRAP="$test_dir/bootstrap" \
DISTILL_GUEST_BUILD="$test_dir/builder" \
DISTILL_REQUIRE_ARTIFACT=1 \
  "$repo_dir/scripts/hvf/legacy-poc" 13 "$test_dir/batch.json" >/dev/null

test -s "$test_dir/output/artifacts/csound--1.0.ventura.bottle.tar.gz"
jq -e '.qemu.hvf == true' "$test_dir/output/hvf/host-info.json" >/dev/null
jq -e '.csound.status == "PASS"' \
  "$test_dir/output/artifacts/batch-results.json" >/dev/null
test -s "$test_dir/output/diagnostics.json"
printf '%s\n' ok
