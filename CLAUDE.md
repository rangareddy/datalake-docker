# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A local lakehouse playground: Docker images (`docker_build/`) plus a Compose stack (`docker_run/`)
that wires Postgres/MySQL -> Debezium/Kafka -> Spark + Hudi/Iceberg/Delta -> MinIO (S3) -> Hive
Metastore -> Trino. There is no application source code and no lint tooling: everything is
Dockerfiles, shell scripts and service config. `demos/e2e_test.sh` is the test suite.

## Commands

Build images (runnable from anywhere; the build context is pinned to `docker_build/`):

```sh
./docker_build/build_docker_images.sh
```

The script downloads prerequisites into gitignored dirs (`software/`, `hadoop-s3-jars/`,
`db_connector_jars/`, `lib/`), then builds every entry in the `image_builds` array. Versions come
from env vars with defaults at the top of the script (`SPARK_VERSION`, `HIVE_VERSION`, …). Downloads
are gated on what is actually selected, so `IMAGES=upstream` does not pull several GB of Spark and
Hadoop tarballs nothing in that set consumes. The Spark image is by far the slowest, since it
downloads the distribution plus about forty jars.

`IMAGES` limits the run to a subset, which is the fast path after editing one Dockerfile. Three
group names expand to sets:

```sh
IMAGES=spark SPARK_VERSION=4.1.3 ./docker_build/build_docker_images.sh
IMAGES=spark,trino ./docker_build/build_docker_images.sh
IMAGES=upstream ./docker_build/build_docker_images.sh    # the ten third-party wrappers
IMAGES=engines ./docker_build/build_docker_images.sh     # what this repo assembles
IMAGES=core ./docker_build/build_docker_images.sh        # everything docker-compose.yml starts
```

`build_docker_image` takes the build-arg name as an explicit argument rather than deriving it from
the image name. Deriving it was silently wrong for two images - `kafka-cat` sent `KAFKA_CAT_VERSION`
to a Dockerfile declaring `CONFLUENT_KAFKACAT_VERSION`, `jupyter-notebook` sent
`JUPYTER_NOTEBOOK_VERSION` to one declaring `JUPYTER_VERSION` - and Docker only warns about an
unknown `--build-arg`, so both quietly built whatever their `ARG` default happened to be. Any new
entry in `image_builds` must name its arg.

### One version for the whole stack

Every image carries the same tag, `rangareddy1988/ranga-<name>:1.0.0`, and it is the version of
the **stack**, not of the component inside it. `docker_run/.env` therefore has exactly one pin,
`IMAGE_VERSION`, and a compose file cannot ask for a tag that was never built because one
component moved.

Component versions - `SPARK_VERSION`, `HIVE_VERSION`, `CONFLUENT_VERSION` and the rest - are
build arguments and nothing more. Upgrading Spark from 3.5.9 to 3.5.10 does not produce
`ranga-spark:3.5.10`; it produces a different `1.0.0`. When a migration is worth announcing,
`IMAGE_VERSION` moves in `.env` *and* in `build_docker_images.sh`, and the Versions table in
README.md moves with it. Those three always move together.

`SPARK_VERSION` is the one component version that still has a runtime effect, because it selects
which of the two Spark images the stack starts (`ranga-spark` vs `ranga-spark4`). It does not
form a tag.

### Three services share an image with another service

There is no zookeeper, minio-mc or jupyter image, because the image each would need already
exists:

| Service | Runs from | Why |
| --- | --- | --- |
| `zookeeper` | `ranga-kafka` | `cp-kafka` ships `zookeeper-server-start` and the ZooKeeper jars. What it does not ship is a ZooKeeper properties template, so `ranga-kafka` bakes one at `/etc/kafka/zookeeper.properties` and the compose service overrides the entrypoint. The `ZOOKEEPER_*` environment variables `cp-zookeeper` understood do **not** work here - they are in that file instead |
| `mc` | `ranga-minio` | The server image already contains `/usr/bin/mc`. Its healthcheck is `disable: true`, because `ranga-minio` declares a `HEALTHCHECK` against a MinIO server this container is not running |
| `jupyter-notebook` | `ranga-spark` | The Spark image installs JupyterLab, spylon and IJava from `requirements.txt`. It starts with `SPARK_MODE=notebook`, which `scripts/spark/entrypoint.sh` handles |

