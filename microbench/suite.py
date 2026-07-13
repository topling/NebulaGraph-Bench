"""Thin nebula3 harness for microbench (no NebulaTestSuite / pytest seed)."""
from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any, Optional

from nebula3.Config import Config
from nebula3.gclient.net import ConnectionPool


def _du_disk_bytes(path: Path) -> int:
    # Match collect-profile-artifacts.sh: du -sk * 1024
    import subprocess

    out = subprocess.check_output(["du", "-sk", str(path)], text=True)
    kib = int(out.split()[0])
    return kib * 1024


def _du_apparent_bytes(path: Path) -> int:
    import subprocess

    out = subprocess.check_output(["du", "-sb", str(path)], text=True)
    return int(out.split()[0])


def _row_cells(row) -> list:
    if hasattr(row, "values"):
        return row.values
    return row


def _cell_str(cell) -> str:
    """Convert a nebula3 Value cell to str without assuming string type."""
    if cell is None:
        return ""
    if hasattr(cell, "is_string") and callable(cell.is_string):
        try:
            if cell.is_string():
                return cell.as_string()
        except Exception:
            pass
    if hasattr(cell, "is_int") and callable(cell.is_int):
        try:
            if cell.is_int():
                return str(cell.as_int())
        except Exception:
            pass
    if hasattr(cell, "as_string"):
        try:
            return cell.as_string()
        except Exception:
            pass
    if hasattr(cell, "as_int"):
        try:
            return str(cell.as_int())
        except Exception:
            pass
    return str(cell)


def _cell_int(cell) -> int:
    if cell is None:
        return 0
    if hasattr(cell, "is_int") and callable(cell.is_int):
        try:
            if cell.is_int():
                return int(cell.as_int())
        except Exception:
            pass
    if hasattr(cell, "as_int"):
        try:
            return int(cell.as_int())
        except Exception:
            pass
    return int(_cell_str(cell))


def _keys(resp) -> list[str]:
    return [k.decode() if isinstance(k, bytes) else str(k) for k in resp.keys()]


