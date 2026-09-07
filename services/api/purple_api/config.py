"""Configuration, read from the environment, validated at startup.

Two rules govern this module:

1. **No secrets.** Every value here is an endpoint, an identifier, or a
   tuning parameter. There is no connection string, no key, no password. The
   application authenticates with a managed identity, so the only thing it
   needs to know is *where* things are, never *how to prove who it is*.

2. **Fail at startup, not at first use.** A missing endpoint should crash the
   pod immediately, so the deployment fails and the rollout stops. A missing
   endpoint discovered on the first user request is an outage instead.
"""

from __future__ import annotations

from functools import lru_cache

from pydantic import Field, HttpUrl
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application settings.

    Populated from environment variables, which in Kubernetes come from a
    ConfigMap. Nothing here comes from a Secret, because nothing here is one.
    """

    model_config = SettingsConfigDict(
        env_prefix="PURPLE_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # --- identity -------------------------------------------------------
    environment: str = Field(default="dev", description="dev, stage or prod.")
    region: str = Field(default="eastus2", description="Azure region this replica runs in.")
    service_name: str = Field(default="purple-api")
    service_version: str = Field(
        default="0.0.0", description="Injected from the image tag at deploy time."
    )

    # --- Azure resource endpoints ---------------------------------------
    cosmos_endpoint: HttpUrl = Field(description="Cosmos DB account endpoint.")
    cosmos_database: str = Field(default="purple")

    openai_endpoint: HttpUrl = Field(description="Azure OpenAI account endpoint.")
    openai_chat_deployment: str = Field(default="chat")
    openai_embedding_deployment: str = Field(default="embeddings")
    openai_api_version: str = Field(default="2024-10-21")

    search_endpoint: HttpUrl = Field(description="Azure AI Search endpoint.")
    search_index_name: str = Field(default="purple-documents")

    # --- behaviour ------------------------------------------------------
    log_level: str = Field(default="INFO")

    # Deliberately shorter than Front Door's 60s origin timeout. A request the
    # origin will abandon should be abandoned by the origin, so the error is
    # attributable to this service rather than surfacing as an edge timeout
    # with no trace.
    request_timeout_seconds: float = Field(default=30.0)

    # How long the readiness probe's dependency checks may take in total.
    # Must stay below the probe's own timeout in the Deployment manifest,
    # or the probe fails on the timeout rather than on the real reason.
    readiness_timeout_seconds: float = Field(default=3.0)

    # RAG retrieval depth. Higher recall costs more tokens in the prompt and
    # more latency; this is the single biggest quality/cost lever.
    rag_top_k: int = Field(default=5, ge=1, le=50)

    @property
    def is_production(self) -> bool:
        return self.environment == "prod"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Return the singleton settings object.

    Cached so that validation happens exactly once, at first access during
    startup. FastAPI's dependency injection calls this per request; without
    the cache that would re-parse the environment on every request.
    """
    return Settings()  # type: ignore[call-arg]
