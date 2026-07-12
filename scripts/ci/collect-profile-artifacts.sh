#!/usr/bin/env bash
# Collect engine logs and on-disk storage stats into RESULT_DIR (before compose teardown).
set -euo pipefail

RESULT_DIR="${1:?usage: collect-profile-artifacts.sh <result_dir>}"
COMPOSE_FILE="${2:?usage: collect-profile-artifacts.sh <result_dir> <compose_file>}"

compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

cid="$(compose ps -q nebula-standalone 2>/dev/null || true)"
if [[ -z "${cid}" ]]; then
  echo "warn: no running nebula-standalone container; skip artifact collection" >&2
  exit 0
fi

mkdir -p "${RESULT_DIR}/engine-logs"
if docker cp "${cid}:/usr/local/nebula/logs/." "${RESULT_DIR}/engine-logs/" 2>/dev/null; then
  echo "collected engine logs -> ${RESULT_DIR}/engine-logs"
else
  echo "warn: failed to copy engine logs from ${cid}" >&2
fi

storage_json="${RESULT_DIR}/storage-stats.json"
mapfile -t _stats < <(docker exec "${cid}" bash -lc '
  set -euo pipefail
  data_dir=/usr/local/nebula/data
  du_disk() { echo $(( $(du -sk "$1" | cut -f1) * 1024 )); }
  du_apparent() { du -sb "$1" | cut -f1; }
  if [[ ! -d "${data_dir}" ]]; then
    echo "error:data dir not found: ${data_dir}" >&2
    exit 1
  fi
  storage_disk=0; storage_apparent=0; meta_disk=0; meta_apparent=0
  if [[ -d "${data_dir}/storage" ]]; then
    storage_disk=$(du_disk "${data_dir}/storage")
    storage_apparent=$(du_apparent "${data_dir}/storage")
  fi
  if [[ -d "${data_dir}/meta" ]]; then
    meta_disk=$(du_disk "${data_dir}/meta")
    meta_apparent=$(du_apparent "${data_dir}/meta")
  fi
  data_disk=$(du_disk "${data_dir}")
  data_apparent=$(du_apparent "${data_dir}")
  printf "%s\n" "${data_disk}" "${data_apparent}" "${storage_disk}" "${storage_apparent}" "${meta_disk}" "${meta_apparent}"
')

data_disk="${_stats[0]}"
data_apparent="${_stats[1]}"
storage_disk="${_stats[2]}"
storage_apparent="${_stats[3]}"
meta_disk="${_stats[4]}"
meta_apparent="${_stats[5]}"

cat > "${storage_json}" <<EOF
{
  "measurement_stage": "post_import_pre_teardown",
  "measurement_methods": {
    "disk_bytes": "du -sk (actual blocks allocated)",
    "apparent_bytes": "du -sb (logical file sizes)"
  },
  "data_dir": "/usr/local/nebula/data",
  "data_dir_disk_bytes": ${data_disk},
  "data_dir_apparent_bytes": ${data_apparent},
  "storage_disk_bytes": ${storage_disk},
  "storage_apparent_bytes": ${storage_apparent},
  "meta_disk_bytes": ${meta_disk},
  "meta_apparent_bytes": ${meta_apparent}
}
EOF
echo "wrote ${storage_json}"
