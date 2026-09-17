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
set -eu
printf '%s\n' "$*" >> "${SOFTWAREUPDATE_LOG:?}"
if [ "${SOFTWAREUPDATE_CREATE_APP:-0}" = "1" ]; then
  root=$FAKE_INSTALLER_ROOT
  mkdir -p "$root/Install macOS Ventura.app/Contents/Resources"
  cat > "$root/Install macOS Ventura.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist version="1.0"><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>13.7.8</string></dict></plist>
PLIST
  printf '%s\n' startosinstall > "$root/Install macOS Ventura.app/Contents/Resources/startosinstall"
  chmod 755 "$root/Install macOS Ventura.app/Contents/Resources/startosinstall"
fi
exit 0
EOF
cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
set -eu
if [ "${CURL_FAIL:-0}" = "1" ]; then
  exit 22
fi
output=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output=$2; shift 2 ;;
    --retry|--retry-delay) shift 2 ;;
    --fail|--location|--progress-bar) shift ;;
    *) url=$1; shift ;;
  esac
done
test -n "$output"
case "$url" in
  *InstallInfo.plist)
    cat > "$output" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist version="1.0"><plist version="1.0"><dict/></plist>
PLIST
    ;;
  *BuildManifest.plist)
    cat > "$output" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist version="1.0"><plist version="1.0"><dict><key>ProductVersion</key><string>13.7.8</string><key>ProductBuildVersion</key><string>22H730</string></dict></plist>
PLIST
    ;;
  *) printf '%s\n' package > "$output" ;;
esac
EOF
cat > "$test_dir/bin/aria2c" <<'EOF'
#!/bin/sh
set -eu
if [ "${ARIA2_FAIL:-0}" = "1" ]; then
  exit 1
fi
directory=.
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) directory=$2; shift 2 ;;
    --out) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
test -n "$output"
printf '%s\n' package > "$directory/$output"
EOF
cat > "$test_dir/catalog-helper.py" <<'EOF'
import json
import os

helper_log = os.environ.get("CATALOG_HELPER_LOG")
if helper_log:
    with open(helper_log, "a", encoding="utf-8") as stream:
        stream.write("called\n")
if os.environ.get("CATALOG_HELPER_FAIL") == "1":
    raise SystemExit(1)

print(json.dumps({
    "schema": 1,
    "product_id": "test-product-13-7-8",
    "version": "13.7.8",
    "build": "22H730",
    "bundle_version": "18.7.62",
    "package_url": "https://example.invalid/InstallAssistant.pkg",
    "install_info_url": "https://example.invalid/InstallInfo.plist",
    "build_manifest_url": "https://example.invalid/BuildManifest.plist",
}))
EOF
cat > "$test_dir/installer" <<'EOF'
#!/bin/sh
set -eu
test "${CM_BUILD:-}" = CM_BUILD
root=$FAKE_INSTALLER_ROOT
mkdir -p "$root/Install macOS Ventura.app/Contents/Resources" \
  "$root/Install macOS Ventura.app/Contents/SharedSupport"
cat > "$root/Install macOS Ventura.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>18.7.62</string></dict></plist>
PLIST
printf '%s\n' startosinstall > "$root/Install macOS Ventura.app/Contents/Resources/startosinstall"
chmod 755 "$root/Install macOS Ventura.app/Contents/Resources/startosinstall"
EOF
chmod 755 "$test_dir/bin/uname" "$test_dir/bin/softwareupdate" "$test_dir/bin/curl" "$test_dir/bin/aria2c" "$test_dir/installer"

PATH="$test_dir/bin:$PATH" \
  SOFTWAREUPDATE_LOG="$test_dir/softwareupdate.log" \
  DISTILL_SOFTWAREUPDATE="$test_dir/bin/softwareupdate" \
  DISTILL_SOFTWAREUPDATE_ATTEMPTS=1 \
  DISTILL_INSTALLER_ROOT="$test_dir/Applications" \
  DISTILL_INSTALLER_PACKAGE_ROOT="$test_dir/no-packages" \
  DISTILL_INSTALLER_SOFTWAREUPDATE_FALLBACK=0 \
  DISTILL_INSTALLER_CATALOG_PRIMARY=1 \
  DISTILL_INSTALLER_CATALOG_HELPER="$test_dir/catalog-helper.py" \
  DISTILL_INSTALLER_CMD="$test_dir/installer" \
  FAKE_INSTALLER_ROOT="$test_dir/Applications" \
  "$repo_dir/scripts/hvf/fetch-installer" 13.7.8 "$test_dir/out" >/dev/null