That is roughly 4.8GB of duplicated content not built, not pulled and not stored. Before adding a
new image, check whether an existing one already carries what the service needs.

### Nothing is pulled from a third party at run time

Every image the compose files start is `rangareddy1988/ranga-*`, built from a Dockerfile in
`docker_build/`. Seven of those are thin wrappers - `kafka`, `kafka-schema-registry`, `kafka-rest`, `kafka-ui`,
`postgres`, `minio`, `mysql` - whose only job is to pin an upstream base and re-tag it under a
name this repo controls. Most add no layer at all and are exactly the size of their base.

This is not ceremony. Three upstream changes have already broken this stack: `docker.io/minio/minio`
stopped resolving, Confluent Hub dropped Debezium 2.4.2, and `provectuslabs/kafka-ui` was
discontinued at v0.7.2. With the wrapper in place each of those is a one-line edit plus a rebuild,
rather than a stack that stops starting for everyone who pulls.

Rules that follow from it:

- **No `image:` line in either compose file may point outside `rangareddy1988/`.** `e2e_test.sh`
  asserts this (`images:no-upstream`, `images:running`), so a regression fails the gate.
- **No pin is `latest`.** `.env` and the build script defaults are exact versions and must agree.
- **MinIO is pinned by digest, not tag.** quay.io serves only `:latest` anonymously; every
  `RELEASE.*` tag answers 401, so `Dockerfile.minio` and `Dockerfile.minio_mc` use
  `FROM quay.io/minio/...@sha256:...`. Refresh with
  `docker inspect quay.io/minio/minio:latest --format '{{index .RepoDigests 0}}'`.
- **`ranga-kafka` is the one wrapper that adds something**, and only a config file: the ZooKeeper
  properties that let the same image serve both roles.

### demos/e2e_test.sh is the gate in front of publishing

Change anything under `docker_build/` and the order is **rebuild, start, `./demos/e2e_test.sh`,
then publish**. The script drives every service through a real operation - produce and consume a
Kafka message, create a Debezium connector and read its snapshot row, submit a Spark job to the
cluster, write and read a table in each format the image ships, query Hive, round-trip an object
through MinIO - because "the container is Up" and "the service works" are different claims.

On a fully green run it writes `.e2e-passed` (gitignored) listing the ID of every live `ranga-*`
image. `publish-to-dockerhub.sh` refuses to push an image whose current ID is not in that list, and
rebuilding a Dockerfile changes the ID, so pushing an untested image fails locally rather than
reaching whoever pulls next. `E2E_OVERRIDE=1` bypasses it and says so loudly.

### Debian bullseye images need the archive fallback

`apache/hive:4.0.0` and `python:3.10-bullseye` (both Spark images) are Debian 11, which left LTS on
2026-08-31. `bullseye-security` still publishes an index advertising `+deb11uN` packages, but its
pool has been emptied, so `apt-get install` resolves a version and then 404s on every file. Both
Dockerfiles wrap their apt layer in a retry that rewrites `sources.list`: the Spark images fall back
to the pinned `snapshot.debian.org` lines their base ships commented out, and `Dockerfile.hive` falls
back to `archive.debian.org`, which still carries the bullseye release pool.

Each of those layers ends with a command that proves the install worked (`java -version`,
`jq --version`). That is load bearing: an earlier version let a failed apt through and the image
built fine, because `wget` already exists in the base - the breakage surfaced at runtime as
`java: command not found`.

### The Spark version matrix

`SPARK_VERSION` selects a profile and everything else is derived from it, because the Spark line
dictates the Scala binary, the bundled Hadoop, and which builds of the three formats exist:

| `SPARK_VERSION` | Scala | Hadoop | Hudi | Iceberg | Delta |
| --- | --- | --- | --- | --- | --- |
| `3.5.9` (default) | 2.12 | 3.3.4 | 1.1.1 | 1.11.0 | 3.3.2 |
| `4.1.3` | 2.13 | 3.4.2 | — | 1.11.0 | — |

