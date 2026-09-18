# syntax=docker/dockerfile:1
#
# Spark 4.0.4 with the six jars this pipeline needs already in /opt/spark/jars.
#
# The jars are baked in rather than resolved by `spark-submit --packages` for one
# reason: `--packages` runs Ivy resolution on every single submit. A reviewer on a
# slow connection then waits for 115 MB of Maven traffic before the first row
# appears, sees what looks like a hang, and concludes the repository does not
# work. Baking them in moves that cost to a one-time `docker compose build`, and
# makes the running container work with no network access to Maven at all.
#
# Every jar is pinned by full coordinate and verified against a sha256 digest
# computed on 2026-09-17. Maven Central artifacts are immutable, so a digest that
# stops matching means the download was tampered with or truncated — not that a
# version moved. Central publishes .sha1 for everything and .sha512 for only some
# artifacts, which is why these are self-computed rather than fetched.

# The Docker Official Images build of Spark, not `apache/spark`. Same version, same
# variant name, and the apache/spark one is broken: 41 of its 277 jars are
# zero-byte files, including spark-launcher, so `spark-submit` dies with
# `ClassNotFoundException: org.apache.spark.launcher.Main`, and /opt/entrypoint.sh
# is empty too, so the container cannot even start. Reproduced on a fresh pull and
# confirmed against the published filesystem rather than a running container:
#
#   docker run --rm --entrypoint sh apache/spark:4.0.4-scala2.13-java17-python3-ubuntu \
#     -c 'find /opt/spark/jars -size 0 | wc -l'      # -> 41
#   docker run --rm --entrypoint sh spark:4.0.4-scala2.13-java17-python3-ubuntu \
#     -c 'find /opt/spark/jars -size 0 | wc -l'      # -> 0
#
# Pinned by digest as well as tag, because that was exactly the failure mode: the
# tag resolved, the manifest was valid, and the contents were not what the version
# number promised. The digest is the only part of a reference that can say so.
FROM spark:4.2.0-scala2.13-java17-python3-ubuntu@sha256:a9e21a6dcb79481003d672ae4e491097028134db25ff8034677d99ad2b2cc67e

# Root only for the jar downloads and the directory setup. The image drops back to
# Spark's own unprivileged uid before the end.
USER root

ARG ICEBERG_VERSION=1.10.1
ARG SPARK_VERSION=4.0.4
ARG SCALA_BINARY=2.13
# Not a free choice: this is the version spark-sql-kafka-0-10_2.13:4.0.4 declares
# in its POM. A newer kafka-clients is the classic source of a
# NoSuchMethodError at consumer construction time.
ARG KAFKA_CLIENTS_VERSION=3.9.1
# Likewise from the connector's POM. Used for its consumer pool.
ARG COMMONS_POOL2_VERSION=2.12.0

