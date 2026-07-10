#!/usr/bin/env bash
# Strip ELF executables and shared libraries under a directory tree.
# Usage: strip-binaries.sh <install_or_lib_dir>
set -euo pipefail

ROOT="${1:?usage: strip-binaries.sh <dir>}"
if [[ ! -d "${ROOT}" ]]; then
  echo "not a directory: ${ROOT}" >&2
  exit 1
fi

if ! command -v strip >/dev/null 2>&1; then
  echo "strip not found" >&2
  exit 1
fi
if ! command -v file >/dev/null 2>&1; then
  echo "file not found" >&2
  exit 1
fi

echo "=== strip before (sample sizes) ==="
find "${ROOT}" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -111 \) 2>/dev/null \
  | head -20 | while read -r f; do ls -lh "$f"; done || true

stripped=0
failed=0
while IFS= read -r -d '' f; do
  ft="$(file -b "${f}" || true)"
  case "${ft}" in
    *ELF*"executable"*|*ELF*"shared object"*)
      before="$(stat -c%s "${f}" 2>/dev/null || stat -f%z "${f}")"
      if strip --strip-unneeded "${f}"; then
        after="$(stat -c%s "${f}" 2>/dev/null || stat -f%z "${f}")"
        echo "stripped ${f} (${before} -> ${after})"
        stripped=$((stripped + 1))
      else
        echo "strip failed: ${f}" >&2
        failed=$((failed + 1))
      fi
      ;;
  esac
done < <(find "${ROOT}" -type f -print0)

echo "=== strip summary: ${stripped} files, ${failed} failures ==="
if [[ "${failed}" -gt 0 ]]; then
  exit 1
fi
if [[ "${stripped}" -eq 0 ]]; then
  echo "ERROR: no ELF files were stripped under ${ROOT}" >&2
  exit 1
fi
