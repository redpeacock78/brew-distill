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
test -x "$repo_dir/scripts/hvf/extract-recovery-image"
python3 -c 'import pathlib, sys; path = pathlib.Path(sys.argv[1]); compile(path.read_text(encoding="utf-8"), str(path), "exec")' \
  "$repo_dir/scripts/hvf/extract-recovery-image"
python3 - "$test_dir/sample-recovery.patch" "$test_dir/sample-recovery.expected" <<'PY'
import hashlib
import lzma
import struct
import sys
from pathlib import Path

patch_path = Path(sys.argv[1])
expected_path = Path(sys.argv[2])
blocks = [b"raw-block" * 512, b"xz-block" * 512]
expected = b"".join(blocks)
payload = bytearray(b"pbzx" + struct.pack(">Q", 4096))
for index, block in enumerate(blocks):
    compressed = block if index == 0 else lzma.compress(block, format=lzma.FORMAT_XZ)
    payload.extend(struct.pack(">QQ", len(block), len(compressed)))
    payload.extend(compressed)
header = struct.pack(
    "<8sQQQQ20s",
    b"BXDIFF50",
    0,
    len(expected),
    0,
    len(payload),
    hashlib.sha1(expected).digest(),
)
patch_path.write_bytes(header + payload)
expected_path.write_bytes(expected)
PY
python3 "$repo_dir/scripts/hvf/extract-recovery-image" \
  "$test_dir/sample-recovery.patch" "$test_dir/sample-recovery.dmg"
cmp "$test_dir/sample-recovery.expected" "$test_dir/sample-recovery.dmg"
grep -F -- 'public_key_fingerprint' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'firstboot.log' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
python3 -c 'import pathlib, sys; path = pathlib.Path(sys.argv[1]); compile(path.read_text(encoding="utf-8"), str(path), "exec")' \
  "$repo_dir/scripts/hvf/fetch-recovery"
DISTILL_RECOVERY_REQUEST_RETRIES=2 DISTILL_RECOVERY_REQUEST_TIMEOUT=1 \
  python3 - "$repo_dir/scripts/hvf/fetch-recovery" <<'PY'
import importlib.util
from importlib.machinery import SourceFileLoader
import sys

loader = SourceFileLoader("fetch_recovery", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)

class Response:
    headers = {"Content-Type": "text/plain"}

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self):
        return b"ok"

calls = 0

def flaky_urlopen(_request, timeout):
    global calls
    calls += 1
    assert timeout == 1.0
    if calls == 1:
        raise TimeoutError("simulated timeout")
    return Response()

module.urllib.request.urlopen = flaky_urlopen
module.time.sleep = lambda _seconds: None
headers, body = module.request("https://example.test", headers={})
assert calls == 2
assert headers["Content-Type"] == "text/plain"
assert body == b"ok"
PY
install_script="$test_dir/install-script.sh"
awk 'BEGIN {emit=0} $0 == "cat > \"$install_script\" <<EOF" {emit=1; next} emit {if ($0 == "EOF") exit; print}' \
  "$repo_dir/scripts/hvf/bootstrap-legacy" | sed -e 's/\\\$/\$/g' -e 's/\\\\/\\/g' > "$install_script"
