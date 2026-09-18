# syntax=docker/dockerfile:1
#
# The Dagster control plane: webserver and daemon, from one image.
#
# Two containers run from this image because Dagster's two processes do different
# jobs — the webserver serves the UI and the GraphQL API, the daemon runs the
# schedules, the sensor and the run queue — but they must agree exactly about what
# the asset graph is. Two images would be two chances for them to disagree, and
# the symptom of that is a schedule firing a job the UI does not show.
#
# The image carries dbt as well as Dagster, and that is not incidental: the
# `build_marts` job shells out to `dbt build`, so a Dagster image without dbt in it
# can load the graph and cannot execute half of it. The dbt in here comes from the
# same `--group analytics` of the same uv.lock as docker/dbt.Dockerfile, so
# `make dbt-build` and the Dagster job run byte-identical dbt.
#
# It does not carry Spark. That boundary is the subject of
# src/wikistream_dagster/maintenance.py: this process observes the tables Spark
# writes and maintains the tables dbt writes, and never writes to bronze or silver
# itself.

FROM python:3.14.7-slim-trixie AS builder

# Pinned to the version that produced the committed uv.lock, as in the other three
# Dockerfiles. A newer uv can resolve differently.
COPY --from=ghcr.io/astral-sh/uv:0.12.15 /uv /usr/local/bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/opt/venv

WORKDIR /src

# Two groups, and the project's own dependencies with them. `orchestration` brings
# dagster, dagster-webserver and dagster-dbt; `analytics` brings dbt-core, dbt-trino
# and the Trino client the resources connect through. The default groups stay out —
# `dev` and `spark` are 400 MB of pytest and JVM jars this container never runs.
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-default-groups \
    --group orchestration --group analytics

# The project is installed, unlike in docker/dbt.Dockerfile: this image imports
# `wikistream_dagster` for the definitions and `wikistream` for the settings and
# the Kafka client that `KafkaResource` reads topic watermarks with.
COPY src/ ./src/
COPY README.md ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-editable --no-default-groups \
    --group orchestration --group analytics


FROM python:3.14.7-slim-trixie AS runtime

# curl for the webserver's healthcheck. git because dbt shells out to it to record
# the project's commit in run_results.json and warns on every invocation without
# it. No build toolchain in a runtime image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

# Unprivileged, and unlike the dbt container this one can afford to be: the dbt
# project is mounted read-only here and every artefact dbt would write beside it
# goes to the scratch paths below instead. So there is no host uid to match and no
# `user:` override in docker-compose.yml — the process that can launch arbitrary
# runs is the one it is least appropriate to run as root.
RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin wikistream

COPY --from=builder --chown=root:root /opt/venv /opt/venv
COPY --chown=root:root docker/dagster/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# The instance directory: run store, event log, schedule state and captured step
# logs. docker-compose.yml mounts a named volume here, which inherits this
# ownership, so run history survives `make down` and `make clean` removes it.
RUN mkdir -p /opt/dagster/home && chown wikistream:wikistream /opt/dagster/home

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    # Where dagster.yaml is read from and where SQLite lives. Both processes get
    # the same value, which is what makes them one deployment.
    DAGSTER_HOME=/opt/dagster/home \
    # The dbt project, mounted read-only from the host.
    WS_DBT_PROJECT_DIR=/opt/dbt \
    DBT_PROFILES_DIR=/opt/dbt \
    # dbt writes a target directory and a log file next to the project by default,
    # and a read-only project directory turns both into a failure partway into the
    # first invocation rather than at start-up. Redirected to scratch: these are
    # per-invocation artefacts, and dagster-dbt already keeps the ones worth
    # keeping — it streams run_results into the event log.
    #
    # DBT_TARGET_PATH is dbt's own variable rather than a WS_-prefixed one because
    # three things have to agree on it: dbt itself, the DbtProject in
    # wikistream_dagster.dbt_project, and dagster-dbt, which roots its
    # per-invocation target directory at whatever this variable says. Nothing
    # passes it between them, so it has to be the name they all already read.
    DBT_TARGET_PATH=/tmp/dbt-target \
    DBT_LOG_PATH=/tmp/dbt-logs \
    WS_LOG_JSON=true

USER wikistream
WORKDIR /opt/dagster

LABEL org.opencontainers.image.title="wikistream-dagster" \
      org.opencontainers.image.description="Dagster webserver and daemon for the wikistream lakehouse" \
      org.opencontainers.image.source="https://github.com/william-sarkar/wikistream-lakehouse" \
      org.opencontainers.image.licenses="Apache-2.0"

# The entrypoint parses the dbt project before exec'ing whatever it is given, for
# the reason set out in that script. docker-compose.yml overrides the command for
# the daemon; the default is the webserver, because that is what a human wants
# when they run this image by hand.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["dagster-webserver", "--host", "0.0.0.0", "--port", "3000", \
     "-m", "wikistream_dagster.definitions"]
