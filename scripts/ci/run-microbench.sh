#!/usr/bin/env bash
# Run microbench stages against an already-up standalone (address 9669).
# Stages: insert → lookup load → query pre → compact lookup → query post
set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${BENCH_ROOT}"

RESULT_DIR="${RESULT_DIR:?RESULT_DIR required}"
PROFILE="${PROFILE:?PROFILE required}"
ADDRESS="${MICROBENCH_ADDRESS:-127.0.0.1:9669}"
export MICROBENCH_ADDRESS="${ADDRESS}"
export MICROBENCH_USER="${MICROBENCH_USER:-root}"
export MICROBENCH_PASSWORD="${MICROBENCH_PASSWORD:-nebula}"
export MICROBENCH_GRAPH_DELAY="${MICROBENCH_GRAPH_DELAY:-5}"
export MICROBENCH_STORAGE_JSON="${RESULT_DIR}/storage-record.json"
export PYTHONPATH="${BENCH_ROOT}${PYTHONPATH:+:${PYTHONPATH}}"

mkdir -p "${RESULT_DIR}"
: >"${RESULT_DIR}/run-microbench.log"

resolve_data_dir() {
  local compose_file="${1:?}"
  local cid
  cid="$(docker compose -f "${compose_file}" ps -aq nebula-standalone 2>/dev/null | head -1 || true)"
  if [[ -z "${cid}" ]]; then
    echo "warn: no nebula-standalone container; MICROBENCH_DATA_DIR unset" >&2
    return 0
  fi
  local mount
  mount="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/usr/local/nebula/data"}}{{.Source}}{{end}}{{end}}' "${cid}" 2>/dev/null || true)"
  if [[ -n "${mount}" && -d "${mount}" ]]; then
    export MICROBENCH_DATA_DIR="${mount}"
    echo "MICROBENCH_DATA_DIR=${MICROBENCH_DATA_DIR}"
  else
    echo "warn: could not resolve host data mount" >&2
  fi
}

if [[ -n "${COMPOSE_FILE:-}" ]]; then
  resolve_data_dir "${COMPOSE_FILE}"
fi

PYTEST=(python3 -m pytest -v --benchmark-only --benchmark-warmup=off)

run_pytest() {
  local label="$1"
  shift
  echo "=== microbench ${PROFILE}: ${label} ===" | tee -a "${RESULT_DIR}/run-microbench.log"
  "${PYTEST[@]}" "$@" 2>&1 | tee -a "${RESULT_DIR}/run-microbench.log"
}

# 1) insert (write + compact + drop in fixture teardown)
run_pytest insert \
  microbench/insert.py \
  --benchmark-json="${RESULT_DIR}/benchmark-insert.json"

# 2) lookup load
export MICROBENCH_LOOKUP_PHASE=load
run_pytest lookup_load \
  microbench/lookup.py -k test_load \
  --benchmark-json="${RESULT_DIR}/benchmark-lookup-load.json"

# 3) lookup query pre-compact
export MICROBENCH_LOOKUP_PHASE=query_pre
run_pytest lookup_query_pre \
  microbench/lookup.py -k test_query \
  --benchmark-json="${RESULT_DIR}/benchmark-lookup-query-pre.json"

# 4) compact lookup space
python3 - <<'PY'
import json
import os
from pathlib import Path
from microbench.suite import suite_from_env

s = suite_from_env()
s.connect()
try:
    result = s.run_compact_job("benchlookupspace")
    out = Path(os.environ["RESULT_DIR"]) / "compact-lookup.json"
    out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"lookup compact done: {result}")
finally:
    s.close()
PY

# 5) lookup query post-compact (+ drop)
export MICROBENCH_LOOKUP_PHASE=query_post
run_pytest lookup_query_post \
  microbench/lookup.py -k test_query \
  --benchmark-json="${RESULT_DIR}/benchmark-lookup-query-post.json"

python3 "${BENCH_ROOT}/scripts/ci/write-microbench-meta.py" \
  --result-dir "${RESULT_DIR}" \
  --profile "${PROFILE}"

echo "run-microbench finished profile=${PROFILE} result_dir=${RESULT_DIR}"
