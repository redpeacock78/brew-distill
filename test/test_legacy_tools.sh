#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-legacy-tools-test.XXXXXX")
test_dir=$(cd "$test_dir" && pwd)

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/out"
test -x "$repo_dir/scripts/hvf/fetch-recovery"
grep -F -- 'public_key_fingerprint' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'firstboot.log' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
python3 -c 'import pathlib, sys; path = pathlib.Path(sys.argv[1]); compile(path.read_text(encoding="utf-8"), str(path), "exec")' \
  "$repo_dir/scripts/hvf/fetch-recovery"
DISTILL_DISK_CANDIDATES='' DISTILL_MIN_FREE_GIB=0 \
  "$repo_dir/scripts/hvf/reclaim-disk" "$test_dir/out" report >/dev/null
jq -e '.mode == "report" and .paths == []' "$test_dir/out/reclaim.json" >/dev/null

mkdir -p "$test_dir/reclaim-me"
DISTILL_DISK_CANDIDATES='' DISTILL_MIN_FREE_GIB=0 DISTILL_RECLAIM_PATHS="$test_dir/reclaim-me" \
  "$repo_dir/scripts/hvf/reclaim-disk" "$test_dir/out" apply >/dev/null
test ! -e "$test_dir/reclaim-me"
jq -e '.mode == "apply" and .paths == ["'"$test_dir"'/reclaim-me"]' \
  "$test_dir/out/reclaim.json" >/dev/null

mkdir -p "$test_dir/opencore-src/EFI/BOOT" "$test_dir/opencore-src/EFI/OC"
cat > "$test_dir/opencore-src/EFI/OC/config.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>ACPI</key><dict/></dict></plist>
PLIST
printf '%s\n' boot > "$test_dir/opencore-src/EFI/BOOT/BOOTx64.efi"
printf '%s\n' opencore > "$test_dir/opencore-src/EFI/OC/OpenCore.efi"
DISTILL_OPENCORE_DIR="$test_dir/opencore-src" DISTILL_OPENCORE_STRICT=1 \
  "$repo_dir/scripts/hvf/prepare-opencore" 13 "$test_dir/opencore" >/dev/null
test -s "$test_dir/opencore/EFI/OC/config.plist"
jq -e '.version == "13" and .strict == true and (.boot_files | length) == 2 and .vm_image == false' \
  "$test_dir/opencore/opencore.json" >/dev/null
"$repo_dir/scripts/hvf/create-opencore-disk" "$test_dir/opencore" \
  "$test_dir/opencore.img" >/dev/null
test -s "$test_dir/opencore.img"
jq -e '.format == "UDRW" and .vm_image == false and (.sha256 | length) == 64' \
  "$test_dir/opencore-disk.json" >/dev/null

cat > "$test_dir/fake-ssh" <<'EOF'
#!/bin/sh
printf '%s\n' 'Darwin guest' '13.6'
EOF
chmod 755 "$test_dir/fake-ssh"
DISTILL_SSH="$test_dir/fake-ssh" DISTILL_GUEST_INFO="$test_dir/guest-info.txt" \
  "$repo_dir/scripts/hvf/wait-ssh" distill@127.0.0.1 2222 1 >/dev/null
grep -Fqx 'Darwin guest' "$test_dir/guest-info.txt"

printf '%s\n' base > "$test_dir/base.qcow2"
mkdir -p "$test_dir/bin" "$test_dir/artifacts" "$test_dir/overlays"
cat > "$test_dir/create-qemu-img" <<'EOF'
#!/bin/sh
set -eu
test "$1" = create
printf '%s\n' "$*" >> "$QEMU_IMG_LOG"
printf '%s\n' base > "$4"
EOF
chmod 755 "$test_dir/create-qemu-img"
QEMU_IMG="$test_dir/create-qemu-img" QEMU_IMG_LOG="$test_dir/qemu-img-create.log" \
  "$repo_dir/scripts/hvf/create-base" "$test_dir/new-base.qcow2" 64G "$test_dir/out" >/dev/null
test -s "$test_dir/new-base.qcow2"
grep -F -- 'create -f qcow2' "$test_dir/qemu-img-create.log" >/dev/null

cp "$repo_dir/test/fake-qemu-img" "$test_dir/bin/qemu-img"
chmod 755 "$test_dir/bin/qemu-img"
cat > "$test_dir/qemu-img-check" <<'EOF'
#!/bin/sh
test "$1" = check
printf '%s\n' 'check ok'
EOF
chmod 755 "$test_dir/qemu-img-check"
QEMU_IMG="$test_dir/qemu-img-check" \
  "$repo_dir/scripts/hvf/freeze-base" "$test_dir/base.qcow2" "$test_dir/out" >/dev/null
test ! -w "$test_dir/base.qcow2"
jq -e '.read_only == true and .persistent == false' "$test_dir/out/base.json" >/dev/null

printf '%s\n' overlay > "$test_dir/boot-overlay.qcow2"
cat > "$test_dir/fake-qemu" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$QEMU_LOG"
EOF
chmod 755 "$test_dir/fake-qemu"
DISTILL_ALLOW_NON_DARWIN=1 QEMU_SYSTEM_X86_64="$test_dir/fake-qemu" \
  QEMU_LOG="$test_dir/qemu.log" "$repo_dir/scripts/hvf/boot-guest" \
  "$test_dir/boot-overlay.qcow2" "$test_dir/out" >/dev/null
