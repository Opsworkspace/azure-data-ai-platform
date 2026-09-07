"""Tests for configuration loading.

The behaviour worth testing is that the application refuses to start when a
required endpoint is missing — because the alternative is discovering it on
the first user request.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "api"))


def test_settings_load_from_environment() -> None:
    from purple_api.config import Settings

    settings = Settings()  # type: ignore[call-arg]
    assert settings.environment == "dev"
    assert settings.region == "eastus2"
    assert settings.is_production is False


def test_missing_required_endpoint_fails_fast(monkeypatch: pytest.MonkeyPatch) -> None:
    """A missing endpoint must crash startup, not the first request."""
    from pydantic import ValidationError

    from purple_api.config import Settings

    monkeypatch.delenv("PURPLE_COSMOS_ENDPOINT", raising=False)

    with pytest.raises(ValidationError):
        Settings()  # type: ignore[call-arg]


def test_production_flag(monkeypatch: pytest.MonkeyPatch) -> None:
    from purple_api.config import Settings

    monkeypatch.setenv("PURPLE_ENVIRONMENT", "prod")
    assert Settings().is_production is True  # type: ignore[call-arg]


def test_rag_top_k_is_bounded(monkeypatch: pytest.MonkeyPatch) -> None:
    """Guard rails on a parameter that drives both cost and latency."""
    from pydantic import ValidationError

    from purple_api.config import Settings

    monkeypatch.setenv("PURPLE_RAG_TOP_K", "500")
    with pytest.raises(ValidationError):
        Settings()  # type: ignore[call-arg]
