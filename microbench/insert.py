"""Insert microbench: write timing + compact + disk in cleanup, then DROP SPACE."""
from __future__ import annotations

import time

import pytest

from microbench.data_generate import (
    generate_insert_likeness_edge,
    generate_insert_student_vertex,
)
from microbench.suite import MicrobenchSuite

INSERT_SPACE = "benchinsertspace"


@pytest.fixture(scope="module")
def insert_prepared(suite: MicrobenchSuite):
    s = suite
    resp = s.execute(
        "CREATE SPACE IF NOT EXISTS {space}("
        "partition_num={partition_num}, replica_factor={replica_factor}, "
        "vid_type=INT64)"
        .format(
            space=INSERT_SPACE,
            partition_num=s.partition_num,
            replica_factor=s.replica_factor,
        )
    )
    s.check_resp_succeeded(resp)
    s.wait_space_ready(INSERT_SPACE)
    resp = s.execute("CREATE TAG IF NOT EXISTS person(name string, age int)")
    s.check_resp_succeeded(resp)
    resp = s.execute("CREATE EDGE IF NOT EXISTS like(likeness int)")
    s.check_resp_succeeded(resp)
    s.wait_after_schema()
    yield s
    s.record_storage_stage("insert_pre_compact")
    s.run_compact_job(INSERT_SPACE)
    s.record_storage_stage("insert_post_compact")
    resp = s.execute(f"DROP SPACE IF EXISTS {INSERT_SPACE}")
    s.check_resp_succeeded(resp)


class TestInsertBench:
    def insert_vertex(self, suite: MicrobenchSuite) -> None:
        resp = suite.execute(f"USE {INSERT_SPACE}")
        suite.check_resp_succeeded(resp)
        for i in range(20000):
            query = generate_insert_student_vertex(50, 50 * i)
            resp = suite.execute(query)
            suite.check_resp_succeeded(resp)

    def insert_edge(self, suite: MicrobenchSuite) -> None:
        resp = suite.execute(f"USE {INSERT_SPACE}")
        suite.check_resp_succeeded(resp)
        for i in range(20000):
            query = generate_insert_likeness_edge(50, 50 * i)
            resp = suite.execute(query)
            suite.check_resp_succeeded(resp)

    @pytest.mark.benchmark(
        group="insert",
        min_time=0.1,
        max_time=0.5,
        min_rounds=1,
        timer=time.time,
        disable_gc=True,
        warmup=False,
    )
    def test_insert_vertex(self, benchmark, insert_prepared: MicrobenchSuite):
        benchmark(lambda: self.insert_vertex(insert_prepared))

    @pytest.mark.benchmark(
        group="insert",
        min_time=0.1,
        max_time=0.5,
        min_rounds=1,
        timer=time.time,
        disable_gc=True,
        warmup=False,
    )
    def test_insert_edge(self, benchmark, insert_prepared: MicrobenchSuite):
        benchmark(lambda: self.insert_edge(insert_prepared))
