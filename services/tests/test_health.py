"""Tests for the health model.

These test the DECISION LOGIC, not the network calls. The valuable question is
"does a failed critical dependency make the pod unready, and does a failed
non-critical one leave it ready" — because that logic is what determines
whether a regional failover happens correctly.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "api"))

from purple_api.health import (
    DependencyCheck,
    DependencyStatus,
    HealthReport,
)


def _check(name: str, status: DependencyStatus, *, critical: bool) -> DependencyCheck:
    return DependencyCheck(name=name, status=status, latency_ms=1.0, critical=critical)


def test_all_dependencies_healthy_is_ready() -> None:
    report = HealthReport(
        checks=[
            _check("cosmos", DependencyStatus.OK, critical=True),
            _check("search", DependencyStatus.OK, critical=True),
            _check("openai", DependencyStatus.OK, critical=False),
        ]
    )
    assert report.ready is True


def test_failed_critical_dependency_makes_pod_unready() -> None:
    """A dead Cosmos must take the pod out of rotation.

    This is what propagates up to Front Door and removes the whole region.
    """
    report = HealthReport(
        checks=[
            _check("cosmos", DependencyStatus.FAILED, critical=True),
            _check("search", DependencyStatus.OK, critical=True),
        ]
    )
    assert report.ready is False


def test_failed_non_critical_dependency_keeps_pod_ready() -> None:
    """A dead OpenAI must NOT take the region out of rotation.

    The assistant degrades; dataset browsing, uploads and the rest of the API
    keep working. Marking every dependency critical would turn a partial
    feature outage into a total service outage — the opposite of what a
    readiness probe is for.
    """
    report = HealthReport(
        checks=[
            _check("cosmos", DependencyStatus.OK, critical=True),
            _check("search", DependencyStatus.OK, critical=True),
            _check("openai", DependencyStatus.FAILED, critical=False),
        ]
    )
    assert report.ready is True


def test_degraded_is_not_failed() -> None:
    """DEGRADED means slow, not broken. Slow still serves."""
    report = HealthReport(checks=[_check("cosmos", DependencyStatus.DEGRADED, critical=True)])
    assert report.ready is True


def test_empty_report_is_ready() -> None:
    """No checks means nothing has failed. Vacuously ready."""
    assert HealthReport(checks=[]).ready is True


@pytest.mark.parametrize(
    "statuses,expected",
    [
        ([DependencyStatus.OK, DependencyStatus.OK], True),
        ([DependencyStatus.OK, DependencyStatus.FAILED], False),
        ([DependencyStatus.FAILED, DependencyStatus.FAILED], False),
    ],
)
def test_readiness_requires_every_critical_dependency(
    statuses: list[DependencyStatus], expected: bool
) -> None:
    report = HealthReport(
        checks=[_check(f"dep{i}", s, critical=True) for i, s in enumerate(statuses)]
    )
    assert report.ready is expected
