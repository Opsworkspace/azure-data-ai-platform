"""FastAPI application entry point.

The startup and shutdown sequence here is what makes a rolling deployment
invisible to users. Read `lifespan` alongside the `preStop` hook and
`terminationGracePeriodSeconds` in
`platform/kubernetes/base/api-deployment.yaml` — they are three halves of one
mechanism.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.responses import JSONResponse

from purple_api import clients, health, rag
from purple_api.config import Settings, get_settings
from purple_api.telemetry import configure_logging, configure_tracing, get_logger

log = get_logger(__name__)


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    """Startup and shutdown.

    **Startup** warms the clients before the pod reports ready. Without this,
    the first real user request pays for DNS resolution, TLS handshakes and a
    token acquisition — turning a rolling deploy into a visible latency spike
    on every replacement pod.

    **Shutdown** is the part people skip. When Kubernetes terminates a pod it
    does two things at once: sends SIGTERM to the container, and removes the
    pod from Service endpoints. Those propagate at different speeds — endpoint
    removal has to reach every kube-proxy and every ingress controller, which
    takes a second or two.

    If the process exits immediately on SIGTERM, requests routed during that
    window hit a closed socket. The `preStop` sleep in the manifest holds the
    container open while endpoint removal propagates; this handler then closes
    clients cleanly.
    """
    settings = get_settings()
    configure_logging(settings)
    configure_tracing(settings)

    log.info(
        "starting",
        service=settings.service_name,
        version=settings.service_version,
        environment=settings.environment,
        region=settings.region,
    )

    try:
        # Warm the credential chain and the client objects. Failures are
        # logged but not fatal: the readiness probe will keep the pod out of
        # rotation until the dependency is genuinely reachable, which is a
        # more accurate signal than refusing to start.
        await asyncio.gather(
            clients.probe_cosmos(),
            clients.probe_search(),
            return_exceptions=True,
        )
    except Exception:  # noqa: BLE001
        log.warning("startup_warmup_incomplete")

    health.mark_startup_complete()
    log.info("started")

    yield

    log.info("shutting_down")
    await clients.close_clients()
    log.info("shutdown_complete")


app = FastAPI(
    title="Purple API",
    version="1.0.0",
    lifespan=lifespan,
    # Interactive docs are disabled in production. They are a live, accurate
    # description of every endpoint and parameter — useful internally,
    # unnecessary reconnaissance material on a public API.
    docs_url=None if get_settings().is_production else "/docs",
    redoc_url=None,
    openapi_url=None if get_settings().is_production else "/openapi.json",
)

app.include_router(health.router)


@app.middleware("http")
async def add_region_header(request: Request, call_next: Any) -> Any:
    """Stamp every response with the region that served it.

    Trivial to add, disproportionately useful. In an active-active deployment
    the first question during any incident is "which region?", and without
    this the answer requires correlating timestamps against Front Door logs.
    """
    response = await call_next(request)
    response.headers["X-Served-By-Region"] = get_settings().region
    return response


async def current_user_id(request: Request) -> str:
    """Extract the authenticated user id from the validated token.

    PLACEHOLDER. A production implementation validates the JWT signature
    against the Entra JWKS endpoint, checks `aud`, `iss`, `exp` and `nbf`, and
    returns the `oid` claim.

    What matters architecturally, and is true of the real implementation too:
    the user id comes from a **cryptographically validated token**, never from
    a header, query parameter or request body the client controls. Every
    downstream authorisation decision — above all the RAG index filter —
    depends on this value being unforgeable.
    """
    header = request.headers.get("authorization", "")
    if not header.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing bearer token.",
        )
    # A real implementation validates the token here. Returning the raw token
    # would be a severe vulnerability, so this placeholder deliberately
    # returns a fixed value rather than anything client-derived.
    return "00000000-0000-0000-0000-000000000000"


@app.post("/v1/assistant/ask", tags=["assistant"])
async def ask(
    payload: dict[str, Any],
    user_id: str = Depends(current_user_id),
) -> JSONResponse:
    """Ask the assistant a question about your own documents.

    Note that `user_id` comes from the dependency, not from `payload`. A
    request body containing `{"userId": "someone-else"}` has no effect.
    """
    question = payload.get("question", "").strip()
    if not question:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="A non-empty 'question' is required.",
        )

    try:
        result = await rag.answer(question, user_id=user_id)
    except rag.UnauthorizedRetrievalError:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Retrieval requires an authenticated user.",
        ) from None

    return JSONResponse(content=result)


@app.get("/v1/meta", tags=["meta"])
async def meta(settings: Settings = Depends(get_settings)) -> dict[str, Any]:
    """Non-sensitive build and placement information."""
    return {
        "service": settings.service_name,
        "version": settings.service_version,
        "environment": settings.environment,
        "region": settings.region,
    }
