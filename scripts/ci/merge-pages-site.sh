#!/usr/bin/env bash
# Merge a run into a pages site tree and prepend a row on the index table.
# Usage:
#   merge-pages-site.sh <site_root> <kind> <run_id> <report_src_dir> <published_at_iso>
# kind: microbench | ldbcbench
set -euo pipefail

SITE_ROOT="${1:?site_root}"
KIND="${2:?kind microbench|ldbcbench}"
RUN_ID="${3:?run_id}"
REPORT_SRC="${4:?report_src_dir}"
PUBLISHED_AT="${5:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
ACTIONS_URL="${ACTIONS_URL:-}"

case "${KIND}" in
  microbench|ldbcbench) ;;
  *) echo "kind must be microbench|ldbcbench" >&2; exit 1 ;;
esac

mkdir -p "${SITE_ROOT}"
RUNS_JSON="${SITE_ROOT}/runs.json"
INDEX_HTML="${SITE_ROOT}/index.html"

python3 - "${SITE_ROOT}" "${KIND}" "${RUN_ID}" "${REPORT_SRC}" "${PUBLISHED_AT}" "${ACTIONS_URL}" <<'PY'
from __future__ import annotations

import html
import json
import shutil
import sys
from pathlib import Path

site_root = Path(sys.argv[1])
kind = sys.argv[2]
run_id = sys.argv[3]
report_src = Path(sys.argv[4])
published_at = sys.argv[5]
actions_url = sys.argv[6]

if kind == "microbench":
    rel_report = f"microbench/runs/{run_id}/report.html"
    dest = site_root / "microbench" / "runs" / run_id
else:
    rel_report = f"ldbcbench/runs/{run_id}/comparison.html"
    dest = site_root / "ldbcbench" / "runs" / run_id

dest.mkdir(parents=True, exist_ok=True)
if not report_src.is_dir():
    raise SystemExit(f"report_src not a directory: {report_src}")
for item in report_src.iterdir():
    target = dest / item.name
    if item.is_dir():
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(item, target)
    else:
        shutil.copy2(item, target)

runs_path = site_root / "runs.json"
runs: list[dict] = []
if runs_path.is_file():
    try:
        runs = json.loads(runs_path.read_text(encoding="utf-8"))
        if not isinstance(runs, list):
            runs = []
    except json.JSONDecodeError:
        runs = []

entry = {
    "kind": kind,
    "run_id": str(run_id),
    "report": rel_report,
    "time": published_at,
    "actions": actions_url,
}
# dedupe same kind+run_id
runs = [r for r in runs if not (r.get("kind") == kind and str(r.get("run_id")) == str(run_id))]
runs.insert(0, entry)
runs_path.write_text(json.dumps(runs, indent=2) + "\n", encoding="utf-8")

def esc(s: str) -> str:
    return html.escape(s or "", quote=True)

rows = []
for r in runs:
    report = esc(str(r.get("report") or ""))
    actions = str(r.get("actions") or "")
    actions_cell = f'<a href="{esc(actions)}">run</a>' if actions else ""
    rows.append(
        "<tr>"
        f"<td>{esc(str(r.get('kind') or ''))}</td>"
        f"<td>{esc(str(r.get('run_id') or ''))}</td>"
        f'<td><a href="{report}">{report}</a></td>'
        f"<td>{esc(str(r.get('time') or ''))}</td>"
        f"<td>{actions_cell}</td>"
        "</tr>"
    )

index = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Nebula Bench Results</title>
<style>
body {{ font-family: sans-serif; margin: 1.5rem; }}
table {{ border-collapse: collapse; width: 100%; }}
th, td {{ border: 1px solid #ccc; padding: 0.45rem 0.6rem; text-align: left; }}
th {{ background: #f4f4f4; }}
</style></head><body>
<h1>Nebula Bench Results</h1>
<p>Newest runs first. Types: microbench, ldbcbench.</p>
<table>
<thead><tr><th>类型</th><th>Run</th><th>报告</th><th>时间</th><th>Actions</th></tr></thead>
<tbody>
{''.join(rows)}
</tbody></table>
</body></html>
"""
(site_root / "index.html").write_text(index, encoding="utf-8")
print(f"merged {kind} run={run_id} -> {dest}")
print(f"index rows={len(runs)}")
PY
