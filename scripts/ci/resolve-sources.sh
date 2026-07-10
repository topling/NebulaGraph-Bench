#!/usr/bin/env bash
# Resolve Nebula / ToplingDB source trees for local or CI layouts.
# Exports: BENCH_ROOT, and any of NEBULA_ROCKSDB_ROOT / NEBULA_TOPLING_ROOT / TOPLINGDB_ROOT
# that can be found (missing ones stay empty unless already set).
set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export BENCH_ROOT

_first_existing() {
  local d
  for d in "$@"; do
    [[ -n "${d}" ]] || continue
    if [[ -d "${d}" ]]; then
      echo "${d}"
      return 0
    fi
  done
  return 1
}

if [[ -z "${NEBULA_ROCKSDB_ROOT:-}" ]]; then
  NEBULA_ROCKSDB_ROOT="$(_first_existing \
    "${BENCH_ROOT}/deps/nebulagraph" \
    "${BENCH_ROOT}/../nebulagraph" \
    || true)"
fi
export NEBULA_ROCKSDB_ROOT="${NEBULA_ROCKSDB_ROOT:-}"

if [[ -z "${NEBULA_TOPLING_ROOT:-}" ]]; then
  NEBULA_TOPLING_ROOT="$(_first_existing \
    "${BENCH_ROOT}/deps/nebulagraph-toplingdb" \
    "${BENCH_ROOT}/../nebulagraph-toplingdb" \
    "${BENCH_ROOT}/deps/nebula" \
    || true)"
fi
export NEBULA_TOPLING_ROOT="${NEBULA_TOPLING_ROOT:-}"

if [[ -z "${TOPLINGDB_ROOT:-}" ]]; then
  TOPLINGDB_ROOT="$(_first_existing \
    "${BENCH_ROOT}/deps/toplingdb" \
    "${BENCH_ROOT}/../toplingdb" \
    "${NEBULA_TOPLING_ROOT:+${NEBULA_TOPLING_ROOT}/../toplingdb}" \
    || true)"
fi
export TOPLINGDB_ROOT="${TOPLINGDB_ROOT:-}"

echo "BENCH_ROOT=${BENCH_ROOT}"
echo "NEBULA_ROCKSDB_ROOT=${NEBULA_ROCKSDB_ROOT:-<unset>}"
echo "NEBULA_TOPLING_ROOT=${NEBULA_TOPLING_ROOT:-<unset>}"
echo "TOPLINGDB_ROOT=${TOPLINGDB_ROOT:-<unset>}"
