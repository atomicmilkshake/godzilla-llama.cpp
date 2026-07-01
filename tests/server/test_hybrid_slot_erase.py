import os

import pytest
from utils import ServerProcess

HYBRID_MODEL = os.environ.get("HYBRID_MODEL")

pytestmark = pytest.mark.skipif(
    not HYBRID_MODEL,
    reason="HYBRID_MODEL env var not set (path to hybrid GGUF)",
)

SESSION_A = "Session A: Explain what a red-black tree is in one sentence."
SESSION_B = "Session B: Write a Python function that returns the nth Fibonacci number."


@pytest.fixture(autouse=True)
def create_server():
    global server
    server = ServerProcess()
    server.model_file = HYBRID_MODEL
    server.jinja = True
    server.n_slots = 1
    server.n_ctx = 8192
    server.n_predict = 32
    server.temperature = 0.0
    server.seed = 42


def test_hybrid_slot_erase_three_cycles():
    """Cadre-style stability: chat → erase slot 0 → chat across unrelated sessions."""
    global server
    server.start()

    for cycle in range(3):
        res = server.make_request(
            "POST",
            "/chat/completions",
            data={
                "messages": [{"role": "user", "content": f"{SESSION_A} (cycle {cycle + 1})"}],
                "max_tokens": 32,
            },
        )
        assert res.status_code == 200, res.body
        assert "choices" in res.body
        assert res.body["choices"][0]["message"]["content"]

        res = server.make_request("POST", "/slots/0?action=erase")
        assert res.status_code == 200, res.body

        res = server.make_request(
            "POST",
            "/chat/completions",
            data={
                "messages": [{"role": "user", "content": f"{SESSION_B} (cycle {cycle + 1})"}],
                "max_tokens": 32,
            },
        )
        assert res.status_code == 200, res.body
        assert "choices" in res.body
        assert res.body["choices"][0]["message"]["content"]

    res = server.make_request("GET", "/health")
    assert res.status_code == 200, res.body

    res = server.make_request(
        "POST",
        "/chat/completions",
        data={
            "messages": [{"role": "user", "content": "Final health check: reply with OK."}],
            "max_tokens": 8,
        },
    )
    assert res.status_code == 200, res.body
    assert "choices" in res.body