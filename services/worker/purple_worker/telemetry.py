"""Observability wiring: structured logs, traces and metrics.

The principle: emit telemetry in a **vendor-neutral** format (OpenTelemetry)
and attach an Azure-specific exporter at the edge. That keeps the
instrumentation in the application independent of the backend storing it, so
moving from Azure Monitor to anything else is a change to this one file.

Three signals, and what each is actually for:

* **Logs** — discrete events with context. "Request failed, here is why."
* **Traces** — the causal path of one request across services. "The 500 came
  from the Cosmos call, which took 4.2 seconds."
* **Metrics** — aggregates over time. "p99 latency is 380ms."

The mistake worth avoiding is using logs for all three: counting log lines to
compute a rate is expensive, slow, and loses precision under sampling.
"""

from __future__ import annotations

import logging
import sys
from typing import Any

import structlog

from purple_worker.config import Settings


def configure_logging(settings: Settings) -> None:
    """Configure structured JSON logging.

    JSON, not human-readable text, because these lines are consumed by a log
    aggregator and queried with KQL. A message like

        "user 4a2f failed to load dataset 91b in 4.2s"

    requires a regex to query. The structured equivalent

        {"event": "dataset_load_failed", "user_id": "4a2f",
         "dataset_id": "91b", "duration_ms": 4200}

    is queryable by any field, and stays queryable when the message wording
    changes.
    """
    logging.basicConfig(
        format="%(message)s",
        stream=sys.stdout,
        level=getattr(logging, settings.log_level.upper(), logging.INFO),
    )

    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso", utc=True),
            # Attaches trace_id and span_id when inside a span, which is what
            # makes a log line clickable through to its distributed trace.
            _add_trace_context,
            structlog.processors.StackInfoRenderer(),
            structlog.processors.format_exc_info,
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(
            getattr(logging, settings.log_level.upper(), logging.INFO)
        ),
        logger_factory=structlog.stdlib.LoggerFactory(),
        cache_logger_on_first_use=True,
    )


def _add_trace_context(_logger: Any, _method: str, event_dict: dict[str, Any]) -> dict[str, Any]:
    """Attach the current trace and span ids to every log line.

    This is the single highest-value logging enhancement available. Without
    it, correlating a log line to a trace means guessing by timestamp.
    """
    try:
        from opentelemetry import trace

        span = trace.get_current_span()
        context = span.get_span_context()
        if context.is_valid:
            event_dict["trace_id"] = format(context.trace_id, "032x")
            event_dict["span_id"] = format(context.span_id, "016x")
    except Exception:  # noqa: BLE001, S110 - telemetry must never break a request
        # Deliberately silent. This runs inside the logging pipeline itself,
        # so logging the failure here would recurse.
        pass
    return event_dict


def configure_tracing(settings: Settings) -> None:
    """Attach the Azure Monitor OpenTelemetry exporter.

    The connection string is read from the environment by the Azure Monitor
    distro itself. It arrives via the Key Vault CSI driver as a mounted file
    projected into an environment variable — never from a manifest, and never
    baked into the image.

    Wrapped in a try/except on purpose: if telemetry export cannot be
    configured, the service should still start and serve traffic. A platform
    that refuses to run because its monitoring is unavailable has made
    monitoring a hard dependency of the product, which is backwards.
    """
    try:
        from azure.monitor.opentelemetry import configure_azure_monitor

        configure_azure_monitor(
            logger_name=settings.service_name,
            resource_attributes={
                "service.name": settings.service_name,
                "service.version": settings.service_version,
                "deployment.environment": settings.environment,
                # The attribute that makes "which region served this request"
                # answerable. In an active-active design this is the first
                # thing anyone asks during an incident.
                "cloud.region": settings.region,
            },
        )
    except Exception:  # noqa: BLE001
        structlog.get_logger(__name__).warning(
            "telemetry_export_unavailable",
            detail="Continuing without Azure Monitor export; traces will not be sent.",
        )


def get_logger(name: str) -> Any:
    """Return a bound structured logger."""
    return structlog.get_logger(name)