class MicrobenchSuite:
    def __init__(
        self,
        host: str,
        port: int,
        user: str = "root",
        password: str = "nebula",
        delay: float = 5.0,
        partition_num: int = 1,
        replica_factor: int = 1,
        data_dir: Optional[str] = None,
        storage_json: Optional[str] = None,
    ):
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.delay = delay
        self.partition_num = partition_num
        self.replica_factor = replica_factor
        self.data_dir = Path(data_dir) if data_dir else None
        self.storage_json = Path(storage_json) if storage_json else None
        self._pool: Optional[ConnectionPool] = None
        self._session = None

    def connect(self) -> None:
        cfg = Config()
        cfg.max_connection_pool_size = 10
        pool = ConnectionPool()
        if not pool.init([(self.host, self.port)], cfg):
            raise RuntimeError(f"failed to init ConnectionPool {self.host}:{self.port}")
        self._pool = pool
        self._session = pool.get_session(self.user, self.password)

    def close(self) -> None:
        if self._session is not None:
            try:
                self._session.release()
            except Exception:
                pass
            self._session = None
        if self._pool is not None:
            try:
                self._pool.close()
            except Exception:
                pass
            self._pool = None

    def execute(self, query: str):
        if self._session is None:
            raise RuntimeError("suite not connected")
        return self._session.execute(query)

    def check_resp_succeeded(self, resp) -> None:
        if not resp.is_succeeded():
            raise RuntimeError(f"nGQL failed: {resp.error_msg()}")

    def sleep_schema(self) -> None:
        time.sleep(self.delay)

    def wait_space_ready(
        self,
        space: str,
        timeout_sec: Optional[float] = None,
        interval_sec: float = 1.0,
    ) -> None:
        """Poll USE until space is visible (CREATE SPACE is async on meta)."""
        timeout = (
            timeout_sec
            if timeout_sec is not None
            else float(os.environ.get("MICROBENCH_SPACE_READY_TIMEOUT", "120"))
        )
        deadline = time.monotonic() + timeout
        last_err = ""
        while time.monotonic() < deadline:
            resp = self.execute(f"USE `{space}`")
            if resp.is_succeeded():
                return
            last_err = resp.error_msg()
            time.sleep(interval_sec)
        raise RuntimeError(
            f"timeout waiting for space {space!r} to be ready: {last_err}"
        )

    def wait_schema_ready(
        self,
        kind: str,
        name: str,
        timeout_sec: Optional[float] = None,
        interval_sec: float = 0.5,
    ) -> None:
        """Poll DESCRIBE until TAG/EDGE/TAG INDEX is visible (meta sync)."""
        kind_u = " ".join(kind.strip().upper().split())
        if kind_u == "TAG":
            ngql = f"DESCRIBE TAG `{name}`"
        elif kind_u == "EDGE":
            ngql = f"DESCRIBE EDGE `{name}`"
        elif kind_u == "TAG INDEX":
            ngql = f"DESCRIBE TAG INDEX `{name}`"
        else:
            raise ValueError(f"kind must be TAG, EDGE, or TAG INDEX, got {kind!r}")
        timeout = (
            timeout_sec
            if timeout_sec is not None
            else float(os.environ.get("MICROBENCH_SCHEMA_READY_TIMEOUT", "180"))
        )
        deadline = time.monotonic() + timeout
        last_err = ""
        while time.monotonic() < deadline:
            resp = self.execute(ngql)
            if resp.is_succeeded():
                return
            last_err = resp.error_msg()
            time.sleep(interval_sec)
        raise RuntimeError(
            f"timeout waiting for {kind_u} {name!r} schema: {last_err}"
        )

    def wait_tag_writable(
        self,
        tag: str,
        *,
        timeout_sec: Optional[float] = None,
        interval_sec: float = 1.0,
        probe_vid: int = -1,
    ) -> None:
        """Poll INSERT VERTEX until storage schema cache accepts the tag."""
        timeout = (
            timeout_sec
            if timeout_sec is not None
            else float(os.environ.get("MICROBENCH_SCHEMA_READY_TIMEOUT", "180"))
        )
        deadline = time.monotonic() + timeout
        last_err = ""
        insert_q = (
            f'INSERT VERTEX `{tag}`(name, age) VALUES '
            f'{probe_vid}:("schema_probe", 0)'
        )
        while time.monotonic() < deadline:
            resp = self.execute(insert_q)
            if resp.is_succeeded():
                self.execute(f"DELETE VERTEX {probe_vid}")
                return
            last_err = resp.error_msg()
            time.sleep(interval_sec)
        raise RuntimeError(
            f"timeout waiting for TAG {tag!r} writable: {last_err}"
        )

    def wait_edge_writable(
        self,
        edge: str,
        *,
        tag: str = "person",
        timeout_sec: Optional[float] = None,
        interval_sec: float = 1.0,
        src_vid: int = -2,
        dst_vid: int = -3,
    ) -> None:
        """Poll INSERT EDGE until storage schema cache accepts the edge."""
        timeout = (
            timeout_sec
            if timeout_sec is not None
            else float(os.environ.get("MICROBENCH_SCHEMA_READY_TIMEOUT", "180"))
        )
        deadline = time.monotonic() + timeout
        last_err = ""
        # Ensure endpoints exist for the edge probe.
        self.execute(
            f'INSERT VERTEX `{tag}`(name, age) VALUES '
            f'{src_vid}:("edge_probe_src", 0), {dst_vid}:("edge_probe_dst", 0)'
        )
        insert_q = f"INSERT EDGE `{edge}`(likeness) VALUES {src_vid}->{dst_vid}:(0)"
        while time.monotonic() < deadline:
            resp = self.execute(insert_q)
            if resp.is_succeeded():
                self.execute(f"DELETE EDGE `{edge}` {src_vid} -> {dst_vid}")
                self.execute(f"DELETE VERTEX {src_vid}, {dst_vid}")
                return
            last_err = resp.error_msg()
            time.sleep(interval_sec)
        self.execute(f"DELETE VERTEX {src_vid}, {dst_vid}")
        raise RuntimeError(
            f"timeout waiting for EDGE {edge!r} writable: {last_err}"
        )

    def wait_after_schema(self) -> None:
        """Wait after DDL so subsequent DML/DQL see schema."""
        self.sleep_schema()

    def measure_data_dir(self) -> dict[str, Any]:
        if self.data_dir is None or not self.data_dir.is_dir():
            return {
                "measurement_scope": "standalone data dir",
                "data_dir": str(self.data_dir) if self.data_dir else None,
                "error": "data_dir missing or not a directory",
                "data_dir_disk_bytes": 0,
                "data_dir_apparent_bytes": 0,
                "storage_disk_bytes": 0,
                "storage_apparent_bytes": 0,
                "meta_disk_bytes": 0,
                "meta_apparent_bytes": 0,
            }
        data_dir = self.data_dir
        storage = data_dir / "storage"
        meta = data_dir / "meta"
        return {
            "measurement_scope": "standalone data dir",
            "data_dir": "/usr/local/nebula/data",
            "host_data_dir": str(data_dir),
            "measurement_methods": {
                "disk_bytes": "du -sk (actual blocks allocated)",
                "apparent_bytes": "du -sb (logical file sizes)",
            },
            "data_dir_disk_bytes": _du_disk_bytes(data_dir),
            "data_dir_apparent_bytes": _du_apparent_bytes(data_dir),
            "storage_disk_bytes": _du_disk_bytes(storage) if storage.is_dir() else 0,
            "storage_apparent_bytes": _du_apparent_bytes(storage)
            if storage.is_dir()
            else 0,
            "meta_disk_bytes": _du_disk_bytes(meta) if meta.is_dir() else 0,
            "meta_apparent_bytes": _du_apparent_bytes(meta) if meta.is_dir() else 0,
        }

    def record_storage_stage(self, stage: str) -> dict[str, Any]:
        payload = self.measure_data_dir()
        payload["measurement_stage"] = stage
        payload["recorded_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        if self.storage_json is not None:
            self.storage_json.parent.mkdir(parents=True, exist_ok=True)
            doc: dict[str, Any] = {"schema_version": 2, "stages": {}}
            if self.storage_json.is_file():
                try:
                    doc = json.loads(self.storage_json.read_text(encoding="utf-8"))
                except json.JSONDecodeError:
                    pass
            stages = doc.setdefault("stages", {})
            stages[stage] = payload
            self.storage_json.write_text(
                json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
        return payload

    def run_compact_job(
        self,
        space: str,
        timeout_sec: float = 1800.0,
        poll_interval: float = 2.0,
    ) -> dict[str, Any]:
        started = time.monotonic()
        self.check_resp_succeeded(self.execute(f"USE `{space}`"))
        resp = self.execute("SUBMIT JOB COMPACT")
        self.check_resp_succeeded(resp)
        if resp.row_size() == 0:
            raise RuntimeError(f"SUBMIT JOB COMPACT returned no rows for {space!r}")
        keys = _keys(resp)
        try:
            id_idx = keys.index("New Job Id")
        except ValueError:
            id_idx = 0
        cells = _row_cells(resp.row_values(0))
        job_id = _cell_int(cells[id_idx])

        deadline = time.monotonic() + timeout_sec
        last_status = "UNKNOWN"
        while time.monotonic() < deadline:
            show = self.execute(f"SHOW JOB {job_id}")
            self.check_resp_succeeded(show)
            if show.row_size() == 0:
                time.sleep(poll_interval)
                continue
            skeys = _keys(show)
            try:
                status_idx = skeys.index("Status")
            except ValueError:
                status_idx = 1 if len(skeys) > 1 else 0
            last_status = _cell_str(_row_cells(show.row_values(0))[status_idx])
            if last_status in ("FINISHED", "FAILED", "STOPPED", "TIMEOUT"):
                break
            time.sleep(poll_interval)
        else:
            raise RuntimeError(
                f"timeout waiting for COMPACT job {job_id} last={last_status}"
            )
        if last_status != "FINISHED":
            raise RuntimeError(f"COMPACT job {job_id} ended with {last_status}")
        elapsed = time.monotonic() - started
        result = {
            "space": space,
            "job_id": job_id,
            "status": last_status,
            "elapsed_sec": elapsed,
        }
        if self.storage_json is not None:
            self.storage_json.parent.mkdir(parents=True, exist_ok=True)
            doc: dict[str, Any] = {"schema_version": 2}
            if self.storage_json.is_file():
                try:
                    doc = json.loads(self.storage_json.read_text(encoding="utf-8"))
                except json.JSONDecodeError:
                    pass
            compact = doc.setdefault("compact", {})
            compact[space] = result
            self.storage_json.write_text(
                json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
        return result


def suite_from_env() -> MicrobenchSuite:
    address = os.environ.get("MICROBENCH_ADDRESS", "127.0.0.1:9669")
    host, port_s = address.rsplit(":", 1)
    return MicrobenchSuite(
        host=host,
        port=int(port_s),
        user=os.environ.get("MICROBENCH_USER", "root"),
        password=os.environ.get("MICROBENCH_PASSWORD", "nebula"),
        delay=float(os.environ.get("MICROBENCH_GRAPH_DELAY", "33")),
        partition_num=int(os.environ.get("MICROBENCH_PARTITION_NUM", "1")),
        replica_factor=int(os.environ.get("MICROBENCH_REPLICA_FACTOR", "1")),
        data_dir=os.environ.get("MICROBENCH_DATA_DIR"),
        storage_json=os.environ.get("MICROBENCH_STORAGE_JSON"),
    )
