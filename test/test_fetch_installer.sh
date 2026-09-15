#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-fetch-installer-test.XXXXXX")

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/bin" "$test_dir/Applications" "$test_dir/no-packages" "$test_dir/out"
cat > "$test_dir/bin/uname" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -s ]; then
  printf '%s\n' Darwin
else
  exec /usr/bin/uname "$@"
fi
EOF
cat > "$test_dir/bin/softwareupdate" <<'EOF'
#!/bin/sh
exit 0
EOF
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
printf '%s\n' package > "$output"
EOF
cat > "$test_dir/catalog-helper.py" <<'EOF'
import json

print(json.dumps({
    "schema": 1,
    "version": "13.7.8",
    "build": "22H730",
    "bundle_version": "18.7.62",
    "package_url": "https://example.invalid/InstallAssistant.pkg",
}))
EOF
cat > "$test_dir/installer" <<'EOF'
#!/bin/sh
set -eu
test "${CM_BUILD:-}" = CM_BUILD
root=$FAKE_INSTALLER_ROOT
mkdir -p "$root/Install macOS Ventura.app/Contents/Resources"
cat > "$root/Install macOS Ventura.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>18.7.62</string></dict></plist>
PLIST
printf '%s\n' startosinstall > "$root/Install macOS Ventura.app/Contents/Resources/startosinstall"
chmod 755 "$root/Install macOS Ventura.app/Contents/Resources/startosinstall"
EOF
chmod 755 "$test_dir/bin/uname" "$test_dir/bin/softwareupdate" "$test_dir/bin/curl" "$test_dir/installer"

PATH="$test_dir/bin:$PATH" \
  DISTILL_SOFTWAREUPDATE="$test_dir/bin/softwareupdate" \
  DISTILL_SOFTWAREUPDATE_ATTEMPTS=1 \
  DISTILL_INSTALLER_ROOT="$test_dir/Applications" \
  DISTILL_INSTALLER_PACKAGE_ROOT="$test_dir/no-packages" \
  DISTILL_INSTALLER_DISCOVERY_TIMEOUT=1 \
  DISTILL_INSTALLER_DISCOVERY_POLL=1 \
  DISTILL_INSTALLER_CATALOG_FALLBACK=1 \
  DISTILL_INSTALLER_CATALOG_HELPER="$test_dir/catalog-helper.py" \
  DISTILL_INSTALLER_CMD="$test_dir/installer" \
  FAKE_INSTALLER_ROOT="$test_dir/Applications" \
  "$repo_dir/scripts/hvf/fetch-installer" 13.7.8 "$test_dir/out" >/dev/null

jq -e '.version == "13.7.8" and .bundle_version == "18.7.62" and (.installer | endswith("Install macOS Ventura.app"))' \
  "$test_dir/out/installer.json" >/dev/null
grep -Fqx -- 'catalog package installed' "$test_dir/out/installer-package.log"

printf '%s\n' ok
