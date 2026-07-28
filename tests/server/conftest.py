import os
import sys

import pytest

# Reuse llama-server pytest helpers from tools/server/tests.
_SERVER_TESTS_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "tools", "server", "tests")
)
if _SERVER_TESTS_DIR not in sys.path:
    sys.path.insert(0, _SERVER_TESTS_DIR)

from utils import server_instances  # noqa: E402


@pytest.fixture(autouse=True)
def stop_server_after_each_test():
    yield
    instances = set(server_instances)
    for server in instances:
        server.stop()