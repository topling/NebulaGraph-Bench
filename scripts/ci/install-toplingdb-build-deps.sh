#!/usr/bin/env bash
# ToplingDB build deps per toplingdb/README-zh_cn.md "Compile & run db_bench".
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "install-toplingdb-build-deps.sh supports Linux only" >&2
  exit 1
fi

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libjemalloc-dev \
    libaio-dev \
    libgflags-dev \
    zlib1g-dev \
    libbz2-dev \
    libcurl4-openssl-dev \
    liburing-dev \
    libsnappy-dev \
    liblz4-dev \
    libzstd-dev
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y \
    libaio-devel \
    gflags-devel \
    zlib-devel \
    bzip2-devel \
    libcurl-devel \
    liburing-devel \
    snappy-devel \
    jemalloc-devel
else
  echo "no supported package manager (apt-get/yum)" >&2
  exit 1
fi

echo "toplingdb build deps ready"
