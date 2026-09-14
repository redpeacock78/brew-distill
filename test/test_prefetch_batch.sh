#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-prefetch-batch-test.XXXXXX")

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/bin"
cp "$repo_dir/test/fake-curl" "$test_dir/bin/curl"
chmod 755 "$test_dir/bin/curl"
content_sha=$(printf '%s\n' 'prefetched artifact' | shasum -a 256 | awk '{print $1}')
url='https://example.test/source.tar.gz'

check_prefetched() {
  cas_dir=$1
  mapping=$2
  first=$(printf '%s' "$content_sha" | cut -c 1-2)
  second=$(printf '%s' "$content_sha" | cut -c 3-4)
  test -s "$cas_dir/sha256/$first/$second/$content_sha"
  jq -e --arg url "$url" --arg sha "$content_sha" '.[$url].sha256 == $sha' \
    "$mapping" >/dev/null
}

jq -n --arg url "$url" --arg sha "$content_sha" \
  '{formulas:["dummy"],artifacts:[{url:$url,sha256:$sha}]}' \
  > "$test_dir/artifacts-batch.json"
PATH="$test_dir/bin:$PATH" "$repo_dir/scripts/prefetch-batch" \
  "$test_dir/artifacts-batch.json" "$test_dir/artifacts-cas" \
  "$test_dir/artifacts-cas/urls.json" >/dev/null
check_prefetched "$test_dir/artifacts-cas" "$test_dir/artifacts-cas/urls.json"

jq -n --arg url "$url" --arg sha "$content_sha" \
  '{formulas:["dummy"],prefetch:[{url:$url,sha256:$sha}]}' \
  > "$test_dir/prefetch-array-batch.json"
PATH="$test_dir/bin:$PATH" "$repo_dir/scripts/prefetch-batch" \
  "$test_dir/prefetch-array-batch.json" "$test_dir/array-cas" \
  "$test_dir/array-cas/urls.json" >/dev/null
check_prefetched "$test_dir/array-cas" "$test_dir/array-cas/urls.json"

jq -n --arg url "$url" --arg sha "$content_sha" \
  '[{url:$url,sha256:$sha}]' > "$test_dir/sources.json"
jq -n '{formulas:["dummy"],prefetch:"sources.json"}' \
  > "$test_dir/prefetch-file-batch.json"
PATH="$test_dir/bin:$PATH" "$repo_dir/scripts/prefetch-batch" \
  "$test_dir/prefetch-file-batch.json" "$test_dir/file-cas" \
  "$test_dir/file-cas/urls.json" >/dev/null
check_prefetched "$test_dir/file-cas" "$test_dir/file-cas/urls.json"

jq -n '{formulas:["dummy"]}' > "$test_dir/no-prefetch-batch.json"
test "$(PATH="$test_dir/bin:$PATH" "$repo_dir/scripts/prefetch-batch" \
  "$test_dir/no-prefetch-batch.json" "$test_dir/none-cas" \
  "$test_dir/none-cas/urls.json")" = 'prefetch-batch: no source artifacts'

printf '%s\n' ok
