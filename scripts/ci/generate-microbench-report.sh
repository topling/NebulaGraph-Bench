#!/usr/bin/env bash
# Merge per-profile microbench artifacts into report.html + report.json.
set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${BENCH_ROOT}"

INPUT_ROOT="${1:-${BENCH_ROOT}/output}"
OUT_DIR="${2:-${BENCH_ROOT}/output/microbench-report}"
mkdir -p "${OUT_DIR}"

python3 - "${INPUT_ROOT}" "${OUT_DIR}" <<'PY'
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

input_root = Path(sys.argv[1])
out_dir = Path(sys.argv[2])
profiles = ["rocksdb", "conservative", "enterprise"]


def load_benchmark(path: Path) -> dict:
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def bench_stats(doc: dict, name_substr: str | None = None) -> dict:
    benches = doc.get("benchmarks") or []
    picked = []
    for b in benches:
        name = b.get("name") or b.get("fullnamename") or ""
        if name_substr and name_substr not in name:
            continue
        stats = b.get("stats") or {}
        picked.append(
            {
                "name": name,
                "mean": stats.get("mean"),
                "stddev": stats.get("stddev"),
                "rounds": stats.get("rounds"),
                "min": stats.get("min"),
                "max": stats.get("max"),
            }
        )
    if not picked:
        return {}
    # Prefer first match / aggregate mean of means for multi-bench groups
    means = [p["mean"] for p in picked if p.get("mean") is not None]
    return {
        "benchmarks": picked,
        "mean": (sum(means) / len(means)) if means else None,
        "stddev": picked[0].get("stddev"),
        "rounds": sum(p.get("rounds") or 0 for p in picked),
    }


def load_storage(path: Path) -> dict:
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def find_profile_dirs() -> dict[str, Path]:
    found: dict[str, Path] = {}
    for p in sorted(input_root.glob("microbench-*")):
        if not p.is_dir():
            continue
        for profile in profiles:
            if f"-{profile}-" in p.name or p.name.endswith(f"-{profile}"):
                found[profile] = p
    # also accept output/<profile>-* laid out by download-artifact
    for profile in profiles:
        if profile in found:
            continue
        candidates = sorted(input_root.glob(f"*{profile}*"), key=lambda x: x.stat().st_mtime, reverse=True)
        for c in candidates:
            if c.is_dir() and (c / "meta.json").is_file():
                found[profile] = c
                break
            if c.is_dir() and any(c.glob("benchmark-*.json")):
                found[profile] = c
                break
    return found


profile_dirs = find_profile_dirs()
report = {
    "bench_kind": "microbench",
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "measurement_scope": "standalone data dir",
    "github_run_id": __import__("os").environ.get("GITHUB_RUN_ID", ""),
    "profiles": {},
    "lookup_query_compare": {},
}

for profile, d in profile_dirs.items():
    insert = load_benchmark(d / "benchmark-insert.json")
    load = load_benchmark(d / "benchmark-lookup-load.json")
    pre = load_benchmark(d / "benchmark-lookup-query-pre.json")
    post = load_benchmark(d / "benchmark-lookup-query-post.json")
    storage = load_storage(d / "storage-record.json")
    compact_lookup = {}
    cl = d / "compact-lookup.json"
    if cl.is_file():
        compact_lookup = json.loads(cl.read_text(encoding="utf-8"))
    pre_s = bench_stats(pre)
    post_s = bench_stats(post)
    ratio = None
    if pre_s.get("mean") and post_s.get("mean") and pre_s["mean"]:
        ratio = post_s["mean"] / pre_s["mean"]
    report["profiles"][profile] = {
        "result_dir": str(d),
        "insert": bench_stats(insert),
        "lookup_load": bench_stats(load),
        "lookup_query_pre": pre_s,
        "lookup_query_post": post_s,
        "lookup_query_ratio_post_over_pre": ratio,
        "storage": storage,
        "compact_lookup": compact_lookup,
    }
    report["lookup_query_compare"][profile] = {
        "pre_mean": pre_s.get("mean"),
        "post_mean": post_s.get("mean"),
        "delta": (post_s["mean"] - pre_s["mean"])
        if pre_s.get("mean") is not None and post_s.get("mean") is not None
        else None,
        "ratio": ratio,
        "note": "ratio = post_mean / pre_mean (>1 means slower after compact)",
    }

out_json = out_dir / "report.json"
out_json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

# HTML
rows = []
for profile in profiles:
    p = report["profiles"].get(profile) or {}
    cmp_ = report["lookup_query_compare"].get(profile) or {}
    stages = (p.get("storage") or {}).get("stages") or {}
    rows.append(
        "<tr>"
        f"<td>{profile}</td>"
        f"<td>{(p.get('insert') or {}).get('mean')}</td>"
        f"<td>{(p.get('lookup_load') or {}).get('mean')}</td>"
        f"<td>{cmp_.get('pre_mean')}</td>"
        f"<td>{cmp_.get('post_mean')}</td>"
        f"<td>{cmp_.get('delta')}</td>"
        f"<td>{cmp_.get('ratio')}</td>"
        f"<td>{(stages.get('insert_pre_compact') or {}).get('data_dir_disk_bytes')}</td>"
        f"<td>{(stages.get('insert_post_compact') or {}).get('data_dir_disk_bytes')}</td>"
        f"<td>{(stages.get('lookup_pre_compact') or {}).get('data_dir_disk_bytes')}</td>"
        f"<td>{(stages.get('lookup_post_compact') or {}).get('data_dir_disk_bytes')}</td>"
        "</tr>"
    )

html = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Nebula microbench</title>
<style>
body {{ font-family: sans-serif; margin: 1.5rem; }}
table {{ border-collapse: collapse; width: 100%; }}
th, td {{ border: 1px solid #ccc; padding: 0.4rem 0.6rem; font-size: 0.9rem; }}
th {{ background: #f4f4f4; }}
.muted {{ color: #666; }}
</style></head><body>
<h1>Nebula microbench</h1>
<p class="muted">measurement_scope = standalone data dir; lookup ratio = post_mean / pre_mean</p>
<p>run_id={report.get('github_run_id') or 'local'} generated_at={report['generated_at']}</p>
<table>
<thead><tr>
<th>profile</th><th>insert mean(s)</th><th>lookup load mean(s)</th>
<th>query pre mean</th><th>query post mean</th><th>delta</th><th>ratio post/pre</th>
<th>insert pre disk</th><th>insert post disk</th>
<th>lookup pre disk</th><th>lookup post disk</th>
</tr></thead>
<tbody>
{''.join(rows)}
</tbody></table>
</body></html>
"""
(out_dir / "report.html").write_text(html, encoding="utf-8")
print(f"wrote {out_json}")
print(f"wrote {out_dir / 'report.html'}")
if len(profile_dirs) < 3:
    missing = [p for p in profiles if p not in profile_dirs]
    print(f"warn: missing profiles: {missing}", file=sys.stderr)
    sys.exit(1)
PY
