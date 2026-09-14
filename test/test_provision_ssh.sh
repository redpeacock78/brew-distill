#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-provision-ssh-test.XXXXXX")

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/bin" "$test_dir/home" "$test_dir/out"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey guest' > "$test_dir/public-key"

cat > "$test_dir/bin/uname" <<'EOF'
#!/bin/sh
printf '%s\n' Darwin
EOF
cat > "$test_dir/bin/id" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -u) printf '%s\n' 0 ;;
  -gn) printf '%s\n' staff ;;
  distill) exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat > "$test_dir/bin/dscl" <<'EOF'
#!/bin/sh
printf '%s\n' "NFSHomeDirectory: $FAKE_HOME"
EOF
cat > "$test_dir/bin/install" <<'EOF'
#!/bin/sh
set -eu
path=
for argument in "$@"; do
  path=$argument
done
mkdir -p "$path"
EOF
cat > "$test_dir/bin/chown" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$test_dir/bin/systemsetup" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$SYSTEMSETUP_LOG"
EOF
cat > "$test_dir/bin/ssh-keygen" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -lf) printf '%s\n' '256 SHA256:test-fingerprint guest (ED25519)' ;;
  *) exit 2 ;;
esac
EOF
chmod 755 "$test_dir/bin"/*

PATH="$test_dir/bin:$PATH" \
FAKE_HOME="$test_dir/home" \
SYSTEMSETUP_LOG="$test_dir/systemsetup.log" \
DISTILL_GUEST=1 \
DISTILL_GUEST_SSH_USER=distill \
DISTILL_GUEST_SSH_PUBLIC_KEY_FILE="$test_dir/public-key" \
  "$repo_dir/scripts/hvf/provision-ssh" "$test_dir/out" >/dev/null

test -s "$test_dir/home/.ssh/authorized_keys"
grep -Fqx -- 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey guest' \
  "$test_dir/home/.ssh/authorized_keys"
grep -Fqx -- '-setremotelogin on' "$test_dir/systemsetup.log"
jq -e '.user == "distill" and .remote_login == true and .public_key_fingerprint == "SHA256:test-fingerprint"' \
  "$test_dir/out/ssh-ready.json" >/dev/null

printf '%s\n' ok
