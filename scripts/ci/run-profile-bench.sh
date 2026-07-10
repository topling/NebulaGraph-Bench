#!/usr/bin/env bash
# Deploy standalone compose for a profile and run this repo's LDBC+k6 bench.
# Usage: run-profile-bench.sh <rocksdb|conservative|enterprise>
# Assumes images are already pullable / present locally. Does NOT compile Nebula.
set -euo pipefail

PROFILE="${1:?usage: run-profile-bench.sh rocksdb|conservative|enterprise}"
BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${BENCH_ROOT}"

SCALE="${SCALE_FACTOR:-0.1}"
STRESS_ARGS="${STRESS_ARGS:--d 3s}"
COMPOSE_DIR="${BENCH_ROOT}/e2e/standalone"
OUT_STAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="${BENCH_ROOT}/output/${PROFILE}-${OUT_STAMP}"

ROCKSDB_IMAGE="${ROCKSDB_IMAGE:-ghcr.io/topling/nebula-standalone-rocksdb:latest}"
TOPLING_IMAGE="${TOPLING_IMAGE:-ghcr.io/topling/nebula-standalone-topling:latest}"

case "${PROFILE}" in
  rocksdb)
    COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.rocksdb.yaml"
    export ROCKSDB_IMAGE
    ;;
  conservative|enterprise)
    COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.topling.yaml"
    export TOPLING_IMAGE
    export TOPLING_MIGRATE_PROFILE="${PROFILE}"
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
  docker compose -f "${COMPOSE_FILE}" "$@"
}

cleanup() {
  compose down -v --remove-orphans || true
}
trap cleanup EXIT

echo "=== profile=${PROFILE} image rocksdb=${ROCKSDB_IMAGE} topling=${TOPLING_IMAGE} ==="
if [[ "${ALLOW_MISSING_PULL:-0}" == "1" ]]; then
  compose pull || true
else
  compose pull
fi
compose up -d

echo "Waiting for graph port 9669..."
for i in $(seq 1 60); do
  if bash -c 'exec 3<>/dev/tcp/127.0.0.1/9669' 2>/dev/null; then
    echo "graph port ready"
    break
  fi
  if [[ "${i}" -eq 60 ]]; then
    echo "timeout waiting for 9669" >&2
    compose logs || true
    exit 1
  fi
  sleep 2
done
# Extra settle time for standalone init
sleep 5

mkdir -p "${RESULT_DIR}"
export NEBULA_ADDRESS="${NEBULA_ADDRESS:-127.0.0.1:9669}"

echo "=== generate LDBC data SF=${SCALE} ==="
python3 run.py data -s "${SCALE}"

echo "=== import ==="
python3 run.py nebula importer -a "${NEBULA_ADDRESS}"

echo "=== stress ${STRESS_ARGS} ==="
# Stress writes under output/<timestamp>/ via StressFactory; copy afterward.
python3 run.py stress run --args="${STRESS_ARGS}"

# Collect latest output folder into RESULT_DIR
latest="$(ls -1dt output/[0-9]* 2>/dev/null | head -1 || true)"
if [[ -n "${latest}" ]] && [[ -d "${latest}" ]]; then
  cp -a "${latest}/." "${RESULT_DIR}/"
  echo "Copied stress results from ${latest} -> ${RESULT_DIR}"
fi

compose logs > "${RESULT_DIR}/compose.log" 2>&1 || true
echo "RESULT_DIR=${RESULT_DIR}"
