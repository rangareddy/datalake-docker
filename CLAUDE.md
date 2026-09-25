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
`image_builds` array: `hive`, `spark`, `kafka-connect`, `kafka-cat`, `trino`, `jupyter-notebook`,
`xtable`, `flink`. Versions come from env vars with defaults at the top of the script
(`SPARK_VERSION`, `HIVE_VERSION`, …). The `xtable` image is by far the slowest, since it git-clones
and `mvn install`s XTable from source in a builder stage.

`IMAGES` limits the run to a subset, which is the fast path after editing one Dockerfile:

```sh
IMAGES=spark SPARK_VERSION=4.1.3 ./docker_build/build_docker_images.sh
IMAGES=spark,trino ./docker_build/build_docker_images.sh
```

### The Spark version matrix

`SPARK_VERSION` selects a profile and everything else is derived from it, because the Spark line
dictates the Scala binary, the bundled Hadoop, and which builds of the three formats exist:

| `SPARK_VERSION` | Scala | Hadoop | Hudi | Iceberg | Delta |
| --- | --- | --- | --- | --- | --- |
| `3.5.9` (default) | 2.12 | 3.3.4 | 1.1.1 | 1.11.0 | 3.3.2 |
| `4.1.3` | 2.13 | 3.4.2 | — | 1.11.0 | — |

Those are the only two lines; anything else exits with an error rather than being built
against a guessed Scala binary.

Any of the derived values can still be overridden individually, but the defaults are chosen so
the three connectors agree. Two constraints are worth keeping in mind before changing them:

- **The Spark 4.1 image is Iceberg-only, and this was measured.** `hudi-spark4.1-bundle` 1.2.0
  dies with `NoClassDefFoundError org/apache/parquet/variant/VariantConverters` because Spark
  4.1.3 ships Parquet 1.16.0 without that class while the bundle is built against 1.15.x;
  Delta 4.0.0 dies with `NoSuchMethodError org.apache.spark.internal.LogKey.$init$` and has no
  Scala 2.13 build past 4.0.0. `Dockerfile.spark` skips a format whose version arg is empty,
  which is how the profile is expressed, and the smoke test reports those as skipped rather
  than failed. Use 3.5.9 when all three formats are needed.
- **S3A changes SDK between the profiles.** Hadoop 3.3.x uses AWS SDK v1
  (`com.amazonaws:aws-java-sdk-bundle`), Hadoop 3.4.x uses SDK v2 (`software.amazon.awssdk:bundle`).
  `download_hadoop_aws_jars` caches per Hadoop version under `.s3-jar-cache/<version>/` and then
  stages a clean `hadoop-s3-jars/`, because `Dockerfile.spark` COPYs that directory wholesale and a
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
  -f Dockerfile.spark . -t rangareddy1988/ranga-spark:3.5.9
```

## Architecture

**Storage plane.** MinIO is the S3 endpoint (`http://minio:9000`, `admin`/`password`). The `mc`
sidecar creates the `warehouse` and `datalake` buckets on startup and then idles. `core-site.xml`
(baked into the Spark and Flink images) sets `fs.defaultFS=s3a://warehouse/` with static
credentials, so bare paths in Spark resolve to MinIO.

Both `s3a://` and `s3://` work everywhere, and the two are interchangeable against the same object:
a table written through one scheme reads back through the other. `s3://` is mapped onto
`S3AFileSystem` via `fs.s3.impl` (plus `fs.AbstractFileSystem.s3.impl` for FileContext callers) in
both `conf/hadoop/core-site.xml` and `conf/hive/hive-site.xml`. Credentials are **not** duplicated
per scheme: `S3AFileSystem` always reads the `fs.s3a.*` keys whichever scheme the URI used, so a
`fs.s3.access.key` would be dead config. Trino needs nothing here, since its native S3 filesystem
handles both schemes on its own. Only the Hadoop-based engines require the mapping.

Anything that talks to MinIO through Hadoop needs `core-site.xml` on its classpath. Only the Spark
and Flink images ship it; Hive carries the same settings inside `hive-site.xml`.

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
together.

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

### The Flink image's lib/ is classpath-fragile

Flink puts **every** jar in `/opt/flink/lib` on the classpath in sorted order, so a jar that
duplicates a class from the Hudi bundle and sorts before `hudi-*` silently wins. Two such jars were
being shipped, and each broke the Hudi connector with a different `NoSuchMethodError`:

