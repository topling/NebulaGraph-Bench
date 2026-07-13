#!/usr/bin/env python3
"""Write microbench meta.json for a profile result dir."""
from __future__ import annotations

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--result-dir", required=True)
    ap.add_argument("--profile", required=True)
    args = ap.parse_args()
    result_dir = Path(args.result_dir)
    meta = {
        "bench_kind": "microbench",
        "profile": args.profile,
        "github_run_id": os.environ.get("GITHUB_RUN_ID", ""),
        "github_sha": os.environ.get("GITHUB_SHA", ""),
        "recorded_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "measurement_scope": "standalone data dir",
        "address": os.environ.get("MICROBENCH_ADDRESS", "127.0.0.1:9669"),
        "files": sorted(p.name for p in result_dir.glob("*") if p.is_file()),
    }
    (result_dir / "meta.json").write_text(
        json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(f"wrote {result_dir / 'meta.json'}")


if __name__ == "__main__":
    main()
