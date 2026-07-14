#!/usr/bin/env bash
# Download the newest pages-site artifact across microbench + compare workflows into DEST.
# Exit 0 with DEST populated, or exit 2 if none found (caller may bootstrap / skip).
set -euo pipefail

DEST="${1:?dest dir}"
REPO="${GITHUB_REPOSITORY:?}"
TOKEN="${GITHUB_TOKEN:?}"

mkdir -p "${DEST}"
rm -rf "${DEST:?}/"*

python3 - "${DEST}" "${REPO}" "${TOKEN}" <<'PY'
from __future__ import annotations

import json
import os
import sys
import urllib.request
import zipfile
from io import BytesIO
from pathlib import Path

dest = Path(sys.argv[1])
repo = sys.argv[2]
token = sys.argv[3]
workflows = [
    "microbench-toplingdb.yaml",
    "compare-toplingdb.yaml",
]

def api(url: str):
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "nebula-bench-pages-merge",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)

candidates = []
for wf in workflows:
    try:
        data = api(
            f"https://api.github.com/repos/{repo}/actions/workflows/{wf}/runs"
            f"?status=completed&conclusion=success&per_page=20"
        )
    except Exception as exc:
        print(f"warn: list runs for {wf}: {exc}", file=sys.stderr)
        continue
    for run in data.get("workflow_runs") or []:
        run_id = run["id"]
        try:
            arts = api(
                f"https://api.github.com/repos/{repo}/actions/runs/{run_id}/artifacts"
            )
        except Exception as exc:
            print(f"warn: list artifacts run={run_id}: {exc}", file=sys.stderr)
            continue
        for art in arts.get("artifacts") or []:
            if art.get("name") != "pages-site" or art.get("expired"):
                continue
            candidates.append(
                {
                    "created_at": art.get("created_at") or run.get("created_at") or "",
                    "archive_download_url": art["archive_download_url"],
                    "run_id": run_id,
                    "workflow": wf,
                    "size": art.get("size_in_bytes"),
                }
            )

if not candidates:
    print("no pages-site artifact found", file=sys.stderr)
    sys.exit(2)

candidates.sort(key=lambda c: c["created_at"], reverse=True)
best = candidates[0]
print(
    f"selected pages-site from {best['workflow']} run={best['run_id']} created_at={best['created_at']}"
)

req = urllib.request.Request(
    best["archive_download_url"],
    headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "nebula-bench-pages-merge",
    },
)


class _StripAuthOnRedirect(urllib.request.HTTPRedirectHandler):
    """Artifact CDN redirects reject GitHub Authorization; strip it on hop."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new_req = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new_req is None:
            return None
        for key in list(new_req.headers.keys()):
            if key.lower() in ("authorization", "accept"):
                del new_req.headers[key]
        return new_req


opener = urllib.request.build_opener(_StripAuthOnRedirect)
with opener.open(req, timeout=180) as resp:
    blob = resp.read()

with zipfile.ZipFile(BytesIO(blob)) as zf:
    zf.extractall(dest)

# If zip contained a single top-level dir, flatten? keep as-is; upload path is DEST contents.
print(f"extracted to {dest}")
for p in sorted(dest.rglob("*"))[:20]:
    print(f"  {p.relative_to(dest)}")
PY
