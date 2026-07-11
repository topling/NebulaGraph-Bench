#!/usr/bin/env python3
"""Write benchmark-meta.json for a profile run (data scale, images, topling easy conf, etc.)."""
from __future__ import annotations

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path


def _count_ldbc_rows(data_folder: Path) -> dict:
    sn = data_folder / "social_network"
    if not sn.is_dir():
        return {"error": f"social_network dir not found: {sn}"}

    vertex_rows = 0
    edge_rows = 0
    vertex_files: list[str] = []
    edge_files: list[str] = []

    for csv_path in sorted(sn.glob("*.csv")):
        name = csv_path.name
        # Edge dumps: <src>_<edge>_<dst>.csv (see nebula_bench.parser.Parser.parse_edge)
        parts = csv_path.stem.split("_", 2)
        is_edge = len(parts) == 3
        try:
            with csv_path.open("rb") as f:
                rows = sum(1 for _ in f)
        except OSError as exc:
            return {"error": f"read failed for {csv_path}: {exc}"}

        if is_edge:
            edge_rows += rows
            edge_files.append(name)
        else:
            vertex_rows += rows
            vertex_files.append(name)

    return {
        "vertex_row_count": vertex_rows,
        "edge_row_count": edge_rows,
        "vertex_file_count": len(vertex_files),
        "edge_file_count": len(edge_files),
        "vertex_files": vertex_files,
        "edge_files": edge_files,
    }


def _topling_easy_conf(profile: str) -> dict | None:
    if profile not in ("conservative", "enterprise"):
        return None
    prefix = "/usr/local/nebula"
    yaml_map = {
        "conservative": f"{prefix}/etc/topling/topling-mimic-rocksdb.yaml",
        "enterprise": f"{prefix}/etc/topling/topling-enterprise.yaml",
    }
    return {
        "topling_migrate_profile": profile,
        "toplingdb_easy_migrate_conf": yaml_map[profile],
        "rocksdb_kick_out_options_file": "1",
        "toplingdb_getcontext_sampling": "kNone",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result-dir", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--scale-factor", required=True)
    parser.add_argument("--stress-args", default="")
    parser.add_argument("--data-folder", default="target/data/test_data")
    parser.add_argument("--rocksdb-image", default="")
    parser.add_argument("--topling-image", default="")
    args = parser.parse_args()

    result_dir = Path(args.result_dir)
    result_dir.mkdir(parents=True, exist_ok=True)

    storage_stats = None
    storage_path = result_dir / "storage-stats.json"
    if storage_path.is_file():
        with storage_path.open(encoding="utf-8") as f:
            storage_stats = json.load(f)

    meta: dict = {
        "schema_version": 1,
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "profile": args.profile,
        "scale_factor": float(args.scale_factor),
        "stress_args": args.stress_args,
        "nebula_address": os.environ.get("NEBULA_ADDRESS", "127.0.0.1:9669"),
        "nebula_replica_factor": int(os.environ.get("NEBULA_REPLICA_FACTOR", "1")),
        "images": {
            "rocksdb": args.rocksdb_image,
            "topling": args.topling_image,
        },
        "ldbc_data": _count_ldbc_rows(Path(args.data_folder)),
        "storage": storage_stats,
    }

    easy = _topling_easy_conf(args.profile)
    if easy:
        meta["topling_runtime"] = easy

    out = result_dir / "benchmark-meta.json"
    with out.open("w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
