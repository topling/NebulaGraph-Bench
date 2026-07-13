"""Lookup microbench: load + query as functions; pre/post compact query runs.

主体语义对齐 Nebula tests/bench/lookup.py；编排拆成 load/query 与 compact 前后测读。
"""
from __future__ import annotations

import os
import time

import pytest

from microbench.data_generate import insert_edges, insert_vertices
from microbench.suite import MicrobenchSuite

LOOKUP_SPACE = "benchlookupspace"


def load_lookup_data(suite: MicrobenchSuite) -> None:
    """对齐原版 TestLookupBench.prepare（不含原版 sleep(4) 的硬编码，改用 suite.delay）。"""
    # 原版无 vid_type；standalone INT64 会话需显式声明（与 topling-bench patch 一致）。
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
    # 原版为 person(name)；Nebula 3.x 变长 string 索引必须带长度（与 YIELD 同类适配）。
    # length=10 对齐 data_generate.random_string(10)。
    resp = suite.execute(
        "CREATE TAG INDEX IF NOT EXISTS personName ON person(name(10))"
    )
    suite.check_resp_succeeded(resp)
    resp = suite.execute(
        "CREATE TAG INDEX IF NOT EXISTS personAge ON person(age)"
    )
    suite.check_resp_succeeded(resp)
    suite.wait_after_schema()
    # 原版: insert_vertices(self, "benchlookupspace", 50, 20000)
    insert_vertices(suite, LOOKUP_SPACE, 50, 20000)
    resp = suite.execute("CREATE EDGE IF NOT EXISTS like(likeness int)")
    suite.check_resp_succeeded(resp)
    suite.wait_after_schema()
    # 原版: insert_edges(self, "benchlookupspace", 50, 20000)
    insert_edges(suite, LOOKUP_SPACE, 50, 20000)


def run_lookup_queries(suite: MicrobenchSuite) -> None:
    """对齐原版 TestLookupBench.lookup 的查询主体（WHERE 条件与语句序列）。"""
    resp = suite.execute(f"USE {LOOKUP_SPACE}")
    suite.check_resp_succeeded(resp)
    # Nebula 3.x 强制 YIELD；WHERE 谓词与条数对齐原版 lookup()。
    queries = [
        "lookup on person where person.age < 0 YIELD id(vertex)",
        "lookup on person where person.age > 0 YIELD id(vertex)",
        "lookup on person where person.age > 60 YIELD id(vertex)",
        "lookup on person where person.age > 90 YIELD id(vertex)",
        'lookup on person where person.name == "sssssaass" YIELD id(vertex)',
        'lookup on person where person.name == "saaaaaass" YIELD id(vertex)',
        "lookup on person where person.age < 10 YIELD id(vertex)",
        "lookup on person where person.age > 80 YIELD id(vertex)",
        "lookup on person where person.age > 60 YIELD id(vertex)",
        "lookup on person where person.age > 90 YIELD id(vertex)",
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