sh -n "$install_script"
grep -F -- '--volume /Volumes/MACOS' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'target-volume-info.txt' "$install_script" >/dev/null
grep -F -- 'startosinstall-environment.txt' "$install_script" >/dev/null
grep -F -- 'network-diagnostics.txt' "$install_script" >/dev/null
grep -F -- 'startosinstall-watch.log' "$install_script" >/dev/null
grep -F -- 'startosinstall-events.log' "$install_script" >/dev/null
grep -F -- 'STARTOSINSTALL_FAILED' "$install_script" >/dev/null
grep -F -- 'startosinstall-stderr.log' "$install_script" >/dev/null
grep -F -- 'csrutil-status.txt' "$install_script" >/dev/null
grep -F -- 'nvram-diagnostics.txt' "$install_script" >/dev/null
grep -F -- 'NVRAM Protections: enabled' "$install_script" >/dev/null
grep -F -- 'STARTOSINSTALL_PRECONDITION_FAILED' "$install_script" >/dev/null
grep -F -- '/sbin/shutdown -h now' "$install_script" >/dev/null
grep -F -- '--pidtosignal $$' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'PROCESS_TREE' "$install_script" >/dev/null
grep -F -- 'rotation_rate=' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- "disk_rotation_rate=\${DISTILL_QEMU_DISK_ROTATION_RATE:-0}" "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'DISTILL_QEMU_DISK_CACHE' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'DISTILL_QEMU_CPU_MODEL' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'cannot apply QEMU CPU model' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'DISTILL_QEMU_DISK_DEVICE' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'MacHDD NVMe device was not found' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'hdiutil detach -force' "$repo_dir/scripts/hvf/create-opencore-disk" >/dev/null
grep -F -- "installer_app_name=\$(basename -- \"\$installer\")" "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- "ditto \"\$installer\" \"\$installer_app_path\"" "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- "startosinstall=\"\\\$installer_app/Contents/Resources/startosinstall\"" "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'DISTILL_LEGACY_INSTALL_TARGET_MODE' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- '--eraseinstall --newvolumename MACOS' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'qemu-launch.json' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'osk=<redacted>' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'SSH identity and public key do not match' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'OpenCore config.plist is invalid' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- "install_media_size=\${DISTILL_INSTALL_MEDIA_SIZE:-20g}" "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- "hdiutil create -size \"\$install_media_size\"" "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'installer-app-info.txt' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'recovery-system-version.txt' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'DISTILL_LEGACY_MATCHING_RECOVERY' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'diskutil apfs list' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'recovery_system_disk' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'APFS Volume Disk' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'x86_64BaseSystem.dmg' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'matching Recovery expanded' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'signature_distance' "$repo_dir/scripts/hvf/unattended-install" >/dev/null
grep -F -- 'picker_signature_like?' "$repo_dir/scripts/hvf/unattended-install" >/dev/null
grep -F -- 'matching-recovery.log' "$repo_dir/scripts/hvf/export-diagnostics" >/dev/null
grep -F -- 'matching_recovery_prepare' "$repo_dir/scripts/hvf/record-timing" >/dev/null
grep -F -- 'install_media_cache' "$repo_dir/scripts/hvf/bootstrap-legacy" >/dev/null
grep -F -- 'network-diagnostics.txt' "$repo_dir/scripts/hvf/export-diagnostics" >/dev/null
grep -F -- 'recovery-system-version.txt' "$repo_dir/scripts/hvf/export-diagnostics" >/dev/null
if grep -F -- 'out/hvf/opencore/' "$repo_dir/.github/workflows/legacy.yml" >/dev/null; then
  exit 1
fi
disk_list="$test_dir/diskutil-list.txt"
cat > "$disk_list" <<'EOF'
/dev/disk0 (internal, physical):
   0:      GUID_partition_scheme                        *402.7 MB   disk0
/dev/disk2 (internal, physical):
   0:      GUID_partition_scheme                        *13.8 GB    disk2
/dev/disk3 (internal, physical):
   0:                                                   *68.7 GB    disk3
/dev/disk4 (synthesized):
   0:      APFS Container Scheme -                      +13.6 GB    disk4
EOF
target_disk=$(sed -n "/^d=\$(awk /,/^' < \/Volumes/p" "$install_script" | sed '1d;$d' | awk -f - "$disk_list")
test "$target_disk" = disk3
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
<plist version="1.0"><dict>
<key>ACPI</key><dict/>
<key>NVRAM</key><dict><key>Add</key><dict><key>7C436110-AB2A-4BBB-A880-FE41995C9F82</key><dict><key>csr-active-config</key><data>Jg8=</data></dict></dict></dict>
</dict></plist>
PLIST
printf '%s\n' boot > "$test_dir/opencore-src/EFI/BOOT/BOOTx64.efi"
printf '%s\n' opencore > "$test_dir/opencore-src/EFI/OC/OpenCore.efi"
DISTILL_OPENCORE_DIR="$test_dir/opencore-src" DISTILL_OPENCORE_STRICT=1 \
  "$repo_dir/scripts/hvf/prepare-opencore" 13 "$test_dir/opencore" >/dev/null
test -s "$test_dir/opencore/EFI/OC/config.plist"
jq -e '.version == "13" and .strict == true and (.boot_files | length) == 2 and .vm_image == false' \
  "$test_dir/opencore/opencore.json" >/dev/null
DISTILL_OPENCORE_DIR="$test_dir/opencore-src" DISTILL_OPENCORE_STRICT=1 DISTILL_OPENCORE_INSTALLER_MODE=1 \
  "$repo_dir/scripts/hvf/prepare-opencore" 13 "$test_dir/opencore-installer" >/dev/null