jq -e '.version == "13.7.8" and .bundle_version == "18.7.62" and (.installer | endswith("Install macOS Ventura.app"))' \
  "$test_dir/out/installer.json" >/dev/null
test ! -e "$test_dir/softwareupdate.log"
jq -e '.version == "13.7.8" and .product_id == "test-product-13-7-8" and .source == "apple-catalog" and .package_url == "https://example.invalid/InstallAssistant.pkg" and .install_info_url == "https://example.invalid/InstallInfo.plist" and .build_manifest_url == "https://example.invalid/BuildManifest.plist"' \
  "$test_dir/out/installer-catalog-cache.json" >/dev/null
grep -Fqx -- 'catalog package installed' "$test_dir/out/installer-package.log"
grep -Fqx -- 'downloader=aria2c' "$test_dir/out/installer-package.log"
jq -e 'all(.phases; .catalog_resolve >= 0 and .installer_download >= 0 and .installer_checksum >= 0 and .installer_pkg_install >= 0 and .installer_discovery >= 0 and .installer_metadata >= 0)' \
  "$test_dir/out/phase-timings.json" >/dev/null
test -s "$test_dir/Applications/Install macOS Ventura.app/Contents/SharedSupport/InstallInfo.plist"
test -s "$test_dir/Applications/Install macOS Ventura.app/Contents/SharedSupport/BuildManifest.plist"

mkdir -p "$test_dir/cache-applications" "$test_dir/cache-out"
cp "$test_dir/out/installer-catalog-cache.json" "$test_dir/cache-catalog.json"
PATH="$test_dir/bin:$PATH" \
  SOFTWAREUPDATE_LOG="$test_dir/softwareupdate.log" \
  DISTILL_SOFTWAREUPDATE="$test_dir/bin/softwareupdate" \
  DISTILL_INSTALLER_ROOT="$test_dir/cache-applications" \
  DISTILL_INSTALLER_PACKAGE_ROOT="$test_dir/no-packages" \
  DISTILL_INSTALLER_SOFTWAREUPDATE_FALLBACK=0 \
  DISTILL_INSTALLER_CATALOG_PRIMARY=1 \
  DISTILL_INSTALLER_CATALOG_CACHE="$test_dir/cache-catalog.json" \
  DISTILL_INSTALLER_CATALOG_HELPER="$test_dir/catalog-helper.py" \
  DISTILL_INSTALLER_CMD="$test_dir/installer" \
  FAKE_INSTALLER_ROOT="$test_dir/cache-applications" \
  CATALOG_HELPER_LOG="$test_dir/cache-helper.log" \
  CATALOG_HELPER_FAIL=1 \
  "$repo_dir/scripts/hvf/fetch-installer" 13.7.8 "$test_dir/cache-out" >/dev/null
jq -e '.catalog.source == "apple-catalog" and .catalog.resolved_at != ""' \
  "$test_dir/cache-out/installer.json" >/dev/null
test ! -e "$test_dir/cache-helper.log"
jq -e '.phases.catalog_resolve >= 0 and .phases.installer_download >= 0' \
  "$test_dir/cache-out/phase-timings.json" >/dev/null

