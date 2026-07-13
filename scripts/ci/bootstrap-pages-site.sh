#!/usr/bin/env bash
# Bootstrap minimal pages site (empty table) into SITE_ROOT.
set -euo pipefail
SITE_ROOT="${1:?site_root}"
mkdir -p "${SITE_ROOT}"
cat >"${SITE_ROOT}/runs.json" <<'EOF'
[]
EOF
cat >"${SITE_ROOT}/index.html" <<'EOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Nebula Bench Results</title>
<style>
body { font-family: sans-serif; margin: 1.5rem; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #ccc; padding: 0.45rem 0.6rem; text-align: left; }
th { background: #f4f4f4; }
</style></head><body>
<h1>Nebula Bench Results</h1>
<p>Newest runs first. Types: microbench, ldbcbench.</p>
<table>
<thead><tr><th>类型</th><th>Run</th><th>报告</th><th>时间</th><th>Actions</th></tr></thead>
<tbody>
</tbody></table>
</body></html>
EOF
echo "bootstrapped empty pages site at ${SITE_ROOT}"
