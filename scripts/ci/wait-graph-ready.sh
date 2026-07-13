#!/usr/bin/env bash
# Wait until graph accepts SHOW HOSTS with at least one ONLINE host.
set -euo pipefail

ADDRESS="${MICROBENCH_ADDRESS:-127.0.0.1:9669}"
TIMEOUT="${MICROBENCH_READY_TIMEOUT:-300}"
INTERVAL="${MICROBENCH_READY_INTERVAL:-2}"
USER="${MICROBENCH_USER:-root}"
PASSWORD="${MICROBENCH_PASSWORD:-nebula}"

python3 - "${ADDRESS}" "${TIMEOUT}" "${INTERVAL}" "${USER}" "${PASSWORD}" <<'PY'
import sys
import time
from nebula3.Config import Config
from nebula3.gclient.net import ConnectionPool

address, timeout_s, interval_s, user, password = sys.argv[1:6]
host, port_s = address.rsplit(":", 1)
port = int(port_s)
deadline = time.monotonic() + float(timeout_s)
interval = float(interval_s)

def online_count(session) -> int:
    resp = session.execute("SHOW HOSTS")
    if not resp.is_succeeded():
        return 0
    keys = [k.decode() if isinstance(k, bytes) else str(k) for k in resp.keys()]
    try:
        status_idx = keys.index("Status")
    except ValueError:
        status_idx = 2 if len(keys) > 2 else 0
    n = 0
    for i in range(resp.row_size()):
        row = resp.row_values(i)
        cells = row.values if hasattr(row, "values") else row
        if status_idx >= len(cells):
            continue
        cell = cells[status_idx]
        status = cell.as_string() if hasattr(cell, "as_string") else str(cell)
        if status.upper() == "ONLINE":
            n += 1
    return n

last_err = ""
while time.monotonic() < deadline:
    pool = ConnectionPool()
    try:
        cfg = Config()
        if not pool.init([(host, port)], cfg):
            last_err = "pool init failed"
            time.sleep(interval)
            continue
        session = pool.get_session(user, password)
        try:
            n = online_count(session)
            if n >= 1:
                print(f"graph ready: {n} ONLINE host(s) at {address}")
                sys.exit(0)
            last_err = f"ONLINE hosts={n}"
        finally:
            session.release()
    except Exception as exc:
        last_err = str(exc)
    finally:
        try:
            pool.close()
        except Exception:
            pass
    time.sleep(interval)

print(f"timeout waiting for graph ready at {address}: {last_err}", file=sys.stderr)
sys.exit(1)
PY
