# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A local lakehouse playground: Docker images (`docker_build/`) plus a Compose stack (`docker_run/`)
that wires Postgres/MySQL -> Debezium/Kafka -> Spark + Hudi/Iceberg/Delta -> MinIO (S3) -> Hive
Metastore -> Trino/Flink. There is no application source code, no test suite, and no lint tooling:
everything is Dockerfiles, shell scripts, and service config.

## Commands

Build images (runnable from anywhere; the build context is pinned to `docker_build/`):

```sh
./docker_build/build_docker_images.sh
```

The script first downloads prerequisites into gitignored dirs (`software/`, `hadoop-s3-jars/`,
`db_connector_jars/`, `lib/`) via `download_flink_jars.sh`, then builds each image in the
`image_builds` array. Only `hive`, `spark`, `kafka-connect`, `kafka-cat` are enabled; `trino`,
`jupyter-notebook`, `xtable`, `flink` are commented out — uncomment to build them. Versions come
from env vars with defaults at the top of the script (`SPARK_VERSION`, `HIVE_VERSION`, …).

Run the stack (from anywhere; the script resolves its own dir):

```sh
sh docker_run/run_datalake.sh                      # start (default)
sh docker_run/run_datalake.sh stop|restart|status
sh docker_run/run_datalake.sh logs spark-master    # follow one or more services
sh docker_run/run_datalake.sh validate             # compose config -q, no containers touched
PROFILE=all sh docker_run/run_datalake.sh start    # superset stack
```

`validate` is the cheap check to run after editing either compose file — a dangling
`depends_on` makes the whole project invalid and `start` fails before anything launches.

Publish (pushes *every* local image whose repository contains `ranga-`, both tags):

```sh
./publish-to-dockerhub.sh
```

Build one image manually:

```sh
cd docker_build && docker build --build-arg SPARK_VERSION=3.5.5 --platform linux/arm64 \
  -f Dockerfile.spark . -t rangareddy1988/ranga-spark:3.5.5
```

## Architecture

**Storage plane.** MinIO is the S3 endpoint (`http://minio:9000`, `admin`/`password`). The `mc`
sidecar creates the `warehouse` and `datalake` buckets on startup and then idles. `core-site.xml`
(baked into the Spark and Flink images) sets `fs.defaultFS=s3a://warehouse/` with static
credentials, so bare paths in Spark resolve to MinIO.

**Catalog plane.** A single Hive Metastore (`thrift://hive-metastore:9083`, Postgres-backed) is the
shared catalog for Spark (`spark.sql.catalogImplementation=hive`), Trino (every catalog in
`conf/trino/catalog/` points at it), Flink, and Hudi hive-sync. Anything written with sync enabled
becomes queryable from Trino without extra registration.

**Ingestion plane.** Two independent CDC routes land data in Hudi:
- *Hudi Streamer* — Debezium source connector (`docker_run/debezium_configs/streamer_connector/`,
  `multi_table_streamer_connector/`) publishes Avro to Kafka against the Schema Registry, then
  `HoodieStreamer` / `HoodieMultiTableStreamer` is `spark-submit`ted inside `spark-master` using the
  properties under `docker_run/hudi_streamer/`.
- *Hudi Kafka Connect sink* — configs under `docker_run/debezium_configs/hudi_kafka_connector/`
  write from Kafka to Hudi directly inside the `kafka-connect` container.

Both paths are driven interactively via `docker exec`; the README holds the full command
transcripts for each.

### Two compose files

`docker_run/docker-compose.yml` is the default (`PROFILE=core`): Kafka stack, Hive, Spark, Postgres,
MinIO, Cloudbeaver. `docker_run/docker-compose_all.yml` is the superset (`PROFILE=all`) — it adds
MySQL, Trino, Jupyter, XTable, and Flink (jobmanager/taskmanager).

