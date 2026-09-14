#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-batch-test.XXXXXX")

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

jq -n '{tag:"ventura",formulas:["csound","imagemagick"]}' > "$test_dir/batch.json"
jq -n '{csound:{ventura:{p95_seconds:2800}},imagemagick:{ventura:{p95_seconds:1200}}}' > "$test_dir/timings.json"
DISTILL_BATCH_BOOTSTRAP_SECONDS=600 DISTILL_BATCH_UPLOAD_SECONDS=90 DISTILL_BATCH_SAFETY_SECONDS=300 \
  "$repo_dir/scripts/batch-plan" "$test_dir/batch.json" "$test_dir/timings.json" "$test_dir/plan.json" >/dev/null
jq -e '.fits == true and .estimated_total_seconds == 4990 and .reserve_seconds == 3600' \
  "$test_dir/plan.json" >/dev/null

if DISTILL_BATCH_MAX_SECONDS=1000 "$repo_dir/scripts/batch-plan" \
  "$test_dir/batch.json" "$test_dir/timings.json" >/dev/null 2>&1; then
  printf '%s\n' "batch-plan accepted an over-budget batch" >&2
  exit 1
fi

printf '%s\n' "ok"
