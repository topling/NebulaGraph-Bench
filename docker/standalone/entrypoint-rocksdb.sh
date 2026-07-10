#!/usr/bin/env bash
set -euo pipefail

PREFIX="${NEBULA_PREFIX:-/usr/local/nebula}"
CONF="${PREFIX}/etc/nebula-standalone.conf"

if [[ ! -x "${PREFIX}/bin/nebula-standalone" ]]; then
  echo "nebula-standalone not found under ${PREFIX}/bin" >&2
  exit 1
fi
if [[ ! -f "${CONF}" ]]; then
  echo "config not found: ${CONF}" >&2
  exit 1
fi

exec "${PREFIX}/bin/nebula-standalone" \
  --flagfile="${CONF}" \
  --daemonize=false \
  --containerized=true \
  "$@"