The two files duplicate the shared service definitions verbatim, so **any change to a common service
must be applied to both**. This duplication has already caused one outage: `cloudbeaver` in
`docker-compose.yml` carried a `depends_on: mysql` that only exists in the `_all` file, which made
the entire core project invalid. Run `sh docker_run/run_datalake.sh validate` (and the same with
`PROFILE=all`) after touching either file.

### Config is baked into images, not mounted

`spark-defaults.conf`, `hudi-defaults.conf`, `core-site.xml`, `hive-site.xml`, `flink-conf.yaml`,
and the Trino catalog files under `docker_build/conf/` are `COPY`d at build time. Editing them
requires rebuilding the image and recreating the container — a `restart` will not pick them up.
The only live-editable config is what the compose files bind-mount: `docker_run/hudi_streamer/`,
`docker_run/debezium_configs/`, and the DB init SQL under `docker_run/db_scripts/`.

### Image tags must line up with compose

`build_docker_images.sh` tags each image `rangareddy1988/ranga-<name>:<version>` *and* `:latest`.
Compose resolves e.g. `rangareddy1988/ranga-spark:${SPARK_VERSION:-latest}`, and `docker_run/.env`
pins those versions to match the build script's defaults. A pin that was never built makes Docker
try to pull a nonexistent tag from Docker Hub, so `.env` and `build_docker_images.sh` must move
together. The `all`-profile images (`trino`, `xtable`, `jupyter-notebook`, `flink`) are commented
out of the build script's `image_builds` array, so they must be enabled and built before
`PROFILE=all` will start.

### Container lifecycle

Custom images (`spark`, `xtable`, `kafka-cat`) end their entrypoint with a
`while true; do sleep 1000; done` keepalive — the container being "up" says nothing about the
service inside. `docker_build/check_service_status_utility.sh` (baked in at
`/opt/check_service_status_utility.sh`) polls `jps` to verify a JVM process actually started.
`scripts/spark/entrypoint.sh` branches on `SPARK_MODE` (`master` | `worker` | `history` | `connect`).

### Gitignored build inputs

`docker_build/{software,hadoop-s3-jars,db_connector_jars,lib,hudi,hudi_*}` and
`docker_run/{data,logs}` are all gitignored. A fresh clone cannot build any image until
`build_docker_images.sh` has populated them. `docker_run/data/` holds the Postgres data dir and
MinIO object store — `run_datalake.sh stop` does a `down` without `-v`, so bind-mounted state
survives restarts and must be deleted manually for a clean slate.

### Local-path gotcha in the Hudi/Flink scripts

`download_and_build_hudi.sh` and `download_flink_jars.sh` both branch on whether `whoami` contains
`ranga` and, if so, use `$HOME/ranga_work/apache/hudi` as the Hudi checkout instead of a local
clone. `download_and_build_hudi.sh` is not called by `build_docker_images.sh` (the line is commented
out); it exists to build Hudi from source and stage the bundle jars for the Flink image.

## Conventions

- Everything is Bash + Docker; scripts use `set -e`/`set -euo pipefail` and resolve their own
  directory via `CURRENT_DIR="$(cd "$(dirname "$0")"; pwd -P)"`.
- All versions are `${VAR:-default}` env-var overridable, both in scripts and in Dockerfile `ARG`s.
- Services attach to the single external-facing `datalake` bridge network; use container names
  (`minio`, `kafka`, `hive-metastore`) for in-network addressing and `localhost:<host-port>` from
  the host.
- Credentials are uniform demo values (`admin`/`password`, `postgres`/`postgres`) hardcoded across
  `aws.env`, `core-site.xml`, the Trino catalogs, and the compose files. Changing one means changing
  all of them.
- Host port mapping is not always identity: the Spark worker UI (container 8081) is published on
  18081 to avoid colliding with the Schema Registry on 8081, and Trino (container 8080) on 9084 to
  avoid the Spark master. The README table is the authoritative port list.