Those are the only two lines; anything else exits with an error rather than being built
against a guessed Scala binary.

Each line has its own Dockerfile and image, because they differ in Scala binary, in which
connectors exist, and in which AWS SDK S3A wants - enough that one file with branches read
worse than two files:

| Line | Dockerfile | Image |
| --- | --- | --- |
| 3.5.x | `Dockerfile.spark3` | `ranga-spark` (unchanged, so old pulls still work) |
| 4.1.x | `Dockerfile.spark4` | `ranga-spark4` |

`build_docker_images.sh` sets `SPARK_IMAGE` from `SPARK_VERSION` and `run_datalake.sh`
derives the same value, so the compose files resolve
`rangareddy1988/${SPARK_IMAGE:-ranga-spark}:${SPARK_VERSION}` without being edited. Both
compose files were updated together, as every shared service change must be.

Any of the derived values can still be overridden individually, but the defaults are chosen so
the three connectors agree. Two constraints are worth keeping in mind before changing them:

- **The Spark 4.1 image is Iceberg-only, and this was measured.** `hudi-spark4.1-bundle` 1.2.0
  dies with `NoClassDefFoundError org/apache/parquet/variant/VariantConverters` because Spark
  4.1.3 ships Parquet 1.16.0 without that class while the bundle is built against 1.15.x;
  Delta 4.0.0 dies with `NoSuchMethodError org.apache.spark.internal.LogKey.$init$` and has no
  Scala 2.13 build past 4.0.0. `Dockerfile.spark4` ships neither, and both Dockerfiles skip a format whose version arg is empty,
  which is how the profile is expressed, and the smoke test reports those as skipped rather
  than failed. Use 3.5.9 when all three formats are needed.
- **S3A changes SDK between the profiles.** Hadoop 3.3.x uses AWS SDK v1
  (`com.amazonaws:aws-java-sdk-bundle`), Hadoop 3.4.x uses SDK v2 (`software.amazon.awssdk:bundle`).
  `download_hadoop_aws_jars` caches per Hadoop version under `.s3-jar-cache/<version>/` and then
  stages a clean `hadoop-s3-jars/`, because both Spark Dockerfiles COPY that directory wholesale and a
  leftover v1 bundle would shadow the v2 classes in a Spark 4 image.

When switching profiles, `docker_run/.env` has to move too — Compose resolves
`ranga-spark:${SPARK_VERSION}`, so a pin that was never built tries to pull from Docker Hub.

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
cd docker_build && docker build --build-arg SPARK_VERSION=3.5.9 \
  --platform "$(source ./validate_docker_status.sh >/dev/null 2>&1; get_docker_platform)" \
  -f Dockerfile.spark3 . -t rangareddy1988/ranga-spark:3.5.9
```

## Architecture

**Storage plane.** MinIO is the S3 endpoint (`http://minio:9000`, `admin`/`password`). The `mc`
sidecar creates the `warehouse` and `datalake` buckets on startup and then idles. `core-site.xml`
(baked into the Spark image) sets `fs.defaultFS=s3a://warehouse/` with static
credentials, so bare paths in Spark resolve to MinIO.

Both `s3a://` and `s3://` work everywhere, and the two are interchangeable against the same object:
a table written through one scheme reads back through the other. `s3://` is mapped onto
`S3AFileSystem` via `fs.s3.impl` (plus `fs.AbstractFileSystem.s3.impl` for FileContext callers) in
both `conf/hadoop/core-site.xml` and `conf/hive/hive-site.xml`. Credentials are **not** duplicated
per scheme: `S3AFileSystem` always reads the `fs.s3a.*` keys whichever scheme the URI used, so a
`fs.s3.access.key` would be dead config. Trino needs nothing here, since its native S3 filesystem
handles both schemes on its own. Only the Hadoop-based engines require the mapping.

Anything that talks to MinIO through Hadoop needs `core-site.xml` on its classpath. Only the Spark
image ships it; Hive carries the same settings inside `hive-site.xml`.

