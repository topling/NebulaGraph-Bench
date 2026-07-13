#!/usr/bin/env bash
# Deploy standalone compose for a profile and run microbench (no Nebula compile).
# Usage: run-profile-microbench.sh <rocksdb|conservative|enterprise>
set -euo pipefail

PROFILE="${1:?usage: run-profile-microbench.sh rocksdb|conservative|enterprise}"
BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${BENCH_ROOT}"

COMPOSE_DIR="${BENCH_ROOT}/e2e/standalone"
OUT_STAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="${RESULT_DIR:-${BENCH_ROOT}/output/microbench-${PROFILE}-${OUT_STAMP}}"
export RESULT_DIR PROFILE

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

if [[ -n "${NEBULA_ROOT:-}" ]] && [[ "${ALLOW_NEBULA_COMPILE:-0}" != "1" ]]; then
  echo "NEBULA_ROOT is set but nebula compile is not allowed (set ALLOW_NEBULA_COMPILE=1 to override)" >&2
  exit 1
fi

compose() {
  docker compose "${COMPOSE_ARGS[@]}" "$@"
}

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

cleanup() {
  compose down -v --remove-orphans || true
}
trap cleanup EXIT

mkdir -p "${RESULT_DIR}"

if [[ "${PROFILE}" == "enterprise" ]]; then
  prepare_enterprise_conf_override
fi

echo "=== pull + up profile=${PROFILE} ==="
compose pull
compose up -d
wait_for_graph_port "${PROFILE}"
bash "${BENCH_ROOT}/scripts/ci/wait-graph-ready.sh"

export COMPOSE_FILE
if [[ "${PROFILE}" == "rocksdb" ]]; then
  export COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.rocksdb.yaml"
else
  export COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.topling.yaml"
fi

export MICROBENCH_ADDRESS="${MICROBENCH_ADDRESS:-127.0.0.1:9669}"
bash "${BENCH_ROOT}/scripts/ci/run-microbench.sh"

echo "RESULT_DIR=${RESULT_DIR}"
