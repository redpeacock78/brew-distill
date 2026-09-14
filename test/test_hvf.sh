#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-hvf-test.XXXXXX")
test_dir=$(cd "$test_dir" && pwd)

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/bin" "$test_dir/out"
cp "$repo_dir/test/fake-qemu" "$test_dir/bin/qemu-system-x86_64"
cp "$repo_dir/test/fake-qemu-img" "$test_dir/bin/qemu-img"
chmod 755 "$test_dir/bin/qemu-system-x86_64" "$test_dir/bin/qemu-img"

QEMU_SYSTEM_X86_64="$test_dir/bin/qemu-system-x86_64" \
  "$repo_dir/scripts/hvf/probe" "$test_dir/out"
jq -e '.host.hv_support == "1" and .qemu.hvf == true' "$test_dir/out/host-info.json" >/dev/null

printf '%s\n' base > "$test_dir/base.qcow2"
mkdir -p "$test_dir/overlays"
(
  cd "$test_dir"
  QEMU_IMG="$test_dir/bin/qemu-img" QEMU_IMG_LOG="$test_dir/qemu-img.log" \
    "$repo_dir/scripts/hvf/create-overlay" base.qcow2 overlays/overlay.qcow2
)
test -s "$test_dir/overlays/overlay.qcow2"
grep -Fqx -- "create -f qcow2 -F qcow2 -b $test_dir/base.qcow2 $test_dir/overlays/overlay.qcow2" "$test_dir/qemu-img.log"

if (
  cd "$test_dir"
  QEMU_IMG="$test_dir/bin/qemu-img" QEMU_IMG_LOG="$test_dir/qemu-img.log" \
    "$repo_dir/scripts/hvf/create-overlay" base.qcow2 overlays/overlay.qcow2
) >/dev/null 2>&1; then
  printf '%s\n' "create-overlay overwrote an existing overlay" >&2
  exit 1
fi

printf '%s\n' "ok"