mkdir -p "$test_dir/invalidate-applications" "$test_dir/invalidate-out"
cp "$test_dir/out/installer-catalog-cache.json" "$test_dir/invalidate-cache.json"
if PATH="$test_dir/bin:$PATH" \
  SOFTWAREUPDATE_LOG="$test_dir/softwareupdate.log" \
  DISTILL_SOFTWAREUPDATE="$test_dir/bin/softwareupdate" \
  DISTILL_INSTALLER_ROOT="$test_dir/invalidate-applications" \
  DISTILL_INSTALLER_PACKAGE_ROOT="$test_dir/no-packages" \
  DISTILL_INSTALLER_SOFTWAREUPDATE_FALLBACK=0 \
  DISTILL_INSTALLER_CATALOG_PRIMARY=1 \
  DISTILL_INSTALLER_CATALOG_CACHE="$test_dir/invalidate-cache.json" \
  DISTILL_INSTALLER_CATALOG_HELPER="$test_dir/catalog-helper.py" \
  DISTILL_INSTALLER_CMD="$test_dir/installer" \
  FAKE_INSTALLER_ROOT="$test_dir/invalidate-applications" \
  CATALOG_HELPER_LOG="$test_dir/invalidate-helper.log" \
  ARIA2_FAIL=1 CURL_FAIL=1 \
  "$repo_dir/scripts/hvf/fetch-installer" 13.7.8 "$test_dir/invalidate-out" >/dev/null 2>&1; then
  printf '%s\n' 'fetch-installer accepted a failed cached URL' >&2
  exit 1
fi
test ! -e "$test_dir/invalidate-cache.json"
test -s "$test_dir/invalidate-helper.log"

mkdir -p "$test_dir/curl-applications" "$test_dir/curl-out"
PATH="$test_dir/bin:$PATH" \
  SOFTWAREUPDATE_LOG="$test_dir/softwareupdate.log" \
  DISTILL_SOFTWAREUPDATE="$test_dir/bin/softwareupdate" \
  DISTILL_INSTALLER_ROOT="$test_dir/curl-applications" \
  DISTILL_INSTALLER_PACKAGE_ROOT="$test_dir/no-packages" \
  DISTILL_INSTALLER_SOFTWAREUPDATE_FALLBACK=0 \
  DISTILL_INSTALLER_CATALOG_PRIMARY=1 \
  DISTILL_INSTALLER_CATALOG_CACHE="$test_dir/curl-cache.json" \
  DISTILL_INSTALLER_CATALOG_HELPER="$test_dir/catalog-helper.py" \
  DISTILL_INSTALLER_CMD="$test_dir/installer" \
  FAKE_INSTALLER_ROOT="$test_dir/curl-applications" \
  ARIA2_FAIL=1 \
  "$repo_dir/scripts/hvf/fetch-installer" 13.7.8 "$test_dir/curl-out" >/dev/null
grep -Fqx -- 'downloader=curl-fallback' "$test_dir/curl-out/installer-package.log"

mkdir -p "$test_dir/softwareupdate-applications" "$test_dir/softwareupdate-out"
PATH="$test_dir/bin:$PATH" \
  SOFTWAREUPDATE_LOG="$test_dir/softwareupdate.log" \
  SOFTWAREUPDATE_CREATE_APP=1 \
  DISTILL_SOFTWAREUPDATE="$test_dir/bin/softwareupdate" \
  DISTILL_SOFTWAREUPDATE_ATTEMPTS=1 \
  DISTILL_INSTALLER_ROOT="$test_dir/softwareupdate-applications" \
  DISTILL_INSTALLER_PACKAGE_ROOT="$test_dir/no-packages" \
  DISTILL_INSTALLER_CATALOG_PRIMARY=1 \
  DISTILL_INSTALLER_SOFTWAREUPDATE_FALLBACK=1 \
  DISTILL_INSTALLER_DISCOVERY_TIMEOUT=1 \
  DISTILL_INSTALLER_DISCOVERY_POLL=1 \
  DISTILL_INSTALLER_CATALOG_CACHE="$test_dir/softwareupdate-cache.json" \
  DISTILL_INSTALLER_CATALOG_HELPER="$test_dir/catalog-helper.py" \
  DISTILL_INSTALLER_CMD="$test_dir/installer" \
  FAKE_INSTALLER_ROOT="$test_dir/softwareupdate-applications" \
  CATALOG_HELPER_FAIL=1 ARIA2_FAIL=1 CURL_FAIL=1 \
  "$repo_dir/scripts/hvf/fetch-installer" 13.7.8 "$test_dir/softwareupdate-out" >/dev/null
jq -e '.catalog == null and .bundle_version == "13.7.8"' \
  "$test_dir/softwareupdate-out/installer.json" >/dev/null
grep -Fqx -- '--list-full-installers' "$test_dir/softwareupdate.log"
grep -Fqx -- '--fetch-full-installer --full-installer-version 13.7.8' "$test_dir/softwareupdate.log"

printf '%s\n' ok