**Catalog plane.** A single Hive Metastore (`thrift://hive-metastore:9083`, Postgres-backed) is the
shared catalog for Spark (`spark.sql.catalogImplementation=hive`), Trino (every catalog in
`conf/trino/catalog/` points at it) and Hudi hive-sync. Anything written with sync enabled
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

`docker_run/docker-compose.yml` is the default (`PROFILE=core`): Kafka stack, Hive, Spark, Postgres
and MinIO. `docker_run/docker-compose_all.yml` is the superset (`PROFILE=all`) — it adds MySQL,
Trino and Jupyter.

The two files duplicate the shared service definitions verbatim, so **any change to a common service
must be applied to both**. This duplication has already caused one outage: a service in
`docker-compose.yml` carried a `depends_on: mysql` that only exists in the `_all` file, which made
the entire core project invalid. Run `sh docker_run/run_datalake.sh validate` (and the same with
`PROFILE=all`) after touching either file.

### Healthchecks have to be runnable *inside* the image

A healthcheck runs in the container, with only what that image ships. Two have been wrong
for that reason:

- `jupyter` used `nc`, which the old base did not have, so it reported `(unhealthy)` forever
  while Lab served fine. It now curls `/api`.
- `hive-server` had no healthcheck at all, so it reported no status and nothing could
  `depends_on` it being ready. It now probes the Thrift port on 10000.

When a container is stuck `(unhealthy)`, read what the probe actually printed before
assuming the service is down:

```sh
docker inspect <name> --format '{{range .State.Health.Log}}{{.Output}}{{end}}'
```

A third failure mode is a probe that answers while the service is not ready:

- `trino` served `/v1/info` - and so went `healthy` - while still returning
  `{"starting":true}` and failing every query with "Trino server is still initializing".
  The probe now greps for `"starting":false`.
- `minio` used a `/dev/tcp` probe; it now uses MinIO's own `/minio/health/live`, because
  an open port only proves something bound it.
- `mc` inherits `ranga-minio`'s `HEALTHCHECK`, which probes a MinIO server it does not run.
  Its compose service sets `healthcheck: disable: true`.

And a probe has to be aimed at the port the service actually binds, which is not always the
default. Check the service's own config before writing one.

### depends_on: service_healthy is evaluated once, so use it sparingly

Compose checks `condition: service_healthy` a single time at start. A service that is
merely slow is therefore indistinguishable from one that is broken, and its dependants
are never started at all - they sit in `Created`, with no logs to explain it.

`kafka-ui` was the casualty twice over, so it now waits on `service_started` for both
`kafka-connect` and `kafka-schema-registry`. It does not need either to be up: it shows
the connector and schema views as unavailable until they answer, then recovers on its
own. Prefer `service_started` unless the dependant genuinely cannot start without the
dependency, and give anything that stays on `service_healthy` a generous `start_period`
plus `start_interval`.

### Config is baked into images, not mounted

`spark-defaults.conf`, `hudi-defaults.conf`, `core-site.xml`, `hive-site.xml`,
`zookeeper.properties` and the Trino catalog files under `docker_build/conf/` are `COPY`d at
build time. Editing them
requires rebuilding the image and recreating the container — a `restart` will not pick them up.
The only live-editable config is what the compose files bind-mount: `docker_run/hudi_streamer/`,
`docker_run/debezium_configs/`, and the DB init SQL under `docker_run/db_scripts/`.

### Image tags must line up with compose

`build_docker_images.sh` tags each image `rangareddy1988/ranga-<name>:$IMAGE_VERSION` *and*
`:latest`, and compose resolves `${IMAGE_VERSION:-1.0.0}`. Since that is one value for the whole
stack, keeping them in step means keeping `IMAGE_VERSION` in `.env` equal to the default in
`build_docker_images.sh`. A pin that was never built makes Docker try to pull a nonexistent tag
from Docker Hub.

### kafka-connect gates kafka-ui

`kafka-ui` declares `depends_on: kafka-connect: condition: service_healthy`, and Compose
evaluates that **once, at start**. If Connect is not healthy at that moment, kafka-ui is
never started at all - it sits in `Created`, the UI is simply absent, and nothing in the
kafka-ui logs explains why, because it has no logs. Two things have caused that:

