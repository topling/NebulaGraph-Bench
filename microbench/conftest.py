"""pytest fixtures for microbench."""
from __future__ import annotations

import pytest

from microbench.suite import MicrobenchSuite, suite_from_env


@pytest.fixture(scope="session")
def suite() -> MicrobenchSuite:
    s = suite_from_env()
    s.connect()
    yield s
    s.close()
