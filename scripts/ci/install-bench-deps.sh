#!/usr/bin/env bash
# Install bench-side dependencies aligned with .github/workflows/nebula-bench.yaml
# (Python/JDK/Maven/Go/Hadoop cache + scripts/setup.sh). Intended to run inside
# each CI matrix job. For local use, assumes apt packages may already exist.
set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${BENCH_ROOT}"

echo "=== install-bench-deps (bench root: ${BENCH_ROOT}) ==="

if [[ "${INSTALL_SYSTEM_DEPS:-0}" == "1" ]] && command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git wget curl file python3 python3-pip python3-dev \
    openjdk-8-jdk maven build-essential
fi

python3 -m pip install --upgrade pip
python3 -m pip install -r requirements.txt

export CGO_ENABLED="${CGO_ENABLED:-0}"
if [[ ! -x "${BENCH_ROOT}/scripts/k6" ]] || [[ ! -x "${BENCH_ROOT}/scripts/nebula-importer" ]]; then
  echo "Building importer + k6 via scripts/setup.sh"
  /bin/bash "${BENCH_ROOT}/scripts/setup.sh"
else
  echo "scripts/k6 and scripts/nebula-importer already present"
fi

echo "=== install-bench-deps done ==="
