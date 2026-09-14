#!/bin/sh
set -eu

export LC_ALL=C

repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-prefetch-test.XXXXXX")

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/bin" "$test_dir/cas"
cp "$repo_dir/test/fake-curl" "$test_dir/bin/curl"
chmod 755 "$test_dir/bin/curl"

content_sha=$(printf '%s\n' "prefetched artifact" | shasum -a 256 | awk '{print $1}')
url='https://example.test/source.tar.gz'
jq -n --arg url "$url" --arg sha "$content_sha" \
  '[{url:$url,sha256:$sha}]' > "$test_dir/sources.json"

PATH="$test_dir/bin:$PATH" \
  "$repo_dir/scripts/prefetch" "$test_dir/sources.json" "$test_dir/cas" "$test_dir/cas/urls.json" >/dev/null

first=$(printf '%s' "$content_sha" | cut -c 1-2)
second=$(printf '%s' "$content_sha" | cut -c 3-4)
test -s "$test_dir/cas/sha256/$first/$second/$content_sha"
jq -e --arg url "$url" --arg sha "$content_sha" '.[$url].sha256 == $sha' \
  "$test_dir/cas/urls.json" >/dev/null

jq -n --arg url "$url" '[{url:$url,sha256:("0" * 64)}]' > "$test_dir/bad.json"
if PATH="$test_dir/bin:$PATH" "$repo_dir/scripts/prefetch" "$test_dir/bad.json" "$test_dir/cas" "$test_dir/cas/urls.json" >/dev/null 2>&1; then
  printf '%s\n' "prefetch accepted a wrong checksum" >&2
  exit 1
fi
jq -e --arg url "$url" --arg sha "$content_sha" '.[$url].sha256 == $sha' \
  "$test_dir/cas/urls.json" >/dev/null

printf '%s\n' "ok"
