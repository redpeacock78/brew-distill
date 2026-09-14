#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-tiny-linux-test.XXXXXX")
test_dir=$(cd "$test_dir" && pwd)

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/bin" "$test_dir/out"
printf '%s\n' kernel > "$test_dir/kernel"
printf '%s\n' initrd > "$test_dir/initrd"
printf '%s\n' disk > "$test_dir/disk.qcow2"
cat > "$test_dir/bin/qemu-system-x86_64" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" > "$QEMU_LOG"
EOF
chmod 755 "$test_dir/bin/qemu-system-x86_64"

DISTILL_ALLOW_NON_DARWIN=1 \
DISTILL_LINUX_KERNEL="$test_dir/kernel" \
DISTILL_LINUX_INITRD="$test_dir/initrd" \
QEMU_SYSTEM_X86_64="$test_dir/bin/qemu-system-x86_64" \
QEMU_LOG="$test_dir/qemu.log" \
  "$repo_dir/scripts/hvf/tiny-linux" "$test_dir/disk.qcow2" "$test_dir/out" >/dev/null

grep -F -- '-accel hvf' "$test_dir/qemu.log" >/dev/null
grep -F -- "-kernel $test_dir/kernel" "$test_dir/qemu.log" >/dev/null
grep -F -- "-initrd $test_dir/initrd" "$test_dir/qemu.log" >/dev/null
if ! grep -F -- "-drive file=$test_dir/disk.qcow2,format=qcow2" "$test_dir/qemu.log" >/dev/null; then
  cat "$test_dir/qemu.log" >&2
  exit 1
fi

printf '%s\n' ok
