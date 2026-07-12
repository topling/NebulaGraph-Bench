#!/usr/bin/env bash
# Deploy standalone compose for a profile and run this repo's LDBC+k6 bench.
# Usage: run-profile-bench.sh <rocksdb|conservative|enterprise>
# Assumes images are already pullable / present locally. Does NOT compile Nebula.
set -euo pipefail

PROFILE="${1:?usage: run-profile-bench.sh rocksdb|conservative|enterprise}"
BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${BENCH_ROOT}"

SCALE="${SCALE_FACTOR:-1}"
STRESS_ARGS="${STRESS_ARGS:--d 30s}"
COMPOSE_DIR="${BENCH_ROOT}/e2e/standalone"
OUT_STAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="${BENCH_ROOT}/output/${PROFILE}-${OUT_STAMP}"

ROCKSDB_IMAGE="${ROCKSDB_IMAGE:-ghcr.io/topling/nebula-standalone-rocksdb:latest}"
TOPLING_IMAGE="${TOPLING_IMAGE:-ghcr.io/topling/nebula-standalone-topling:latest}"

COMPOSE_ARGS=(-f)
case "${PROFILE}" in
  rocksdb)
    COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.rocksdb.yaml"
    COMPOSE_ARGS+=("${COMPOSE_FILE}")
    export ROCKSDB_IMAGE
    ;;
  conservative|enterprise)
    COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.topling.yaml"
    COMPOSE_ARGS+=("${COMPOSE_FILE}")
    export TOPLING_IMAGE
    export TOPLING_MIGRATE_PROFILE="${PROFILE}"
    case "${PROFILE}" in
      conservative)
        export TOPLINGDB_EASY_MIGRATE_CONF="/usr/local/nebula/etc/topling/topling-mimic-rocksdb.yaml"
        ;;
      enterprise)
        export TOPLINGDB_EASY_MIGRATE_CONF="/usr/local/nebula/etc/topling/topling-enterprise.yaml"
        ;;
    esac
    export ROCKSDB_KICK_OUT_OPTIONS_FILE="${ROCKSDB_KICK_OUT_OPTIONS_FILE:-1}"
    export TOPLINGDB_GetContext_sampling="${TOPLINGDB_GetContext_sampling:-kNone}"
    ;;
  *)
    echo "unknown profile: ${PROFILE}" >&2
    exit 1
    ;;
esac

# Fail fast if someone tries to compile nebula here
if [[ -n "${NEBULA_ROOT:-}" ]] && [[ "${ALLOW_NEBULA_COMPILE:-0}" != "1" ]]; then
  echo "NEBULA_ROOT is set but nebula compile is not allowed in run-profile-bench.sh (set ALLOW_NEBULA_COMPILE=1 to override)" >&2
  exit 1
fi

compose() {
  docker compose "${COMPOSE_ARGS[@]}" "$@"
}

# Extract image topling-enterprise.yaml and force selected knobs for CI runners.
prepare_enterprise_conf_override() {
  local wbs="${ENTERPRISE_WRITE_BUFFER_SIZE:-128M}"
  local zip_tmp="${ENTERPRISE_LOCAL_TEMP_DIR:-/tmp}"
  local out="${RESULT_DIR}/topling-enterprise.ci.yaml"
  local cid
  echo "=== enterprise conf override: write_buffer_size=${wbs} localTempDir=${zip_tmp} ==="
  mkdir -p "${RESULT_DIR}"
  cid="$(docker create "${TOPLING_IMAGE}")"
  docker cp "${cid}:/usr/local/nebula/etc/topling/topling-enterprise.yaml" "${out}"
  docker rm -f "${cid}" >/dev/null
  python3 - "${out}" "${wbs}" "${zip_tmp}" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
wbs = sys.argv[2]
zip_tmp = sys.argv[3]
text = path.read_text(encoding="utf-8")
patches = [
    (r"^([ \t]*write_buffer_size:\s*)\S+(.*)$", rf"\g<1>{wbs}\2", "write_buffer_size", wbs),
    (r"^([ \t]*localTempDir:\s*)\S+(.*)$", rf"\g<1>{zip_tmp}\2", "localTempDir", zip_tmp),
]
for pat, repl, name, value in patches:
    text, n = re.compile(pat, re.M).subn(repl, text, count=1)
    if n != 1:
        raise SystemExit(f"expected to patch exactly 1 {name}, patched={n}")
    print(f"patched {path} {name} -> {value}")
path.write_text(text, encoding="utf-8")
PY
  export TOPLING_ENTERPRISE_CONF_HOST="${out}"
  COMPOSE_ARGS+=(-f "${COMPOSE_DIR}/docker-compose.topling.enterprise-conf.yaml")
}

dump_compose_debug() {
  compose ps || true
  compose logs || true
}