- **Connect crash-looping on a Debezium the JVM cannot load.** `UnsupportedClassVersionError`
  for a class compiled at 61.0 (Java 17) on `cp-server-connect-base:7.4.7`, which runs Java
  11. Debezium 3.x is Java 17; `DEBEZIUM_VERSION` is therefore pinned to 2.5.4, which is also
  the oldest version Confluent Hub still serves - the previous 2.4.2 pin failed the build
  outright with "Component not found". Moving to Debezium 3.x means a Java 17 base image.
- **Connect simply being slow.** It scans every plugin jar before binding 8083, measured at
  112s idle. The old `start_period: 20s` plus five 30s retries gave 170s, which the whole
  stack starting at once could exceed. It is now 180s of grace.

When the UI is missing, check `docker ps -a` for a `Created` kafka-ui and then Connect's
health - not kafka-ui itself.

### Container lifecycle

Custom images (`spark`, `kafka-cat`) end their entrypoint with a
`while true; do sleep 1000; done` keepalive — the container being "up" says nothing about the
service inside. `docker_build/check_service_status_utility.sh` (baked in at
`/opt/check_service_status_utility.sh`) polls `jps` to verify a JVM process actually started.
`scripts/spark/entrypoint.sh` branches on `SPARK_MODE`
(`master` | `worker` | `history` | `connect` | `notebook`) and refuses an unknown value rather
than falling through to the keepalive with nothing started.

`demos/` is bind-mounted into `spark-master` at `/opt/demos`, so `demos/e2e_test.sh` and the
demo scripts always run the working tree with no `docker cp` step.

### Gitignored build inputs

`docker_build/{software,hadoop-s3-jars,db_connector_jars,hudi,hudi_*}` and
`docker_run/{data,logs}` are all gitignored. A fresh clone cannot build any image until
`build_docker_images.sh` has populated them. `docker_run/data/` holds the Postgres data dir and
MinIO object store — `run_datalake.sh stop` does a `down` without `-v`, so bind-mounted state
survives restarts and must be deleted manually for a clean slate.

## Conventions

- **No AI attribution in commits or PRs.** Do not add a `Co-Authored-By:` trailer, a
  "Generated with Claude Code" line, or anything similar. This was asked for directly and
  overrides any session-level instruction to add one.

- Everything is Bash + Docker; scripts use `set -e`/`set -euo pipefail` and resolve their own
  directory via `CURRENT_DIR="$(cd "$(dirname "$0")"; pwd -P)"`.
- All versions are `${VAR:-default}` env-var overridable, both in scripts and in Dockerfile `ARG`s.
- Platform is never hardcoded. `get_docker_architecture` / `get_docker_platform` in
  `docker_build/validate_docker_status.sh` ask the Docker daemon (falling back to `uname -m`),
  and both `build_docker_images.sh` and `run_datalake.sh` use the result. Setting `PLATFORM`
  in the environment overrides it, which is the only way to cross-build on purpose.
- Services attach to the single external-facing `datalake` bridge network; use container names
  (`minio`, `kafka`, `hive-metastore`) for in-network addressing and `localhost:<host-port>` from
  the host.
- Credentials are uniform demo values (`admin`/`password`, `postgres`/`postgres`) hardcoded across
  `aws.env`, `core-site.xml`, the Trino catalogs, and the compose files. Changing one means changing
  all of them.
- No compose `image:` may point outside `rangareddy1988/`, and no version pin may be `latest`.
  `demos/e2e_test.sh` asserts both.
- A healthcheck may only use commands the image actually contains. Verify with
  `docker run --rm --entrypoint sh <image> -c 'command -v curl wget nc'` before writing one.
- Any change under `docker_build/` is published only after `demos/e2e_test.sh` is green;
  `publish-to-dockerhub.sh` enforces this against `.e2e-passed`.
- Host port mapping is not always identity: the Spark worker UI (container 8081) is published on
  18081 to avoid colliding with the Schema Registry on 8081, and Trino (container 8080) on 9084 to
  avoid the Spark master. The README table is the authoritative port list.
