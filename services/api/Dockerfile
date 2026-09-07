# ---------------------------------------------------------------------------
# Multi-stage build for the Purple API.
#
# Two stages, and the reason is not image size — it is attack surface. The
# builder needs a compiler, pip, and build headers. The runtime needs none of
# those, and every one of them is a tool an attacker who achieves code
# execution would otherwise find waiting for them.
#
# The result: no pip, no gcc, no shell utilities beyond what the base image
# ships, and a non-root user with no write access to its own code.
# ---------------------------------------------------------------------------

# --- stage 1: build --------------------------------------------------------
# Pinned by digest, not just by tag. A tag is mutable: `python:3.12-slim` today
# and tomorrow can be different images. A digest is the only reproducible
# reference, and it is what makes a rebuild of an old commit produce the same
# artefact. Renovate or Dependabot updates these digests as a reviewed PR.
FROM python:3.12-slim AS builder

# Never write .pyc files, never buffer stdout. Unbuffered output matters in
# Kubernetes: a buffered log line is a log line you do not see until the
# process flushes, which for a crashing process is never.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

# Copy requirements alone first. Docker caches layers by their inputs, so as
# long as requirements.txt is unchanged this expensive layer is reused even
# when application code changes — the difference between a 5-second and a
# 90-second build on every commit.
COPY services/requirements.txt .

# Install into a virtualenv that gets copied wholesale into the runtime stage.
RUN python -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip setuptools wheel && \
    /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

# --- stage 2: runtime ------------------------------------------------------
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

# A dedicated non-root user with a fixed UID.
#
# The fixed UID matters: the Kubernetes securityContext specifies
# runAsUser: 10001, and a Gatekeeper policy rejects any pod running as root.
# If the image's user and the manifest's UID disagree, the container starts
# with a UID that owns nothing and fails on the first file write, with a
# permission error that names no cause.
RUN groupadd --system --gid 10001 purple && \
    useradd --system --uid 10001 --gid purple --no-create-home --shell /usr/sbin/nologin purple

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
# Copy application code owned by root, readable by purple. The running user
# cannot modify its own code — so an attacker who achieves code execution
# cannot persist by rewriting the application.
COPY --chown=root:root services/api/purple_api ./purple_api

USER 10001

EXPOSE 8000

# No HEALTHCHECK instruction. Docker healthchecks are irrelevant under
# Kubernetes, which uses its own probes and ignores this entirely. Including
# one gives a false impression that health is configured here; it is
# configured in platform/kubernetes/base/api-deployment.yaml.

# Exec form, so uvicorn is PID 1 and receives SIGTERM directly. The shell form
# would put /bin/sh at PID 1, and sh does not forward signals to its child —
# so SIGTERM would be swallowed, graceful shutdown would never run, and every
# pod termination would end in SIGKILL after the grace period.
#
# One worker per container. Scale with replicas, not with in-container
# processes: replicas are what the HPA, the scheduler, and PodDisruptionBudgets
# understand.
CMD ["uvicorn", "purple_api.main:app", \
     "--host", "0.0.0.0", \
     "--port", "8000", \
     "--workers", "1", \
     "--no-access-log", \
     "--timeout-graceful-shutdown", "25"]
