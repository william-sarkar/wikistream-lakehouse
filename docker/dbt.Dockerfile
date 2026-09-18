# syntax=docker/dockerfile:1
#
# dbt-core plus the Trino adapter, and nothing else. The project itself is bind
# mounted at run time rather than copied in, because a dbt image that has to be
# rebuilt to edit a model is a slow way to write SQL.
#
# The dependency set comes from the same uv.lock the rest of the repository is
# pinned by — `--only-group analytics` — so the dbt in this container is exactly
# the dbt that CI runs and that `uv run dbt` runs on the host. Three copies of
# dbt at two versions is a debugging experience worth spending a Dockerfile to
# avoid.

FROM python:3.14.7-slim-trixie AS builder

COPY --from=ghcr.io/astral-sh/uv:0.12.15 /uv /usr/local/bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/opt/venv

WORKDIR /src

# --no-install-project: dbt does not import this project's Python, and installing
# it would drag in confluent-kafka's C extension for nothing.
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-default-groups --only-group analytics


FROM python:3.14.7-slim-trixie AS runtime

# git, because dbt shells out to it to record the project's commit in
# run_results.json and warns on every invocation when it is missing. That
# provenance is the point of the artefact, so the 6 MB is worth it.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder --chown=root:root /opt/venv /opt/venv

# No `USER` line, deliberately. dbt writes target/ and logs/ into the
# bind-mounted project directory, so the container has to run as whoever owns
# that directory on the host — a uid baked in here would be wrong on every
# machine but one. docker-compose.yml sets `user:` from WS_DOCKER_USER instead,
# and the Makefile fills that in from `id -u`.
ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    # An arbitrary uid has no entry in /etc/passwd and therefore no home
    # directory; anything calling expanduser("~") then raises. Nothing here needs
    # a real home, so it is pointed somewhere writable.
    HOME=/tmp \
    # dbt looks for profiles.yml in ~/.dbt by default. Pointing it at the project
    # directory keeps the profile in version control next to the models it
    # configures, which is the only way it can be reviewed.
    DBT_PROFILES_DIR=/opt/dbt

WORKDIR /opt/dbt

LABEL org.opencontainers.image.title="wikistream-dbt" \
      org.opencontainers.image.description="dbt-core with the Trino adapter for the gold marts" \
      org.opencontainers.image.source="https://github.com/william-sarkar/wikistream-lakehouse" \
      org.opencontainers.image.licenses="Apache-2.0"

ENTRYPOINT ["dbt"]
CMD ["--version"]
