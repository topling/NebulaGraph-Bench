#!/usr/bin/env bash
# Host-side build toolchain for Nebula / ToplingDB (compile on runner, not in Docker).
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "install-nebula-build-deps.sh supports Linux only" >&2
  exit 1
fi

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    ninja-build \
    git \
    curl \
    wget \
    ca-certificates \
    pkg-config \
    flex \
    bison \
    libssl-dev \
    libcurl4-openssl-dev \
    libreadline-dev \
    zlib1g-dev \
    libbz2-dev \
    libsnappy-dev \
    libzstd-dev \
    liblz4-dev \
    libgflags-dev \
    libgoogle-glog-dev \
    libevent-dev \
    libdouble-conversion-dev \
    libboost-all-dev
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y \
    gcc gcc-c++ make cmake3 git curl wget \
    flex bison openssl-devel readline-devel zlib-devel \
    snappy-devel lz4-devel libzstd-devel gflags-devel glog-devel \
    libevent-devel double-conversion-devel boost-devel
else
  echo "no supported package manager (apt-get/yum)" >&2
  exit 1
fi

command -v cmake >/dev/null
echo "nebula build deps ready"