- `flink-sql-parquet` — its `org.apache.parquet.avro.AvroSchemaConverter` is compiled against
  Flink's shaded Avro; Hudi calls the same class with its own shaded Avro `Schema`.
- a raw `hive-exec` jar — bundles Parquet 1.10 (no `LogicalTypeAnnotation`), shadowing the Hudi
  bundle's Parquet 1.13. `flink-sql-connector-hive` is already an uber jar with a relocated
  `hive-exec`, so the raw one is pure duplication.

Neither is needed by Delta or Iceberg. Before adding any jar to `download_flink_jars.sh`, check
whether it duplicates a class the Hudi bundle already relocates.

The worst instance of this is **Hudi 1.2.0 vs Iceberg**, which is why Hudi is pinned to 1.1.1
rather than the newest release. Hudi 1.2.0 relocated its codahale metrics to
`org.apache.hudi.com.codahale.metrics.*` but kept shipping `org.apache.flink.dropwizard.metrics.*`
under the original package name, so its wrapper's constructor signature no longer matches the one
Iceberg's copy expects. Whichever jar loses the sort order fails its INSERT with
`NoSuchMethodError` on `DropwizardHistogramWrapper` / `DropwizardMeterWrapper`. This cannot be
worked around by passing one bundle via `sql-client -j`, because `org.apache.flink.` is a
**parent-first** package, so the `lib/` copy always wins. Hudi 1.1.1 does not relocate codahale and
coexists with Iceberg. If you bump Hudi past 1.1.1, verify the Flink Iceberg sample still writes
data, and check the job state in the REST API rather than trusting `sql-client`'s exit output: the
client submits asynchronously and reports success for a job that later fails.

`docker_build/lib/` is gitignored and persists between runs, so jars accumulate — three
`hudi-flink1.17-bundle-*` jars had piled up, and a Flink version bump leaves the whole previous
connector set behind. `download_flink_jars.sh` now prunes anything outside the expected set for the
current run, and `Dockerfile.flink` no longer wgets a second Hudi bundle on top of the staged one;
keep `HUDI_VERSION` aligned between those two files.

Two more Flink facts that cost real debugging time:

- **Hudi on s3a needs an explicit lock provider.** The default `FileSystemBasedLockProvider` throws
  `Unsupported scheme :s3a, since this fs can not support atomic creation`, and that failure kills
  the JobMaster and the cluster entrypoint — not just the job.
- **Delta reads its Hadoop config from `HADOOP_CONF_DIR` only.** Hudi and Iceberg find the MinIO
  credentials because their catalogs set `hive-conf-dir=/opt/flink/conf`; Delta doesn't, so without
  `core-site.xml` on `$HADOOP_HOME/etc/hadoop` it falls back to the default AWS chain and fails with
  S3 403. `delta-standalone` also needs `shapeless` at runtime, which nothing pulls in transitively.

The sample scripts land flat in `/opt/flink/conf/` (Docker `COPY` of `conf/flink/*` flattens the
`sql/` dir), and run with
`docker exec jobmanager /opt/flink/bin/sql-client.sh -f /opt/flink/conf/hudi-flink.sql`. A leading
`SET` must be the file's first statement — Flink fails to recognise it if comment lines precede it.
From Hudi 1.2.0 on, the Hudi DDL also requires an explicit `PRIMARY KEY (...) NOT ENFORCED`.

Flink config lives in `conf/flink/config.yaml` in **nested** YAML. Flink 1.19 replaced the flat
`flink-conf.yaml` and 1.20 no longer reads it at all, so a flat `rest.port: 8084` line is silently
ignored, leaving REST on the default 8081 and breaking both the port mapping and the healthcheck.
The compose `FLINK_PROPERTIES` env still works: the image entrypoint feeds it through
`config-parser-utils.sh` as `-Dkey=value`, which merges correctly into the nested file.

### Local-path gotcha in the Hudi/Flink scripts

`download_and_build_hudi.sh` and `download_flink_jars.sh` both branch on whether `whoami` contains
`ranga` and, if so, use `$HOME/ranga_work/apache/hudi` as the Hudi checkout instead of a local
clone. `download_and_build_hudi.sh` is not called by `build_docker_images.sh` (the line is commented
out); it exists to build Hudi from source and stage the bundle jars for the Flink image.

## Conventions

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
- Host port mapping is not always identity: the Spark worker UI (container 8081) is published on
  18081 to avoid colliding with the Schema Registry on 8081, and Trino (container 8080) on 9084 to
  avoid the Spark master. The README table is the authoritative port list.
