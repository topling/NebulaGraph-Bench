#!/usr/bin/env bash
# Fail if any k6 summary JSON under RESULT_DIR has checks.fails > 0.
set -euo pipefail

RESULT_DIR="${1:?usage: validate-stress-results.sh <result_dir>}"
shopt -s nullglob
files=("${RESULT_DIR}"/result_*.json)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "no result_*.json under ${RESULT_DIR}" >&2
  exit 1
fi

failed_files=0
python3 - <<'PY' "${files[@]}"
import json
import sys
from pathlib import Path

failed = []
for arg in sys.argv[1:]:
    path = Path(arg)
    with path.open(encoding="utf-8") as f:
        doc = json.load(f)
    checks = doc.get("metrics", {}).get("checks", {})
    fails = int(checks.get("fails", 0) or 0)
    if fails > 0:
        parts = path.stem.split("_", 2)
        case_name = parts[2] if len(parts) == 3 else path.stem
        vu = parts[1] if len(parts) >= 2 else "?"
        failed.append((path.name, case_name, vu, fails, int(checks.get("passes", 0) or 0)))

if failed:
    for name, case_name, vu, fails, passes in failed:
        print(f"FAIL {name}: case={case_name} vu={vu} checks fails={fails} passes={passes}", file=sys.stderr)
    print(f"{len(failed)} result file(s) with check failures", file=sys.stderr)
    sys.exit(1)

print(f"validated {len(sys.argv) - 1} result file(s), all checks passed")
PY
