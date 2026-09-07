"""Shared test fixtures.

The environment variables set here are the ones `Settings` requires. They are
obviously-fake documentation values: the test suite must never touch a real
Azure resource, and a test that accidentally acquires a real credential would
be both a security problem and a flaky test.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

# Make both services importable as `app` without installing them as packages.
# The API and worker each have their own `app` package, so tests import one at
# a time and the path is set per-test-module.
API_PATH = Path(__file__).resolve().parents[1] / "api"
WORKER_PATH = Path(__file__).resolve().parents[1] / "worker"


@pytest.fixture(autouse=True)
def _fake_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    """Populate the settings the application requires, with fake values."""
    monkeypatch.setenv("PURPLE_ENVIRONMENT", "dev")
    monkeypatch.setenv("PURPLE_REGION", "eastus2")
    monkeypatch.setenv("PURPLE_COSMOS_ENDPOINT", "https://cosmos.example.invalid/")
    monkeypatch.setenv("PURPLE_OPENAI_ENDPOINT", "https://openai.example.invalid/")
    monkeypatch.setenv("PURPLE_SEARCH_ENDPOINT", "https://search.example.invalid/")


@pytest.fixture
def api_path() -> Path:
    if str(API_PATH) not in sys.path:
        sys.path.insert(0, str(API_PATH))
    return API_PATH


@pytest.fixture
def worker_path() -> Path:
    if str(WORKER_PATH) not in sys.path:
        sys.path.insert(0, str(WORKER_PATH))
    return WORKER_PATH
