#!/usr/bin/env bash
set -euo pipefail

PREFIX="${NEBULA_PREFIX:-/usr/local/nebula}"
CONF="${PREFIX}/etc/nebula-standalone.conf"
LIB_DIR="${PREFIX}/lib"
PROFILE="${TOPLING_MIGRATE_PROFILE:-enterprise}"

case "${PROFILE}" in
  conservative)
    MIGRATE_YAML="${PREFIX}/etc/topling/topling-mimic-rocksdb.yaml"
    ;;
  enterprise)
    MIGRATE_YAML="${PREFIX}/etc/topling/topling-enterprise.yaml"
    ;;
  *)
    echo "Unknown TOPLING_MIGRATE_PROFILE=${PROFILE} (expected conservative|enterprise)" >&2
    exit 1
    ;;
esac

if [[ ! -f "${MIGRATE_YAML}" ]]; then
  echo "Easy Migrate config not found: ${MIGRATE_YAML}" >&2
  exit 1
fi
if [[ ! -x "${PREFIX}/bin/nebula-standalone" ]]; then
  echo "nebula-standalone not found under ${PREFIX}/bin" >&2
  exit 1
fi
if [[ ! -f "${CONF}" ]]; then
  echo "config not found: ${CONF}" >&2
  exit 1
fi

export LD_LIBRARY_PATH="${LIB_DIR}:${LD_LIBRARY_PATH:-}"
export TOPLINGDB_EASY_MIGRATE_CONF="${MIGRATE_YAML}"
export ROCKSDB_KICK_OUT_OPTIONS_FILE=1
export TOPLINGDB_GetContext_sampling=kNone

exec "${PREFIX}/bin/nebula-standalone" \
  --flagfile="${CONF}" \
  --daemonize=false \
  --containerized=true \
  "$@"