jq -e '.installer_mode == true and .csr_active_config.before == "0x00000f26" and .csr_active_config.after == "0x00000f66"' \
  "$test_dir/opencore-installer/opencore.json" >/dev/null
python3 - "$test_dir/opencore-installer/EFI/OC/config.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    config = plistlib.load(handle)
assert config["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]["csr-active-config"] == b"\x66\x0f"
PY
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

cat > "$test_dir/create-qemu-img-options" <<'EOF'
#!/bin/sh
set -eu
test "$1" = create
printf '%s\n' "$*" >> "$QEMU_IMG_LOG"
output=
for argument
do
  case "$argument" in
    *.qcow2|*.raw) output=$argument ;;
  esac
done
test -n "$output"
printf '%s\n' base > "$output"
EOF
chmod 755 "$test_dir/create-qemu-img-options"
QEMU_IMG="$test_dir/create-qemu-img-options" QEMU_IMG_LOG="$test_dir/qemu-img-options.log" \
  DISTILL_BASE_QCOW2_OPTIONS='cluster_size=2M,preallocation=metadata,lazy_refcounts=on' \
  "$repo_dir/scripts/hvf/create-base" "$test_dir/tuned-base.qcow2" 64G "$test_dir/out" >/dev/null
grep -F -- 'create -f qcow2 -o cluster_size=2M,preallocation=metadata,lazy_refcounts=on' \
  "$test_dir/qemu-img-options.log" >/dev/null
jq -e '.format == "qcow2" and .options == "cluster_size=2M,preallocation=metadata,lazy_refcounts=on"' \
  "$test_dir/out/base-create.json" >/dev/null

QEMU_IMG="$test_dir/create-qemu-img-options" QEMU_IMG_LOG="$test_dir/qemu-img-options.log" \
  DISTILL_BASE_FORMAT=raw \
  "$repo_dir/scripts/hvf/create-base" "$test_dir/raw-base.raw" 64G "$test_dir/out" >/dev/null
grep -F -- 'create -f raw' "$test_dir/qemu-img-options.log" >/dev/null
jq -e '.format == "raw" and .options == null' \
  "$test_dir/out/base-create.json" >/dev/null

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
  DISTILL_QEMU_DISK_CACHE=unsafe \
  QEMU_SYSTEM_X86_64="$test_dir/fake-qemu" QEMU_LOG="$test_dir/qemu.log" \
  "$repo_dir/scripts/hvf/boot-guest" "$test_dir/boot-overlay.qcow2" "$test_dir/out" >/dev/null
grep -F -- "$test_dir/opencore.img" "$test_dir/qemu.log" >/dev/null
grep -F -- 'OpenCoreBoot' "$test_dir/qemu.log" >/dev/null
grep -F -- "cache=unsafe" "$test_dir/qemu.log" >/dev/null
if DISTILL_ALLOW_NON_DARWIN=1 DISTILL_QEMU_DISK_CACHE=invalid \
  QEMU_SYSTEM_X86_64="$test_dir/fake-qemu" QEMU_LOG="$test_dir/qemu.log" \
  "$repo_dir/scripts/hvf/boot-guest" "$test_dir/boot-overlay.qcow2" "$test_dir/out" \
  >/dev/null 2>&1; then
  printf '%s\n' 'boot-guest accepted an invalid disk cache mode' >&2
  exit 1
fi
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
printf '%s\n' '{}' > "$test_dir/out/qemu-launch.json"
"$repo_dir/scripts/hvf/export-diagnostics" "$test_dir/out" "$test_dir/diagnostics.tar.gz" >/dev/null
test -s "$test_dir/diagnostics.tar.gz"
tar -tzf "$test_dir/diagnostics.tar.gz" | awk -F/ '$NF == "qemu-launch.json" {found=1} END {exit !found}' || {
  printf '%s\n' 'export-diagnostics omitted qemu-launch.json' >&2
  exit 1
}
jq -e '.files > 0' "$test_dir/out/diagnostics.json" >/dev/null

jq -n '{stable_runs:3,license_review:true,timing_acceptable:true,fresh_overlay:true,provenance:true,runtime_smoke:true,brew_test:true,brew_linkage:true}' \
  > "$test_dir/evidence.json"
"$repo_dir/scripts/hvf/promote" "$test_dir/evidence.json" "$test_dir/promotion.json" >/dev/null
jq -e '.trust == "production"' "$test_dir/promotion.json" >/dev/null

printf '%s\n' ok
