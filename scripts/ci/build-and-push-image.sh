#!/usr/bin/env bash
# Build Nebula standalone, strip binaries/*.so, docker build, optional push to GHCR.
# Usage: build-and-push-image.sh rocksdb|topling [--push] [--tag TAG] [--latest]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-sources.sh
source "${SCRIPT_DIR}/resolve-sources.sh"

VARIANT="${1:?usage: build-and-push-image.sh rocksdb|topling [--push] [--tag TAG] [--latest]}"
shift || true

DO_PUSH=0
DO_LATEST=0
IMAGE_TAG="${IMAGE_TAG:-}"
GHCR_OWNER="${GHCR_OWNER:-topling}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push) DO_PUSH=1; shift ;;
    --latest) DO_LATEST=1; shift ;;
    --tag) IMAGE_TAG="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

case "${VARIANT}" in
  rocksdb|topling) ;;
  *) echo "variant must be rocksdb|topling" >&2; exit 1 ;;
esac

prepare_install_conf() {
  local install_dir="$1"
  local src_default="${install_dir}/etc/nebula-standalone.conf.default"
  local dst="${install_dir}/etc/nebula-standalone.conf"
  if [[ -f "${src_default}" ]]; then
    cp -f "${src_default}" "${dst}"
  elif [[ ! -f "${dst}" ]]; then
    echo "missing standalone conf under ${install_dir}/etc" >&2
    exit 1
  fi
  # Ensure daemonize default in file does not matter; entrypoint overrides CLI flags.
  mkdir -p "${install_dir}"/{logs,data,pids}
}

cmake_build_standalone() {
  local build_dir="$1"
  echo "=== cmake build target nebula-standalone (jobs=$(nproc)) ==="
  cmake --build "${build_dir}" --target nebula-standalone -j"$(nproc)"
}

cmake_install_standalone() {
  local build_dir="$1"
  echo "=== cmake install standalone (components graph, common) ==="
  cmake --install "${build_dir}" --component common
  cmake --install "${build_dir}" --component graph
}

build_rocksdb() {
  local nebula_root="${NEBULA_ROCKSDB_ROOT:?NEBULA_ROCKSDB_ROOT not set; checkout vesoft-inc/nebula or set path}"
  local build_dir="${nebula_root}/build-standalone-rocksdb"
  local install_dir="${nebula_root}/install-standalone-rocksdb"

  mkdir -p "${build_dir}"
  cd "${build_dir}"
  cmake "${nebula_root}" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DENABLE_STANDALONE_VERSION=ON \
    -DENABLE_TESTING=OFF \
    -DENABLE_WERROR=OFF \
    -DCMAKE_INSTALL_PREFIX="${install_dir}"
  cmake_build_standalone "${build_dir}"
  rm -rf "${install_dir}"
  cmake_install_standalone "${build_dir}"
  prepare_install_conf "${install_dir}"
  bash "${SCRIPT_DIR}/strip-binaries.sh" "${install_dir}"
}

build_topling() {
  local nebula_root="${NEBULA_TOPLING_ROOT:?NEBULA_TOPLING_ROOT not set; checkout topling/nebula or set path}"
  local build_dir="${nebula_root}/build-standalone-topling"
  local install_dir="${nebula_root}/install-standalone-topling"
  local toplingdb_dir="${build_dir}/toplingdb"

  mkdir -p "${build_dir}"
  # InstallToplingDB.cmake uses ${build_dir}/toplingdb; symlink a pinned checkout when provided.
  if [[ -n "${TOPLINGDB_ROOT:-}" && -d "${TOPLINGDB_ROOT}" ]]; then
    ln -sfn "$(cd "${TOPLINGDB_ROOT}" && pwd)" "${toplingdb_dir}"
  fi
  cd "${build_dir}"
  cmake "${nebula_root}" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DENABLE_STANDALONE_VERSION=ON \
    -DENABLE_TESTING=OFF \
    -DENABLE_WERROR=OFF \
    -DCMAKE_INSTALL_PREFIX="${install_dir}"
  cmake_build_standalone "${build_dir}"
  rm -rf "${install_dir}"
  cmake_install_standalone "${build_dir}"
  prepare_install_conf "${install_dir}"

  mkdir -p "${install_dir}/etc/topling"
  cp -f "${nebula_root}/conf/topling-mimic-rocksdb.yaml" "${install_dir}/etc/topling/"
  cp -f "${nebula_root}/conf/topling-enterprise.yaml" "${install_dir}/etc/topling/"

  bash "${SCRIPT_DIR}/strip-binaries.sh" "${install_dir}"
}

docker_package() {
  local variant="$1"
  local install_dir="$2"
  local ctx="${BENCH_ROOT}/.docker-build-ctx-${variant}"
  local dockerfile="${BENCH_ROOT}/docker/standalone/Dockerfile.${variant}"
  local entry="entrypoint-${variant}.sh"
  local image_name="ghcr.io/${GHCR_OWNER}/nebula-standalone-${variant}"

  if [[ -z "${IMAGE_TAG}" ]]; then
    if [[ "${variant}" == "rocksdb" ]]; then
      IMAGE_TAG="$(git -C "${NEBULA_ROCKSDB_ROOT}" rev-parse --short HEAD)"
    else
      IMAGE_TAG="$(git -C "${NEBULA_TOPLING_ROOT}" rev-parse --short HEAD)"
    fi
  fi

  rm -rf "${ctx}"
  mkdir -p "${ctx}"
  cp -a "${install_dir}" "${ctx}/install"
  cp -f "${BENCH_ROOT}/docker/standalone/${entry}" "${ctx}/"
  cp -f "${dockerfile}" "${ctx}/Dockerfile"

  local full_tag="${image_name}:${IMAGE_TAG}"
  echo "Building docker image ${full_tag}"
  docker build -t "${full_tag}" -f "${ctx}/Dockerfile" "${ctx}"

  if [[ "${DO_LATEST}" -eq 1 ]]; then
    docker tag "${full_tag}" "${image_name}:latest"
  fi

  if [[ "${DO_PUSH}" -eq 1 ]]; then
    echo "Pushing ${full_tag}"
    docker push "${full_tag}"
    if [[ "${DO_LATEST}" -eq 1 ]]; then
      docker push "${image_name}:latest"
    fi
  fi

  echo "IMAGE_REF=${full_tag}"
  if [[ "${DO_LATEST}" -eq 1 ]]; then
    echo "IMAGE_LATEST=${image_name}:latest"
  fi
  # GitHub Actions job summary
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## nebula-standalone-${variant}"
      echo "- image: \`${full_tag}\`"
      if [[ "${DO_LATEST}" -eq 1 ]]; then
        echo "- also tagged: \`${image_name}:latest\`"
      fi
    } >> "${GITHUB_STEP_SUMMARY}"
  fi

  rm -rf "${ctx}"
}

main() {
  local install_dir
  if [[ "${VARIANT}" == "rocksdb" ]]; then
    install_dir="${NEBULA_ROCKSDB_ROOT:?NEBULA_ROCKSDB_ROOT not set}/install-standalone-rocksdb"
    build_rocksdb
  else
    install_dir="${NEBULA_TOPLING_ROOT:?NEBULA_TOPLING_ROOT not set}/install-standalone-topling"
    build_topling
  fi
  docker_package "${VARIANT}" "${install_dir}"
}

main
