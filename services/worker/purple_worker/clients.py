"""Azure SDK clients, authenticated with a managed identity.

**There is not one credential in this file.** That is the entire point.

`DefaultAzureCredential` walks an ordered chain of authentication methods and
uses the first that works:

  1. Environment variables (a service principal secret) — NOT used here.
  2. **Workload identity** — the pod's projected service account token is
     exchanged with Entra for an Azure access token. This is what succeeds in
     the cluster.
  3. Managed identity (IMDS) — for VMs and other Azure compute.
  4. Azure CLI / Developer CLI / PowerShell — what succeeds on a developer's
     laptop, using *their* identity.

Step 2 in production and step 4 locally means the same code runs in both
places with no configuration branch and no secret in either. A developer runs
`az login` and the application works; a pod presents its service account token
and the application works.

The credential is created once and shared. Creating one per request would
re-run the whole chain and re-fetch a token every time — a measurable latency
cost and, at 2,000 req/s, enough traffic to get throttled by Entra.
"""

from __future__ import annotations

import asyncio
import contextlib
from functools import lru_cache
from typing import Any

from azure.cosmos.aio import CosmosClient
from azure.identity.aio import DefaultAzureCredential
from azure.search.documents.aio import SearchClient
from openai import AsyncAzureOpenAI

from purple_worker.config import get_worker_settings as get_settings
from purple_worker.telemetry import get_logger

log = get_logger(__name__)


@lru_cache(maxsize=1)
def get_credential() -> DefaultAzureCredential:
    """Return the process-wide credential.

    `exclude_shared_token_cache_credential` avoids a slow probe of a cache
    that never exists in a container, trimming startup time.
    """
    return DefaultAzureCredential(exclude_shared_token_cache_credential=True)


@lru_cache(maxsize=1)
def get_cosmos_client() -> CosmosClient:
    """Cosmos client.

    Note the absence of a key or connection string. The account has
    `local_authentication_enabled = false`, so a key would not work even if
    one existed — the only way in is a token from the workload identity, and
    the data-plane role assignment granted in Terraform.

    A common confusion: Cosmos has two RBAC systems. The Azure control-plane
    roles ("Cosmos DB Account Reader") let you read the account's *metadata*.
    Reading *documents* needs a data-plane role assignment, which is a
    different resource type entirely. Granting Contributor on the account and
    expecting to read data is a mistake that produces a 403 with a message
    that does not explain why.
    """
    settings = get_settings()
    return CosmosClient(url=str(settings.cosmos_endpoint), credential=get_credential())


@lru_cache(maxsize=1)
def get_search_client() -> SearchClient:
    """AI Search client for the document index."""
    settings = get_settings()
    return SearchClient(
        endpoint=str(settings.search_endpoint),
        index_name=settings.search_index_name,
        credential=get_credential(),
    )


@lru_cache(maxsize=1)
def get_openai_client() -> AsyncAzureOpenAI:
    """Azure OpenAI client.

    Authenticated with a bearer token from the same credential rather than an
    API key. `azure_ad_token_provider` is given a callable so the SDK can
    refresh the token when it expires — passing a token string directly would
    work until the first expiry, then fail in a way that looks intermittent.
    """
    from azure.identity.aio import get_bearer_token_provider

    settings = get_settings()
    token_provider = get_bearer_token_provider(
        get_credential(), "https://cognitiveservices.azure.com/.default"
    )

    return AsyncAzureOpenAI(
        azure_endpoint=str(settings.openai_endpoint),
        azure_ad_token_provider=token_provider,
        api_version=settings.openai_api_version,
        timeout=settings.request_timeout_seconds,
        # Two retries with exponential backoff. Azure OpenAI returns 429 under
        # capacity pressure, and a bounded retry is the correct response — but
        # only a bounded one: unlimited retries against a saturated model
        # deployment turn a slowdown into a self-inflicted outage.
        max_retries=2,
    )


# --------------------------------------------------------------------------
# Readiness probes.
#
# Each is the CHEAPEST call that proves the dependency is genuinely reachable
# and this identity is genuinely authorised.
#
# "Cheapest" matters: readiness runs every few seconds on every pod. A probe
# that runs a real query would, at 30 pods and a 5-second period, add 360
# queries a minute of pure overhead — and on Cosmos, that is RU spent on
# nothing.
# --------------------------------------------------------------------------


async def probe_cosmos() -> None:
    """Read the database's own metadata.

    This exercises DNS resolution, the private endpoint route, TLS, token
    acquisition and authorisation — the entire path — while costing roughly
    one RU. A `SELECT * FROM c` would prove no more and cost far more.
    """
    settings = get_settings()
    client = get_cosmos_client()
    database = client.get_database_client(settings.cosmos_database)
    await database.read()


async def probe_search() -> None:
    """Count documents in the index.

    Cheap, and it proves both reachability and that this identity holds a
    data-plane role. A control-plane call would succeed with only
    control-plane permissions and give a false positive.
    """
    client = get_search_client()
    await client.get_document_count()


async def probe_openai() -> None:
    """List deployments.

    Deliberately NOT a completion request: a completion costs real money on
    every probe, adds latency, and consumes the TPM quota the actual users
    need. This verifies connectivity and authorisation, which is what a
    readiness probe is for.
    """
    client = get_openai_client()
    await asyncio.wait_for(client.models.list(), timeout=2.0)


async def close_clients() -> None:
    """Close every client on shutdown.

    Called from the lifespan handler. Without this, the async transports leak
    connections and Kubernetes' graceful shutdown window expires, turning a
    clean rollout into SIGKILL and dropped in-flight requests.
    """
    for factory in (get_cosmos_client, get_search_client, get_openai_client):
        try:
            client: Any = factory()
            if hasattr(client, "close"):
                await client.close()
        except Exception:  # noqa: BLE001
            log.warning("client_close_failed", client=factory.__name__)

    # The credential holds its own HTTP transport. Failing to close it on
    # shutdown is not worth crashing over, and there is nothing useful to do
    # about it, so it is suppressed rather than logged.
    with contextlib.suppress(Exception):
        await get_credential().close()