wait_for_graph_port() {
  local label="${1:?}"
  echo "Waiting for graph service (${label})..."
  for i in $(seq 1 90); do
    if curl -sf "http://127.0.0.1:19669/status" >/dev/null 2>&1 \
      && bash -c 'exec 3<>/dev/tcp/127.0.0.1/9669' 2>/dev/null; then
      echo "graph service ready (${label})"
      return 0
    fi
    if [[ "${i}" -eq 90 ]]; then
      echo "timeout waiting for graph service (${label})" >&2
      dump_compose_debug
      return 1
    fi
    sleep 2
  done
}

restart_standalone_for_import() {
  echo "recycling standalone before import (fresh volumes)" >&2
  compose down -v --remove-orphans || true
  compose up -d
  wait_for_graph_port "pre-import-restart" || return 1
  sleep 10
}

cleanup() {
  compose down -v --remove-orphans || true
}
trap cleanup EXIT

mkdir -p "${RESULT_DIR}"
export NEBULA_ADDRESS="${NEBULA_ADDRESS:-127.0.0.1:9669}"
export NEBULA_REPLICA_FACTOR="${NEBULA_REPLICA_FACTOR:-1}"

echo "=== profile=${PROFILE} image rocksdb=${ROCKSDB_IMAGE} topling=${TOPLING_IMAGE} ==="
if [[ "${ALLOW_MISSING_PULL:-0}" == "1" ]]; then
  compose pull || true
else
  compose pull
fi
if [[ "${PROFILE}" == "enterprise" ]]; then
  prepare_enterprise_conf_override
fi
compose up -d

wait_for_graph_port "startup"
# Extra settle time for standalone init
sleep 5

echo "=== bootstrap LDBC datagen Maven deps ==="
bash "${BENCH_ROOT}/scripts/ci/bootstrap-dsol-xml-maven.sh"

echo "=== generate LDBC data SF=${SCALE} ==="
python3 run.py data -s "${SCALE}"

echo "=== import ==="
if ! curl -sf "http://127.0.0.1:19669/status" >/dev/null 2>&1 \
  || ! bash -c 'exec 3<>/dev/tcp/127.0.0.1/9669' 2>/dev/null; then
  restart_standalone_for_import || exit 1
fi
import_rc=0
python3 - "${RESULT_DIR}" "${NEBULA_ADDRESS}" <<'PY' || import_rc=$?
import json
import subprocess
import sys
import time
from pathlib import Path

result_dir = Path(sys.argv[1])
address = sys.argv[2]
cmd = ["python3", "run.py", "nebula", "importer", "-a", address]
t0 = time.perf_counter()
proc = subprocess.run(cmd)
duration = time.perf_counter() - t0
stats = {
    "duration_sec": round(duration, 3),
    "exit_code": proc.returncode,
    "command": " ".join(cmd),
}
out = result_dir / "import-stats.json"
out.write_text(json.dumps(stats, indent=2) + "\n", encoding="utf-8")
print(f"wrote {out} duration_sec={stats['duration_sec']} exit_code={stats['exit_code']}")
sys.exit(proc.returncode)
PY
if [[ "${import_rc}" -ne 0 ]]; then
  echo "nebula importer failed" >&2
  dump_compose_debug
  exit 1
fi

echo "=== stress ${STRESS_ARGS} ==="
bench_failed=0
if ! python3 run.py stress run --args="${STRESS_ARGS}"; then
  echo "stress test failed" >&2
  bench_failed=1
  dump_compose_debug
fi

if ! wait_for_graph_port "post-stress"; then
  echo "graph service unavailable after stress" >&2
  bench_failed=1
fi

# Collect latest output folder into RESULT_DIR
latest="$(ls -1dt output/[0-9]* 2>/dev/null | head -1 || true)"
if [[ -n "${latest}" ]] && [[ -d "${latest}" ]]; then
  cp -a "${latest}/." "${RESULT_DIR}/"
  echo "Copied stress results from ${latest} -> ${RESULT_DIR}"
fi

if ! bash "${BENCH_ROOT}/scripts/ci/validate-stress-results.sh" "${RESULT_DIR}"; then
  bench_failed=1
fi

compose logs > "${RESULT_DIR}/compose.log" 2>&1 || true

echo "=== collect engine logs and storage stats ==="
bash "${BENCH_ROOT}/scripts/ci/collect-profile-artifacts.sh" \
  "${RESULT_DIR}" "${COMPOSE_FILE}"

python3 "${BENCH_ROOT}/scripts/ci/write-benchmark-meta.py" \
  --result-dir "${RESULT_DIR}" \
  --profile "${PROFILE}" \
  --scale-factor "${SCALE}" \
  --stress-args "${STRESS_ARGS}" \
  --rocksdb-image "${ROCKSDB_IMAGE}" \
  --topling-image "${TOPLING_IMAGE}"

if [[ "${bench_failed}" -ne 0 ]]; then
  echo "bench failed for profile=${PROFILE}" >&2
  exit 1
fi

echo "RESULT_DIR=${RESULT_DIR}"
