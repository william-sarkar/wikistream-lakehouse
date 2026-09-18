# syntax=docker/dockerfile:1
#
# The producer: one HTTP connection out to Wikimedia, one Kafka producer in.
#
# Two stages, because the wheel-building stage needs uv and a writable cache and
# the runtime stage needs neither. The result is a ~180 MB image containing an
# interpreter, five libraries and this project — no compiler, no uv, no Spark.
#
# Dependencies are installed in a separate layer from the source tree so that
# editing a Python file does not re-resolve the lockfile.

FROM python:3.14.7-slim-trixie AS builder

# Pinned to the version that produced the committed uv.lock. A newer uv can
# resolve differently, which would make the image stop matching the lockfile the
# tests ran against.
COPY --from=ghcr.io/astral-sh/uv:0.12.15 /uv /usr/local/bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/opt/venv

WORKDIR /src

# --no-install-project: the project itself is copied in below and installed in a
# second, cheap layer, so a source edit does not invalidate the dependency layer.
# --no-default-groups: dev, spark, analytics and orchestration are all
# irrelevant here; the producer needs httpx, confluent-kafka, pydantic and
# websockets and nothing else.
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-default-groups

COPY src/ ./src/
COPY README.md ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-editable --no-default-groups


FROM python:3.14.7-slim-trixie AS runtime

# curl for the healthcheck and for a human debugging inside the container;
# ca-certificates because the Wikimedia stream is HTTPS and a slim image has no
# trust store worth relying on. Nothing else — no build toolchain in a runtime.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Unprivileged: this process makes an outbound internet connection and parses
# untrusted JSON from it. It has no reason to be able to write anywhere.
RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin wikistream

COPY --from=builder --chown=root:root /opt/venv /opt/venv

ENV PATH="/opt/venv/bin:${PATH}" \
    # Unbuffered, or the JSON log lines sit in a pipe buffer and
    # `docker compose logs -f` shows nothing for the first few minutes.
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    WS_LOG_JSON=true

USER wikistream
WORKDIR /home/wikistream

LABEL org.opencontainers.image.title="wikistream-producer" \
      org.opencontainers.image.description="Wikimedia EventStreams to Kafka" \
      org.opencontainers.image.source="https://github.com/william-sarkar/wikistream-lakehouse" \
      org.opencontainers.image.licenses="Apache-2.0"

# Liveness, not readiness: the producer has no port to probe, so the check asks
# the process whether it has produced anything recently. See
# wikistream.producer.heartbeat for what "recently" means.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["python", "-m", "wikistream.producer.healthcheck"]

CMD ["python", "-m", "wikistream.producer"]
