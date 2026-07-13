"""Lookup microbench: load + query as functions; pre/post compact query runs."""
from __future__ import annotations

import os
import time

import pytest

from microbench.data_generate import insert_edges, insert_vertices
from microbench.suite import MicrobenchSuite

LOOKUP_SPACE = "benchlookupspace"


def load_lookup_data(suite: MicrobenchSuite) -> None:
    """Create indexed space and bulk-insert ~1M vertices/edges."""
    resp = suite.execute(
        "CREATE SPACE IF NOT EXISTS {space}("
        "partition_num={partition_num}, replica_factor={replica_factor}, "
        "vid_type=INT64)"
        .format(
            space=LOOKUP_SPACE,
            partition_num=suite.partition_num,
            replica_factor=suite.replica_factor,
        )
    )
    suite.check_resp_succeeded(resp)
    suite.wait_space_ready(LOOKUP_SPACE)
    resp = suite.execute("CREATE TAG IF NOT EXISTS person(name string, age int)")
    suite.check_resp_succeeded(resp)
    resp = suite.execute(
        "CREATE TAG INDEX IF NOT EXISTS personName ON person(name(10))"
    )
    suite.check_resp_succeeded(resp)
    resp = suite.execute("CREATE TAG INDEX IF NOT EXISTS personAge ON person(age)")
    suite.check_resp_succeeded(resp)
    suite.wait_after_schema()
    resp = suite.execute("REBUILD TAG INDEX personName, personAge")
    suite.check_resp_succeeded(resp)
    suite.wait_after_schema()
    insert_vertices(suite, LOOKUP_SPACE, 20000, 50)
    resp = suite.execute("CREATE EDGE IF NOT EXISTS like(likeness int)")
    suite.check_resp_succeeded(resp)
    suite.wait_after_schema()
    insert_edges(suite, LOOKUP_SPACE, 20000, 50)


def run_lookup_queries(suite: MicrobenchSuite) -> None:
    """Query-only path: USE existing indexed space, no bulk INSERT."""
    resp = suite.execute(f"USE {LOOKUP_SPACE}")
    suite.check_resp_succeeded(resp)
    queries = [
        "LOOKUP ON person WHERE person.age < 0",
        "LOOKUP ON person WHERE person.age > 0",
        "LOOKUP ON person WHERE person.age > 60",
        "LOOKUP ON person WHERE person.age > 90",
        'LOOKUP ON person WHERE person.name == "sssssaass"',
        'LOOKUP ON person WHERE person.name == "saaaaaass"',
        "LOOKUP ON person WHERE person.age < 10",
        "LOOKUP ON person WHERE person.age > 80",
        "LOOKUP ON person WHERE person.age > 60",
        "LOOKUP ON person WHERE person.age > 90",
    ]
    for q in queries:
        resp = suite.execute(q)
        suite.check_resp_succeeded(resp)


class TestLookupBench:
    @pytest.fixture(autouse=True)
    def _bind(self, suite: MicrobenchSuite):
        self.suite = suite

    @pytest.mark.benchmark(
        group="lookup_load",
        min_time=0.1,
        max_time=0.5,
        min_rounds=1,
        timer=time.time,
        disable_gc=True,
        warmup=False,
    )
    def test_load(self, benchmark):
        phase = os.environ.get("MICROBENCH_LOOKUP_PHASE", "")
        if phase and phase != "load":
            pytest.skip(f"MICROBENCH_LOOKUP_PHASE={phase} (want load)")
        benchmark(lambda: load_lookup_data(self.suite))
        self.suite.record_storage_stage("post_lookup_load")

    @pytest.mark.benchmark(
        group="lookup_query",
        min_time=0.1,
        max_time=0.5,
        min_rounds=10,
        timer=time.time,
        disable_gc=True,
        warmup=False,
    )
    def test_query(self, benchmark):
        phase = os.environ.get("MICROBENCH_LOOKUP_PHASE", "query")
        if phase == "load":
            pytest.skip("MICROBENCH_LOOKUP_PHASE=load")
        # Refuse accidental bulk INSERT on query phase.
        if phase in ("query_pre", "query_post", "query", ""):
            pass
        else:
            pytest.skip(f"unknown MICROBENCH_LOOKUP_PHASE={phase}")
        if phase == "query_pre":
            self.suite.record_storage_stage("lookup_pre_compact")
        benchmark(lambda: run_lookup_queries(self.suite))
        if phase == "query_post":
            self.suite.record_storage_stage("lookup_post_compact")
            resp = self.suite.execute(f"DROP SPACE IF EXISTS {LOOKUP_SPACE}")
            self.suite.check_resp_succeeded(resp)
