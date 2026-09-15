#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-legacy-poc-test.XXXXXX")

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/bin" "$test_dir/opencore/EFI/BOOT" "$test_dir/opencore/EFI/OC" \
  "$test_dir/Applications" "$test_dir/output"
cat > "$test_dir/opencore/EFI/OC/config.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
PLIST
printf '%s\n' boot > "$test_dir/opencore/EFI/BOOT/BOOTx64.efi"
printf '%s\n' opencore > "$test_dir/opencore/EFI/OC/OpenCore.efi"
mkdir -p "$test_dir/Applications/Install macOS Sonoma.app/Contents/Resources"
cat > "$test_dir/Applications/Install macOS Sonoma.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>14.0.0</string></dict></plist>
PLIST
printf '%s\n' wrong-version > "$test_dir/Applications/Install macOS Sonoma.app/Contents/Resources/startosinstall"
chmod 755 "$test_dir/Applications/Install macOS Sonoma.app/Contents/Resources/startosinstall"
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
installer_root=${DISTILL_INSTALLER_ROOT:-$HOME/Applications}
mkdir -p "$installer_root/Install macOS Ventura.app/Contents/Resources"
cat > "$installer_root/Install macOS Ventura.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>13.6.1</string></dict></plist>
PLIST
cat > "$installer_root/Install macOS Ventura.app/Contents/Resources/startosinstall" <<'INNER'
#!/bin/sh
if [ "${1:-}" = "--usage" ]; then
  printf '%s\n' --agreetolicense --nointeraction --eraseinstall --volume
  exit 0
fi
exit 0
INNER
chmod 755 "$installer_root/Install macOS Ventura.app/Contents/Resources/startosinstall"
EOF
cat > "$test_dir/bin/sudo" <<'EOF'
#!/bin/sh
set -eu
if [ "${1:-}" = -n ]; then
  shift
fi
if [ "$#" -eq 1 ] && [ "$1" = true ]; then
  exit 0
fi
exec "$@"
EOF
cat > "$test_dir/bootstrap" <<'EOF'
#!/bin/sh
set -eu
test "$#" -eq 4
test "${DISTILL_MACOS_MAJOR:-}" = 13
test -f "$2"
printf '%s\n' bootstrapped > "$2"
printf '%s\n' '{"schema":1,"qemu_args":["-accel","hvf"],"vm_image":false}' > "$4/.qemu-runtime.json"
EOF
cat > "$test_dir/builder" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' bottle > "$3/$1--1.0.ventura.bottle.tar.gz"
test "${DISTILL_QEMU_CONFIG:-}" = "$DISTILL_LEGACY_OUTPUT_DIR/hvf/.qemu-runtime.json"
EOF
chmod 755 "$test_dir/bin/qemu-system-x86_64" "$test_dir/bin/qemu-img" \
  "$test_dir/bin/softwareupdate" "$test_dir/bin/sudo" "$test_dir/bootstrap" "$test_dir/builder"
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
HOME="$test_dir" \
QEMU_SYSTEM_X86_64="$test_dir/bin/qemu-system-x86_64" \
QEMU_IMG="$test_dir/bin/qemu-img" \
  DISTILL_SOFTWAREUPDATE="$test_dir/bin/softwareupdate" \
  DISTILL_SOFTWAREUPDATE_SUDO=1 DISTILL_SOFTWAREUPDATE_ATTEMPTS=1 \
  DISTILL_INSTALLER_CATALOG_PRIMARY=0 DISTILL_INSTALLER_SOFTWAREUPDATE_FALLBACK=1 \
  DISTILL_OPENCORE_DIR="$test_dir/opencore" \
DISTILL_OPENCORE_STRICT=1 DISTILL_CREATE_OPENCORE_DISK=1 \
DISTILL_INSTALLER_VERSION=13.6.1 \
DISTILL_LEGACY_OUTPUT_DIR="$test_dir/output" \
DISTILL_MIN_FREE_GIB=0 DISTILL_DISK_CANDIDATES='' \
DISTILL_LEGACY_BOOTSTRAP="$test_dir/bootstrap" \
DISTILL_GUEST_BUILD="$test_dir/builder" \
DISTILL_REQUIRE_ARTIFACT=1 \
  "$repo_dir/scripts/hvf/legacy-poc" 13 "$test_dir/batch.json" >/dev/null

test -s "$test_dir/output/artifacts/csound--1.0.ventura.bottle.tar.gz"
jq -e '.qemu.hvf == true' "$test_dir/output/hvf/host-info.json" >/dev/null
jq -e '.version == "13.6.1" and .bundle_version == "13.6.1" and (.installer | endswith("Install macOS Ventura.app"))' \
  "$test_dir/output/hvf/installer.json" >/dev/null
jq -e '.usage_status == 0' "$test_dir/output/hvf/installer-capabilities.json" >/dev/null
test -s "$test_dir/output/hvf/startosinstall-usage.txt"
test -s "$test_dir/output/hvf/opencore-disk.json"
jq -e '.csound.status == "PASS"' \
  "$test_dir/output/artifacts/batch-results.json" >/dev/null
test -s "$test_dir/output/diagnostics.json"
printf '%s\n' ok
