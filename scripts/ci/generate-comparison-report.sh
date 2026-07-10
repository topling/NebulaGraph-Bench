#!/usr/bin/env bash
# Merge bench profile artifacts and export triple comparison report for CI.
set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${BENCH_ROOT}"

REPORT_DIR="${BENCH_ROOT}/output/comparison-report"
mkdir -p "${REPORT_DIR}"

find_profile_dir() {
  local profile="$1"
  local d
  d="$(ls -1dt "${BENCH_ROOT}/output/${profile}-"* 2>/dev/null | head -1 || true)"
  if [[ -z "${d}" || ! -d "${d}" ]]; then
    return 1
  fi
  echo "${d}"
}

rocksdb_dir=""
conservative_dir=""
enterprise_dir=""

for profile in rocksdb conservative enterprise; do
  if dir="$(find_profile_dir "${profile}")"; then
    echo "found ${profile}: ${dir}"
    case "${profile}" in
      rocksdb) rocksdb_dir="${dir}" ;;
      conservative) conservative_dir="${dir}" ;;
      enterprise) enterprise_dir="${dir}" ;;
    esac
    python3 run.py report export -f "${dir}" -o "${REPORT_DIR}/${profile}.html"
    python3 run.py report export -f "${dir}" -o "${REPORT_DIR}/${profile}.csv" -t csv
  else
    echo "warn: missing benchmark output for profile ${profile}" >&2
  fi
done

if [[ -z "${rocksdb_dir}" || -z "${conservative_dir}" || -z "${enterprise_dir}" ]]; then
  echo "need rocksdb, conservative and enterprise outputs for triple comparison" >&2
  exit 1
fi

python3 run.py report compare-triple \
  --rocksdb "${rocksdb_dir}" \
  --conservative "${conservative_dir}" \
  --enterprise "${enterprise_dir}" \
  -o "${REPORT_DIR}/comparison.html"

index="${REPORT_DIR}/index.html"
run_id="${GITHUB_RUN_ID:-local}"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local}/actions/runs/${run_id}"
{
  echo '<!DOCTYPE html>'
  echo '<html><head><meta charset="utf-8"><title>ToplingDB Benchmark Comparison</title></head><body>'
  echo '<h1>ToplingDB Benchmark Comparison</h1>'
  echo "<p>Workflow run: <a href=\"${run_url}\">${run_id}</a></p>"
  echo '<p><strong><a href="comparison.html">Triple comparison (charts + table)</a></strong></p>'
  echo '<h2>Per-profile reports</h2><ul>'
  for profile in rocksdb conservative enterprise; do
    echo "<li><a href=\"${profile}.html\">${profile}</a> (<a href=\"${profile}.csv\">csv</a>)</li>"
  done
  echo '</ul></body></html>'
} > "${index}"

echo "REPORT_DIR=${REPORT_DIR}"
ls -la "${REPORT_DIR}"
