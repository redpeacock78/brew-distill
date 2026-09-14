#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-gateway-test.XXXXXX")
port=18080

cleanup() {
  if [ -n "${gateway_pid:-}" ]; then
    kill "$gateway_pid" 2>/dev/null || true
    wait "$gateway_pid" 2>/dev/null || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

content='gateway-content'
sha=$(printf '%s' "$content" | shasum -a 256 | awk '{print $1}')
first=$(printf '%s' "$sha" | cut -c 1-2)
second=$(printf '%s' "$sha" | cut -c 3-4)
mkdir -p "$test_dir/cas/sha256/$first/$second"
printf '%s' "$content" > "$test_dir/cas/sha256/$first/$second/$sha"
manifest='{"schemaVersion":2,"manifests":[]}'
manifest_sha=$(printf '%s' "$manifest" | shasum -a 256 | awk '{print $1}')
manifest_first=$(printf '%s' "$manifest_sha" | cut -c 1-2)
manifest_second=$(printf '%s' "$manifest_sha" | cut -c 3-4)
mkdir -p "$test_dir/cas/sha256/$manifest_first/$manifest_second"
printf '%s' "$manifest" > "$test_dir/cas/sha256/$manifest_first/$manifest_second/$manifest_sha"
jq -n --arg sha "$sha" --arg manifest_sha "$manifest_sha" \
  '{"https://example.test/source.tar.gz":{sha256:$sha},"https://ghcr.io/v2/homebrew/core/demo/manifests/1.0":{sha256:$manifest_sha}}' \
  > "$test_dir/cas/urls.json"

"$repo_dir/cas-gateway" --root "$test_dir/cas" --mapping "$test_dir/cas/urls.json" --port "$port" > "$test_dir/gateway.log" 2>&1 &
gateway_pid=$!

ready=0
attempt=0
while [ "$attempt" -lt 20 ]; do
  if curl -fsSI "http://127.0.0.1:$port/sha256/$first/$second/$sha" >/dev/null 2>&1; then
    ready=1
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done
test "$ready" -eq 1

test "$(curl -fsS --range 1-5 "http://127.0.0.1:$port/sha256/$first/$second/$sha")" = "atewa"
test "$(curl -fsS "http://127.0.0.1:$port/https://example.test/source.tar.gz")" = "$content"
test "$(curl -fsS "http://127.0.0.1:$port/v2/homebrew/core/demo/manifests/1.0")" = "$manifest"
test "$(curl -fsS "http://127.0.0.1:$port/v2/homebrew/core/demo/blobs/sha256:$sha")" = "$content"
curl -fsSI "http://127.0.0.1:$port/v2/homebrew/core/demo/manifests/1.0" | grep -Fi 'Content-Type: application/vnd.oci.image.index.v1+json' >/dev/null
curl -fsSI "http://127.0.0.1:$port/v2/homebrew/core/demo/blobs/sha256:$sha" | grep -Fi "Docker-Content-Digest: sha256:$sha" >/dev/null
test "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/v2/homebrew/core/demo/manifests/1.0")" = 405
if curl -fsS "http://127.0.0.1:$port/sha256/ff/ff/$sha" >/dev/null 2>&1; then
  printf '%s\n' "gateway ignored the CAS shard path" >&2
  exit 1
fi
if curl -fsS "http://127.0.0.1:$port/https://example.test/missing.tar.gz" >/dev/null 2>&1; then
  printf '%s\n' "gateway served an unmapped URL" >&2
  exit 1
fi

printf '%s\n' "ok"
