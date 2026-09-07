"""Health endpoints.

This is a small file that carries a disproportionate amount of the platform's
availability design. Read it alongside
`infra/terraform/modules/front-door/main.tf`.

There are three probes and they answer three genuinely different questions.
Conflating them is one of the most common and most damaging Kubernetes
mistakes.

+-----------+-------------------------------+--------------------------------+
| Probe     | Question                      | What happens when it fails     |
+-----------+-------------------------------+--------------------------------+
| startup   | Has the app finished booting? | Restart, but only after the    |
|           |                               | generous startup budget        |
| liveness  | Is the process wedged?        | Kubernetes KILLS the container |
| readiness | Can it serve a request NOW?   | Removed from the Service's     |
|           |                               | endpoints; NOT killed          |
+-----------+-------------------------------+--------------------------------+

**Liveness must not check dependencies.** This is the rule people break.

If liveness checks Cosmos DB, then a Cosmos outage makes every liveness probe
fail, and Kubernetes responds by killing and restarting every pod, repeatedly.
The application was healthy. The restarts add a thundering herd of cold starts
and connection churn to an already-degraded dependency, and the outage gets
worse because of the health check. This failure mode has taken down real
production systems.

Liveness answers exactly one question: is this process still capable of making
progress? A deadlocked event loop, an exhausted thread pool, a wedged runtime.
Nothing external.

**Readiness is where dependencies belong.** A pod that cannot reach Cosmos
cannot serve requests, so it should stop receiving them — but it should stay
alive, because the moment Cosmos returns it can serve again with no restart
cost.

**Front Door probes readiness, not liveness.** That is what makes regional
failover correct: when a region's dependencies are unreachable, every pod in
that region reports not-ready, Front Door's health probe fails, and the region
is removed from rotation. A shallow probe that returns 200 from a live process
with a dead database would keep sending users to a region that cannot serve
them.
"""

from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass, field
from enum import StrEnum
from typing import Any

from fastapi import APIRouter, Response, status

from purple_api.config import Settings, get_settings
from purple_api.telemetry import get_logger

log = get_logger(__name__)
router = APIRouter(prefix="/healthz", tags=["health"])

# Set once the application has finished its startup sequence.
_startup_complete = False
_started_at = time.monotonic()


def mark_startup_complete() -> None:
    """Called from the lifespan handler once the app is ready to serve."""
    global _startup_complete
    _startup_complete = True


class DependencyStatus(StrEnum):
    OK = "ok"
    DEGRADED = "degraded"
    FAILED = "failed"


@dataclass
class DependencyCheck:
    """One dependency's health, and whether the service can work without it."""

    name: str
    status: DependencyStatus
    latency_ms: float
    # A dependency that is NOT critical can fail without making the pod
    # unready. This distinction is what stops a non-essential service from
    # taking the whole region out of rotation.
    critical: bool = True
    detail: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "status": self.status.value,
            "latency_ms": round(self.latency_ms, 1),
            "critical": self.critical,
            **({"detail": self.detail} if self.detail else {}),
        }


@dataclass
class HealthReport:
    checks: list[DependencyCheck] = field(default_factory=list)

    @property
    def ready(self) -> bool:
        """Ready only if every CRITICAL dependency is usable."""
        return all(
            check.status is not DependencyStatus.FAILED for check in self.checks if check.critical
        )

    def as_dict(self) -> dict[str, Any]:
        return {
            "ready": self.ready,
            "checks": [c.as_dict() for c in self.checks],
        }