grep -F -- '-accel hvf' "$test_dir/qemu.log" >/dev/null
grep -F -- "$test_dir/boot-overlay.qcow2" "$test_dir/qemu.log" >/dev/null
printf '%s\n' opencore > "$test_dir/opencore.img"
DISTILL_ALLOW_NON_DARWIN=1 DISTILL_OPENCORE_DISK="$test_dir/opencore.img" \
  QEMU_SYSTEM_X86_64="$test_dir/fake-qemu" QEMU_LOG="$test_dir/qemu.log" \
  "$repo_dir/scripts/hvf/boot-guest" "$test_dir/boot-overlay.qcow2" "$test_dir/out" >/dev/null
grep -F -- "$test_dir/opencore.img" "$test_dir/qemu.log" >/dev/null
grep -F -- 'OpenCoreBoot' "$test_dir/qemu.log" >/dev/null
if grep -F -- 'readonly=on' "$test_dir/qemu.log" >/dev/null; then
  printf '%s\n' 'boot-guest attached OpenCore as read-only' >&2
  exit 1
fi

cat > "$test_dir/verifier" <<'EOF'
#!/bin/sh
printf '%s\n' verified > "$4/verified.txt"
EOF
chmod 755 "$test_dir/verifier"
cat > "$test_dir/builder" <<'EOF'
#!/bin/sh
set -eu
formula=$1
artifact_dir=$3
if [ "$formula" = bad ]; then
  exit 9
fi
bottle="$artifact_dir/$formula--1.0.ventura.bottle.tar.gz"
printf '%s\n' bottle > "$bottle"
sha=$(shasum -a 256 "$bottle" | awk '{print $1}')
jq -n --arg sha "$sha" '{artifact:{sha256:$sha}}' \
  > "$artifact_dir/$formula--1.0.ventura.bottle.manifest.json"
EOF
chmod 755 "$test_dir/builder"
jq -n '{formulas:["good","bad","after"],dependencies:{after:["bad"]}}' > "$test_dir/batch.json"
if QEMU_IMG="$test_dir/bin/qemu-img" QEMU_IMG_LOG="$test_dir/qemu-img.log" \
  DISTILL_BASE_IMAGE="$test_dir/base.qcow2" DISTILL_ARTIFACT_DIR="$test_dir/artifacts" \
  DISTILL_PHASE_TIMINGS="$test_dir/out/phase-timings.json" \
  DISTILL_OVERLAY_DIR="$test_dir/overlays" DISTILL_GUEST_BUILD="$test_dir/builder" \
  DISTILL_VERIFY_AFTER_BUILD=1 DISTILL_GUEST_VERIFY="$test_dir/verifier" \
  "$repo_dir/scripts/hvf/build-batch" "$test_dir/batch.json" >/dev/null; then
  printf '%s\n' 'build-batch accepted a failed formula' >&2
  exit 1
fi
jq -e \
  '.good.status == "PASS" and .bad.status == "FAIL" and .after.status == "SKIPPED_DEPENDENCY"' \
  "$test_dir/artifacts/batch-results.json" >/dev/null
jq -e '.schema == 1 and (.formulas.good.status == "PASS")' \
  "$test_dir/artifacts/timings.json" >/dev/null
test -s "$test_dir/artifacts/verified.txt"
printf '%s\n' bottle > "$test_dir/sample.bottle.tar.gz"
sample_sha=$(shasum -a 256 "$test_dir/sample.bottle.tar.gz" | awk '{print $1}')
QEMU_IMG="$test_dir/bin/qemu-img" QEMU_IMG_LOG="$test_dir/qemu-img.log" \
  DISTILL_GUEST_VERIFY="$test_dir/verifier" \
  DISTILL_BOTTLE_SHA256="$sample_sha" \
  DISTILL_PHASE_TIMINGS="$test_dir/out/phase-timings.json" \
  "$repo_dir/scripts/hvf/verify-bottle" good "$test_dir/sample.bottle.tar.gz" \
  "$test_dir/base.qcow2" "$test_dir/artifacts" >/dev/null
test -s "$test_dir/artifacts/verified.txt"
test ! -e "$test_dir/artifacts/verify-overlays/good-fresh.qcow2"
jq -e '.phases.formula_build >= 0 and .phases.bottle_verify >= 0' \
  "$test_dir/out/phase-timings.json" >/dev/null
"$repo_dir/scripts/hvf/record-timing" "$test_dir/out/phase-timings.json" recovery_image_download 0
jq -e '.phases.recovery_image_download == 0' "$test_dir/out/phase-timings.json" >/dev/null

printf '%s\n' host > "$test_dir/out/host-info.json"
"$repo_dir/scripts/hvf/export-diagnostics" "$test_dir/out" "$test_dir/diagnostics.tar.gz" >/dev/null
test -s "$test_dir/diagnostics.tar.gz"
jq -e '.files > 0' "$test_dir/out/diagnostics.json" >/dev/null

jq -n '{stable_runs:3,license_review:true,timing_acceptable:true,fresh_overlay:true,provenance:true,runtime_smoke:true,brew_test:true,brew_linkage:true}' \
  > "$test_dir/evidence.json"
"$repo_dir/scripts/hvf/promote" "$test_dir/evidence.json" "$test_dir/promotion.json" >/dev/null
jq -e '.trust == "production"' "$test_dir/promotion.json" >/dev/null

printf '%s\n' ok