# Why each of the six, since "add these jars" is the least explicable step in any
# Spark-plus-Iceberg setup:
#
#   iceberg-spark-runtime  the catalog, the SQL extensions, MERGE INTO, and the
#                          Iceberg reader/writer. Must be the _2.13 build: Spark
#                          4.x is Scala 2.13 only, and the _2.12 jars that most
#                          Iceberg material still shows fail at class-load time
#                          with a NoSuchMethodError that never mentions Scala.
#   iceberg-aws-bundle     S3FileIO plus a shaded AWS SDK v2. Iceberg talks to
#                          MinIO through this, not through Hadoop's s3a.
#   spark-sql-kafka-0-10   the Kafka source for Structured Streaming.
#   spark-token-provider-  a hard dependency of the above that `--packages` would
#     kafka-0-10           have pulled in silently. Omitting it produces a
#                          ClassNotFoundException on the first micro-batch, long
#                          after the job appears to have started cleanly.
#   kafka-clients          the connector is compiled against it and does not
#                          bundle it.
#   commons-pool2          the connector's consumer pool needs it.
#
# The Spark image already ships zstd-jni, lz4-java and snappy-java, so the
# consumer can read this project's zstd-compressed topic with no extra jar.
RUN set -eux; \
    base=https://repo1.maven.org/maven2; \
    for entry in \
      "org/apache/iceberg/iceberg-spark-runtime-4.0_${SCALA_BINARY}/${ICEBERG_VERSION}/iceberg-spark-runtime-4.0_${SCALA_BINARY}-${ICEBERG_VERSION}.jar 2192a0881ed0f5773b5a83a8820d2b0b2069beec203028643a1c338551007f09" \
      "org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar 86bf20892ea5b4c17688f19b075399885f6aa5303f6b2dc9f491e76ceef9633b" \
      "org/apache/spark/spark-sql-kafka-0-10_${SCALA_BINARY}/${SPARK_VERSION}/spark-sql-kafka-0-10_${SCALA_BINARY}-${SPARK_VERSION}.jar b2f7b3a4fbf292b5bf10bd4dd6af301eded9c9985b16239b407401d66dbc8a25" \
      "org/apache/spark/spark-token-provider-kafka-0-10_${SCALA_BINARY}/${SPARK_VERSION}/spark-token-provider-kafka-0-10_${SCALA_BINARY}-${SPARK_VERSION}.jar ae9817053af94a21992e948269eba1a50d511333cb51462865983abfbeea7f60" \
      "org/apache/kafka/kafka-clients/${KAFKA_CLIENTS_VERSION}/kafka-clients-${KAFKA_CLIENTS_VERSION}.jar 7568b998572d256f0b7bc0afdc1b7a2588b8b08415c62ce314c864a6851ae9d9" \
      "org/apache/commons/commons-pool2/${COMMONS_POOL2_VERSION}/commons-pool2-${COMMONS_POOL2_VERSION}.jar 6d3bd18df8410f3e31b031aca582cc109342358a62a2759ebd0c4cdf30d06f8b" \
    ; do \
      set -- ${entry}; \
      path="$1"; digest="$2"; jar="${path##*/}"; \
      curl -fsSL --retry 3 --retry-delay 2 -o "/opt/spark/jars/${jar}" "${base}/${path}"; \
      echo "${digest}  /opt/spark/jars/${jar}" | sha256sum -c -; \
    done

# The streaming jobs read their configuration through `wikistream.config`, which is
# pydantic-settings. Two libraries, pinned to the versions in uv.lock so that a job
# in this image validates its settings exactly the way the unit tests did — a
# different pydantic here would mean the tests prove nothing about the container.
#
# Deliberately *not* installing this project's other runtime dependencies. httpx,
# confluent-kafka and websockets belong to the producer; Spark reaches Kafka
# through the JVM connector, so a Python Kafka client in this image would be a
# second, unused client and a second thing to keep in step. `--no-deps` with every
# transitive dependency named makes that explicit rather than accidental.
RUN pip install --no-cache-dir --no-deps \
      pydantic==2.13.5 \
      pydantic-core==2.46.5 \
      pydantic-settings==2.15.0 \
      annotated-types==0.8.0 \
      typing-extensions==4.16.0 \
      typing-inspection==0.4.4 \
      python-dotenv==1.2.3

# Checkpoints and the event log are bind-mounted or volume-mounted at run time;
# creating them here means the container does not need to be root to write them.
# 185 is the uid the upstream Spark image runs as.
RUN mkdir -p /opt/spark/checkpoints /opt/spark/work-dir /opt/wikistream \
    && chown -R 185:185 /opt/spark/checkpoints /opt/spark/work-dir

# PySpark needs to find this project's modules. The source tree is mounted rather
# than copied so that editing a streaming job does not need an image rebuild — the
# jars are the slow part of this image and they never change during development.
ENV PYTHONPATH=/opt/wikistream/src \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

USER 185
WORKDIR /opt/spark/work-dir