async def _check_dependency(
    name: str,
    probe: Any,
    *,
    critical: bool,
    timeout: float,
) -> DependencyCheck:
    """Run one dependency probe under a timeout.

    The timeout is essential. A dependency that hangs rather than refusing
    would make the readiness probe itself hang, and Kubernetes would then fail
    the probe on ITS timeout — losing the information about which dependency
    was actually at fault.
    """
    started = time.monotonic()
    try:
        await asyncio.wait_for(probe(), timeout=timeout)
        return DependencyCheck(
            name=name,
            status=DependencyStatus.OK,
            latency_ms=(time.monotonic() - started) * 1000,
            critical=critical,
        )
    except TimeoutError:
        return DependencyCheck(
            name=name,
            status=DependencyStatus.FAILED,
            latency_ms=timeout * 1000,
            critical=critical,
            detail=f"probe exceeded {timeout}s",
        )
    except Exception as exc:  # noqa: BLE001 - any failure is a failed check
        return DependencyCheck(
            name=name,
            status=DependencyStatus.FAILED,
            latency_ms=(time.monotonic() - started) * 1000,
            critical=critical,
            detail=type(exc).__name__,
        )


@router.get("/live", status_code=status.HTTP_200_OK)
async def liveness() -> dict[str, Any]:
    """Liveness: is this process able to make progress?

    NO DEPENDENCY CHECKS. See the module docstring — checking dependencies
    here turns a dependency outage into a cluster-wide restart storm.

    The only thing verified is that the event loop is responsive enough to
    schedule and complete this coroutine. If the loop were blocked, this
    handler would never run and the probe would time out, which is exactly
    the condition that should trigger a restart.
    """
    return {
        "status": "alive",
        "uptime_seconds": round(time.monotonic() - _started_at, 1),
    }


@router.get("/ready")
async def readiness(response: Response) -> dict[str, Any]:
    """Readiness: can this pod serve a real request right now?

    Checks every dependency the request path needs. Returns 503 when a
    critical one is unusable, which:

      * removes the pod from the Kubernetes Service's endpoint list, and
      * fails Front Door's health probe, so the whole region is taken out of
        global rotation once every pod reports the same thing.

    The pod is NOT killed. When the dependency recovers, the next probe
    succeeds and traffic returns with no restart.
    """
    settings = get_settings()
    report = await run_readiness_checks(settings)

    if not report.ready:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        log.warning(
            "readiness_failed",
            failed=[c.name for c in report.checks if c.status is DependencyStatus.FAILED],
            region=settings.region,
        )

    return report.as_dict()


@router.get("/startup", status_code=status.HTTP_200_OK)
async def startup(response: Response) -> dict[str, Any]:
    """Startup: has the boot sequence finished?

    Exists so that liveness can have an aggressive timeout without killing a
    pod that is merely still starting. Without a startup probe, the liveness
    probe's initialDelaySeconds has to be set to the worst-case startup time,
    which means a genuinely wedged process goes undetected for that whole
    period.
    """
    if not _startup_complete:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "starting"}
    return {"status": "started"}


async def run_readiness_checks(settings: Settings) -> HealthReport:
    """Probe every dependency concurrently.

    Concurrently, not sequentially: four dependencies at 500ms each is 2s
    serially and 500ms in parallel, and the readiness probe has a hard budget.

    Which dependencies are marked critical is a real design decision:

      Cosmos DB   CRITICAL. Every request reads or writes user state.
      AI Search   CRITICAL. The assistant is the product's core feature.
      Azure OpenAI  NOT critical. If it is down the assistant degrades to an
                  error on that one endpoint, but dataset browsing, uploads
                  and the rest of the API still work. Taking the entire region
                  out of rotation because one feature is unavailable would
                  turn a partial degradation into a total outage.

    That last one is the judgement call worth internalising: readiness should
    reflect whether the pod can serve *its traffic*, not whether every feature
    is perfect.
    """
    from purple_api import clients

    timeout = settings.readiness_timeout_seconds

    results = await asyncio.gather(
        _check_dependency("cosmos", clients.probe_cosmos, critical=True, timeout=timeout),
        _check_dependency("search", clients.probe_search, critical=True, timeout=timeout),
        _check_dependency("openai", clients.probe_openai, critical=False, timeout=timeout),
    )

    return HealthReport(checks=list(results))
