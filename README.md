# Datalake Playground Docker

A local lakehouse you can run on one machine. It wires Postgres and MySQL through Debezium
and Kafka into Apache Hudi, Apache Iceberg and Delta Lake tables stored on MinIO, catalogued
in a shared Hive Metastore, and queryable from Spark and Trino.

Everything is Docker images plus a Compose stack. There is no application code to build.

## Contents

- [Prerequisites](#prerequisites)
- [Setup, step by step](#setup-step-by-step)
  - [Step 1: Check your machine](#step-1-check-your-machine)
  - [Step 2: Build the images](#step-2-build-the-images)
  - [Step 3: Start the stack](#step-3-start-the-stack)
  - [Step 4: Verify every service](#step-4-verify-every-service)
  - [Step 5: Create your first table](#step-5-create-your-first-table)
- [Where the images come from](#where-the-images-come-from)
- [Architecture](#architecture)
- [Components and ports](#components-and-ports)
- [Versions](#versions)
- [Working with the table formats](#working-with-the-table-formats)
- [S3 paths: `s3a://` and `s3://`](#s3-paths-s3a-and-s3)
- [CDC walkthrough: Postgres to Hudi to Trino](#cdc-walkthrough-postgres-to-hudi-to-trino)
- [Multi table CDC](#multi-table-cdc)
- [Day to day operations](#day-to-day-operations)
- [Changing a Dockerfile](#changing-a-dockerfile)
- [Troubleshooting](#troubleshooting)
- [Repository layout](#repository-layout)

## Prerequisites

| Requirement | Detail |
| ----------- | ------ |
| Docker      | With Compose v2 (`docker compose`). The v1 `docker-compose` binary also works |
| Disk        | About 19 GB. The 12 images total roughly 16 GB, and the build inputs another 1.5 GB |
| Memory      | 8 GB for the `core` profile (14 containers), 10 GB for `all` (16). Most are JVMs. Too little shows up as the daemon thrashing — health checks that should take a second take minutes, and the kernel OOM-kills whichever JVM is largest — which looks like broken services rather than a memory problem |
| Network     | The first build downloads the Spark and Hadoop tarballs plus about 40 jars from Maven Central |
| Free ports  | 2181, 3306, 5432, 7077, 8080-8083, 8888, 9000-9001, 9082, 9084, 9092, 9101, 10000, 10002, 14040-14042, 18080-18081, 29092 |

The platform is detected from the Docker daemon, so images build and run natively on both
Apple Silicon and Intel with nothing to configure. Set `PLATFORM=linux/amd64` in the
environment only if you deliberately want a cross-platform build.

## Setup, step by step

### Step 1: Check your machine

```sh
docker --version
docker compose version
docker info --format 'Docker memory: {{.MemTotal}} bytes'
df -h .
```

Docker must be running before anything else. The build script checks this and stops early
with a clear message if the daemon is unreachable.

### Step 2: Build the images

The `rangareddy1988/ranga-*` images are built locally. The script first downloads the
prerequisites that the Dockerfiles `COPY` in, so it must run before the first start:

```sh
./docker_build/build_docker_images.sh
```

What it does, in order:

1. Downloads the Hadoop and Spark tarballs into `docker_build/software`.
2. Downloads the S3 jars into `docker_build/hadoop-s3-jars` and the JDBC drivers into
   `docker_build/db_connector_jars`.
3. Builds every entry in the `image_builds` array: the third-party wrappers
   (`kafka`, `kafka-schema-registry`, `kafka-rest`, `kafka-ui`, `postgres`, `minio`,
   `mysql`) and then the images this repo assembles (`hive`, `spark`, `kafka-connect`,
   `trino`). See [Where the images come from](#where-the-images-come-from)
   for why the first group exists.

Each image prints a line on success:

```
Successfully built spark:1.0.0 (SPARK_VERSION=3.5.9)
```

The tag is the stack version; the value in brackets is what went into it. The Spark
image dominates the total on a cold cache — it downloads the distribution plus about
forty jars.

#### Building only part of it

`IMAGES` limits the run, which is the fast path after editing one Dockerfile. Downloads are
gated on the selection, so a wrapper-only run does not fetch the Spark and Hadoop tarballs:

```sh
IMAGES=upstream ./docker_build/build_docker_images.sh   # the ten wrappers; seconds, not minutes
IMAGES=engines  ./docker_build/build_docker_images.sh   # spark, hive, connect, trino
IMAGES=core     ./docker_build/build_docker_images.sh   # everything docker-compose.yml starts
IMAGES=spark,hive ./docker_build/build_docker_images.sh # or name images individually
```

#### Choosing a Spark line

The build supports two profiles, selected by `SPARK_VERSION`. Everything else follows from
it, because the Spark line dictates the Scala binary, the bundled Hadoop, and which builds
of Hudi, Iceberg and Delta exist:

Each line has its own Dockerfile and its own image. The Spark 3 image keeps the original
name so existing pulls and compose files carry on working; only the new line is prefixed.

| `SPARK_VERSION` | Dockerfile | Image | Scala | Hadoop | Hudi  | Iceberg | Delta |
| --------------- | ---------- | ----- | ----- | ------ | ----- | ------- | ----- |
| `3.5.9` (default) | `Dockerfile.spark3` | `ranga-spark` | 2.12 | 3.3.4 | 1.1.1 | 1.11.0 | 3.3.2 |
| `4.1.3`           | `Dockerfile.spark4` | `ranga-spark4` | 2.13 | 3.4.2 | — | 1.11.0 | — |

`run_datalake.sh` picks the matching image from `SPARK_VERSION`, so switching lines is one
variable and never an edit to the compose files:

```sh
SPARK_VERSION=3.5.9 sh docker_run/run_datalake.sh restart   # ranga-spark
SPARK_VERSION=4.1.3 sh docker_run/run_datalake.sh restart   # ranga-spark4
```

`IMAGES=spark` builds whichever line `SPARK_VERSION` selects, and `IMAGES=spark4` names
the Spark 4 image directly.

Any other Spark line is refused rather than built against a guessed Scala binary.

**The Spark 4.1 image ships Iceberg only.** Neither Hudi nor Delta has a build that runs
on Spark 4.1 yet, and both failures were confirmed by running them rather than inferred
from a version table:

- **Hudi 1.2.0** — `NoClassDefFoundError: org/apache/parquet/variant/VariantConverters`.
  Spark 4.1.3 ships Parquet 1.16.0, which dropped that class; `hudi-spark4.1-bundle` is
  built against 1.15.x and bundles parquet classes that still reference it.
- **Delta 4.0.0** — `NoSuchMethodError: org.apache.spark.internal.LogKey.$init$`. Spark
  4.1 changed an internal trait Delta 4.0.0 was compiled against, and Delta publishes no
  Scala 2.13 build past 4.0.0.

Rather than shipping jars that fail on the first statement, the image leaves them out and
`demos/smoke_test_formats.sh` reports them as skipped. Use the **3.5.9** profile when you
need all three formats. When Hudi and Delta publish Spark 4.1 builds, filling in the two
versions in `build_docker_images.sh` is the whole change.

```sh
SPARK_VERSION=4.1.3 ./docker_build/build_docker_images.sh
```

Then pin the same version for the stack, so Compose resolves the tag that was built:

```sh
SPARK_VERSION=4.1.3 sh docker_run/run_datalake.sh restart
```



Note the S3A dependency changes with the profile: Hadoop 3.3.x uses AWS SDK v1
(`aws-java-sdk-bundle`) and Hadoop 3.4.x uses SDK v2 (`software.amazon.awssdk:bundle`). The
build script downloads the right one and stages a clean `hadoop-s3-jars/` for the image, so
switching profiles does not leave the previous SDK behind on the classpath.

To build only some images, which is much faster than the full set:

```sh
IMAGES=spark SPARK_VERSION=4.1.3 ./docker_build/build_docker_images.sh
IMAGES=spark,trino ./docker_build/build_docker_images.sh
```

To rebuild one image only, for example after editing a config file:

```sh
cd docker_build
docker build --build-arg SPARK_VERSION=3.5.9 \
  --platform "$(source ./validate_docker_status.sh >/dev/null 2>&1; get_docker_platform)" \
  -f "$PWD/Dockerfile.spark3" "$PWD" \
  -t rangareddy1988/ranga-spark:3.5.9 -t rangareddy1988/ranga-spark:latest
```

### Step 3: Start the stack

```sh
sh docker_run/run_datalake.sh
```

The script takes `start` (the default), `stop`, `restart`, `status`, `logs [service...]`
and `validate`. It validates the compose file before starting, so a broken edit fails fast
instead of half starting the stack.

There are two profiles:

| Profile | Compose file | Services |
| ------- | ------------ | -------- |
| `core` (default) | `docker-compose.yml` | Kafka stack, Hive, Spark, Postgres, MinIO |
| `all` | `docker-compose_all.yml` | Everything in `core` plus MySQL, Trino and Jupyter |

To bring up the full stack, which you need for the Trino section below:

```sh
PROFILE=all sh docker_run/run_datalake.sh start
```

Startup is ordered by health checks, so services wait for their dependencies. Expect the
first start to take a couple of minutes while Hive initialises its metastore schema.

### Step 4: Verify every service

One command checks all of it:

```sh
./demos/e2e_test.sh
```

It does not probe ports. Every check is a real operation — a Kafka message produced and
consumed back, a Debezium connector created and its snapshot row read off the topic, a
Spark job submitted to the cluster, a table written and read in each format the image
ships, a Hive query through the shared metastore, an object round-tripped through MinIO.
Each line is `PASS`, `FAIL` or `SKIP`, and the exit status is non-zero if anything failed:

```
== kafka
  PASS  kafka:zookeeper-ruok               imok
  PASS  kafka:broker-api                   e2e-e2e
  PASS  kafka:produce-consume              e2e-message
  PASS  kafka:broker-metadata              kafka:29092 (id: 1 rack: null)

== spark
  PASS  spark:master-ui                    Spark Master at spark://spark-master:7077
  PASS  spark:worker-registered            ALIVE
  PASS  spark:submit-job                   Pi is roughly 3.14
  PASS  spark:s3a-write                    e2e-s3a

== summary
  passed 45   failed 0   skipped 0

  Stack is end-to-end green; images are safe to publish.
  Recorded 26 image IDs in .e2e-passed
```

Verified green on all three combinations:

| Profile | Spark line | Checks |
| ------- | ---------- | ------ |
| `core` | 3.5.9 | 45 passed, 0 failed |
| `core` | 4.1.3 | 45 passed, 0 failed, 2 skipped (Hudi and Delta, which that line does not ship) |
| `all` | 3.5.9 | 55 passed, 0 failed |

Useful variants:

```sh
PROFILE=all ./demos/e2e_test.sh      # also Trino, Jupyter and MySQL
./demos/e2e_test.sh kafka spark      # only checks whose names start with these
SKIP_FORMATS=1 ./demos/e2e_test.sh   # skip the slow Hudi/Iceberg/Delta table writes
```

If you would rather look at the containers directly:

```sh
sh docker_run/run_datalake.sh status
```

Every row should read `Up ... (healthy)`, except `mc`, which has no health check defined, and `kafka-init-topics`, which creates the demo topic and exits 0:

```
NAME             IMAGE                                       SERVICE          STATUS
hive-metastore   rangareddy1988/ranga-hive:4.0.0             hive-metastore   Up 3 minutes (healthy)
kafka            rangareddy1988/ranga-kafka:7.4.7            kafka            Up 3 minutes (healthy)
minio            rangareddy1988/ranga-minio:RELEASE.2025-...  minio           Up 3 minutes (healthy)
```

A container being `Up` still does not mean the service inside is serving — the custom
images end their entrypoint with a keepalive loop — which is exactly why `e2e_test.sh`
exercises the services rather than reading this table.

### Step 5: Create your first table

This writes a Hudi table to MinIO, registers it in the shared metastore, and reads it back
from a different engine. If this works, the whole stack is wired correctly.

Open a shell on the Spark master:

```sh
docker exec -it spark-master bash
```

Start Spark SQL with the Hudi bundle:

```sh
spark-sql --jars $(ls $HUDI_HOME/hudi-spark*-bundle_*.jar) \
  --conf spark.serializer=org.apache.spark.serializer.KryoSerializer \
  --conf spark.sql.catalog.spark_catalog=org.apache.spark.sql.hudi.catalog.HoodieCatalog \
  --conf spark.sql.extensions=org.apache.spark.sql.hudi.HoodieSparkSessionExtension \
  --conf spark.kryo.registrator=org.apache.spark.HoodieSparkKryoRegistrar
```

Create and populate a table:

```sql
CREATE TABLE employees_hudi (id INT, name STRING, department STRING, ts LONG)
USING hudi
TBLPROPERTIES (primaryKey = 'id', preCombineField = 'ts')
LOCATION 's3a://warehouse/employees_hudi';

INSERT INTO employees_hudi VALUES (1, 'Ranga', 'Sales', 1), (2, 'Nishanth', 'Software', 2);
UPDATE employees_hudi SET department = 'Analytics' WHERE id = 1;
SELECT id, name, department FROM employees_hudi ORDER BY id;
```

```
1	Ranga	Analytics
2	Nishanth	Software
```

Leave the shell with `quit;`. Confirm the files really landed on MinIO:

```sh
docker exec mc /usr/bin/mc ls -r minio/warehouse/employees_hudi | head -3
```

Now read the same table from Trino, which proves the metastore is shared:

```sh
docker exec -it trino trino --execute "SELECT id, name, department FROM hudi.default.employees_hudi ORDER BY id"
```

```
"1","Ranga","Analytics"
"2","Nishanth","Software"
```

Clean up when you are done. Drop the table from the metastore, then delete the objects:

```sh
docker exec hive-server beeline -u jdbc:hive2://localhost:10000 -n hive --silent=true \
  -e "DROP TABLE IF EXISTS employees_hudi;"
docker exec mc /usr/bin/mc rm --force --recursive minio/warehouse/employees_hudi
```

## Where the images come from

Every image this stack starts is `rangareddy1988/ranga-*`, built from a Dockerfile in
`docker_build/`. Nothing is pulled from Confluent, Provectus, dbeaver, quay.io or the
Postgres and MySQL libraries at run time.

Ten of those images are thin wrappers whose only job is to pin an upstream base and re-tag
it under a name this repo controls:

| Image | Base it pins | Adds |
| ----- | ------------ | ---- |
| `ranga-kafka` | `confluentinc/cp-kafka:7.4.7` | a ZooKeeper config, so one image serves both roles |
| `ranga-kafka-schema-registry` | `confluentinc/cp-schema-registry:7.4.7` | nothing |
| `ranga-kafka-rest` | `confluentinc/cp-kafka-rest:7.4.7` | nothing |
| `ranga-kafka-ui` | `provectuslabs/kafka-ui:v0.7.2` | nothing |
| `ranga-postgres` | `postgres:16.4` | `wal_level=logical` as the default command |
| `ranga-minio` | `quay.io/minio/minio` **by digest** | a real `HEALTHCHECK` |
| `ranga-mysql` | `ubuntu/mysql:8.0-20.04_edge` | nothing |

A wrapper that adds nothing is exactly the size of its base, so this costs no disk.

### One image, several services

Three services do not have an image of their own, because the image they would need
already exists:

| Service | Runs from | Why |
| ------- | --------- | --- |
| `zookeeper` | `ranga-kafka` | `cp-kafka` already ships `zookeeper-server-start` and the ZooKeeper jars. A separate `cp-zookeeper` was 825MB of the same contents. It needs an entrypoint override because `cp-kafka` carries no ZooKeeper properties template, so `ranga-kafka` bakes one at `/etc/kafka/zookeeper.properties` |
| `mc` | `ranga-minio` | The MinIO server image already contains the `mc` client at `/usr/bin/mc` |
| `jupyter-notebook` | `ranga-spark` | The Spark image already installs JupyterLab and the Python, Scala (spylon) and Java (IJava) kernels. A separate 3.2GB jupyter image duplicated all of it — and a notebook next to Spark can actually use Spark, which the standalone one could not. It starts with `SPARK_MODE=notebook` |

There is no `kcat` container either. `cp-kafkacat` was an 839MB image for a CLI whose
job — inspect topics and broker metadata from inside the network — the broker image
already does with `kafka-topics`, `kafka-console-consumer` and
`kafka-broker-api-versions`:

```sh
docker exec kafka kafka-broker-api-versions --bootstrap-server kafka:29092
docker exec kafka kafka-topics --bootstrap-server kafka:29092 --list
```

Altogether that is about 5.6GB of duplicated content not built, not pulled and not
stored.

### Why bother

Three upstream changes have already broken this stack:

- **`docker.io/minio/minio` stopped resolving** (`pull access denied`). Every `start` failed
  until both compose files were repointed at quay.io.
- **Confluent Hub dropped Debezium 2.4.2.** The pinned build stopped existing and
  `kafka-connect` failed with `Component not found`.
- **`provectuslabs/kafka-ui` was discontinued** at v0.7.2 (April 2024). Its `:latest` is a
  tag nobody maintains, and the project moved to a different image name entirely.

With a wrapper in front, each of those is a one-line edit here plus a rebuild. Without one,
it is a stack that stops starting for everyone who pulls.

Two details worth knowing:

- **No pin is `latest`.** `docker_run/.env` and the defaults in `build_docker_images.sh` are
  exact versions and must agree, because Compose resolves the tag the build produced.
- **MinIO is pinned by digest rather than tag.** quay.io serves only `:latest` anonymously —
  every `RELEASE.*` tag answers `401 unauthorized` — so a tag pin is not available and
  `:latest` is a moving target. The digest is immutable, still pullable without credentials,
  and covers both architectures. To move it forward:

  ```sh
  docker pull quay.io/minio/minio:latest
  docker inspect quay.io/minio/minio:latest --format '{{index .RepoDigests 0}}'
  ```

  then paste the `sha256:...` into `docker_build/Dockerfile.minio`.

## Architecture

```
Postgres / MySQL
      |  Debezium source connector
      v
   Kafka  +  Schema Registry (Avro)
      |
      |  Hudi Streamer on Spark, or the Hudi Kafka Connect sink
      v
   MinIO (S3)  s3a://warehouse
      |
      |  table metadata
      v
 Hive Metastore  <---- shared catalog ---->  Spark | Trino
```

Three planes are worth understanding:

**Storage.** MinIO is the S3 endpoint at `http://minio:9000`. The `mc` sidecar creates the
`warehouse` and `datalake` buckets on startup, then idles. `core-site.xml` is baked into the
Spark image and sets `fs.defaultFS` to `s3a://warehouse/`.

**Catalog.** One Hive Metastore at `thrift://hive-metastore:9083`, backed by Postgres, is the
shared catalog for Spark and Trino. Anything written with metadata sync enabled becomes
queryable from the other engines without extra registration.

**Ingestion.** Two independent routes land CDC data in Hudi: the Hudi Streamer submitted to
Spark, and the Hudi Kafka Connect sink running inside the `kafka-connect` container. Both are
driven interactively with `docker exec`.

## Components and ports

Rows marked `all` exist only in the `all` profile.

| Component              | URL / port             | Profile | Notes                                         |
| ---------------------- | ---------------------- | ------- | --------------------------------------------- |
| Zookeeper              | localhost:2181         | core    | Runs from the `ranga-kafka` image              |
| Kafka broker           | localhost:9092         | core    | In-network listener is `kafka:29092`          |
| Kafka JMX              | localhost:9101         | core    |                                               |
| Schema Registry        | http://localhost:8081  | core    |                                               |
| Kafka REST Proxy       | http://localhost:8082  | core    |                                               |
| Kafka Connect REST     | http://localhost:8083  | core    |                                               |
| Kafka UI               | http://localhost:9082  | core    |                                               |
| Hive Metastore (thrift)| localhost:9083         | core    |                                               |
| HiveServer2            | localhost:10000        | core    | Web UI at http://localhost:10002              |
| Spark master UI        | http://localhost:8080  | core    | Submit to `spark://spark-master:7077`         |
| Spark worker UI        | http://localhost:18081 | core    | Container port 8081                           |
| Spark History Server   | http://localhost:18080 | core    |                                               |
| Spark application UI   | http://localhost:14040 | core    | Container 4040-4042 mapped to 14040-14042     |
| MinIO API              | http://localhost:9000  | core    | Buckets `warehouse` and `datalake`            |
| MinIO console          | http://localhost:9001  | core    | `admin` / `password`                          |
| Postgres               | localhost:5432         | core    | `postgres` / `postgres`                       |
| MySQL                  | localhost:3306         | all     | `admin` / `password`                          |
| Trino                  | http://localhost:9084  | all     | Container port 8080                           |
| Jupyter Lab            | http://localhost:8888  | all     | Token disabled. Runs from the Spark image      |

Host ports are not always the same as container ports. The Spark worker UI and Trino are
remapped to avoid colliding with the Schema Registry on 8081 and the Spark master on 8080.

All credentials are uniform demo values and are hardcoded across `aws.env`, `core-site.xml`,
the Trino catalog files and the compose files. Changing one means changing all of them.

## Versions

### One version for the whole stack

Every image carries the same tag, and it is the version of the **stack**, not of the
component inside it:

```
rangareddy1988/ranga-spark:1.0.0
rangareddy1988/ranga-kafka:1.0.0
rangareddy1988/ranga-hive:1.0.0
```

So `docker_run/.env` needs exactly one pin, `IMAGE_VERSION=1.0.0`, and there is no way
for a compose file to ask for a tag that was never built because one component moved.

Upgrading a component — Spark 3.5.9 to 3.5.10, say — does not produce
`ranga-spark:3.5.10`. It produces a different `1.0.0`, and the table below is what
records the change. When a migration is worth announcing, `IMAGE_VERSION` moves to
`1.1.0` in both `.env` and `docker_build/build_docker_images.sh`, and this table moves
with it.

### What 1.0.0 is made of

The table below is the default (Spark 3.5) profile. See
[Choosing a Spark line](#choosing-a-spark-line) for the Spark 4.1 set, and
[Where the images come from](#where-the-images-come-from) for the third-party pins.

This is the whole tech stack behind `1.0.0`. It is the same list as the defaults at the
top of `docker_build/build_docker_images.sh`; the two move together, and neither moves
without a green `./demos/e2e_test.sh`.

**Engines and table formats** (Spark 3.5 profile; `SPARK_VERSION=4.1.3` switches to the
Scala 2.13, Iceberg-only set):

| Component | Version         | Why this one |
| --------- | --------------- | ------------ |
| Spark     | 3.5.9 on JDK 17 | Default profile. JDK 17 is required because Iceberg 1.11.0 is compiled for Java 17 |
| Scala     | 2.12            | Follows the Spark line. 4.1.3 is Scala 2.13 |
| Hadoop    | 3.3.4           | Follows the Spark line, and decides which AWS SDK S3A needs. 4.1.3 is Hadoop 3.4.2 |
| Hive      | 4.0.0           | Metastore and HiveServer2, both from the same image |
| Trino     | 483             | Latest release. Trino 460 could not read Hudi 1.x tables at all |
| Hudi      | 1.1.1           | Spark 3.5 profile only; no Spark 4.1 build runs yet |
| Iceberg   | 1.11.0          | Latest. Needs Java 17, which is why the Spark images install JDK 17 |
| Delta     | 3.3.2           | Ceiling for Scala 2.12. There is no build that runs on Spark 4.1, so that profile ships Iceberg alone |

**Platform services**, each rebuilt under `rangareddy1988/ranga-*`:

| Component | Version | Notes |
| --------- | ------- | ----- |
| Kafka, Schema Registry, REST Proxy | Confluent 7.4.7 | The broker image also serves ZooKeeper |
| Kafka Connect | Confluent 7.4.7 + Debezium 2.5.4 | Debezium 3.x is Java 17 and this base runs Java 11 |
| Kafka UI | provectuslabs v0.7.2 | The last build before the project was discontinued |
| PostgreSQL | 16.4 | Metastore backing store, Connect offsets, and the CDC source |
| MySQL | ubuntu/mysql 8.0 | `all` profile only; the second CDC source |
| MinIO | RELEASE.2025-09-07 | Pinned by digest, not tag — see [Where the images come from](#where-the-images-come-from) |
| JupyterLab | from the Spark image | Python, Scala (spylon) and Java (IJava) kernels |

Hudi stays on one version across Spark, Hive and Kafka Connect, because all of them read
and write the same tables through the shared metastore.

Hudi is held at 1.1.1 because that is the version this stack is tested on, not because 1.2.0
is known bad here. The original reason for the pin was a Flink classpath conflict — 1.2.0
relocated its codahale metrics while still exporting `org.apache.flink.dropwizard.metrics.*`
under the original package name, which made the Hudi and Iceberg Flink connectors mutually
exclusive — and Flink is no longer part of this stack. Moving to 1.2.0 is therefore a
reasonable thing to try; it is a change to `HUDI_VERSION` in
`docker_build/build_docker_images.sh` followed by a green `./demos/e2e_test.sh`.

## Working with the table formats

Open a shell on the Spark master first:

```sh
docker exec -it spark-master bash
```

The image ships the format jars under `$HUDI_HOME`, `$ICEBERG_HOME` and `$DELTA_HOME`, so
the commands below resolve them with `ls` rather than hardcoding versions.

### Hudi

```sh
spark-sql --jars $(ls $HUDI_HOME/hudi-spark*-bundle_*.jar) \
  --conf spark.serializer=org.apache.spark.serializer.KryoSerializer \
  --conf spark.sql.catalog.spark_catalog=org.apache.spark.sql.hudi.catalog.HoodieCatalog \
  --conf spark.sql.extensions=org.apache.spark.sql.hudi.HoodieSparkSessionExtension \
  --conf spark.kryo.registrator=org.apache.spark.HoodieSparkKryoRegistrar
```

```sql
CREATE TABLE employees_hudi (id INT, name STRING, department STRING, ts LONG)
USING hudi
TBLPROPERTIES (primaryKey = 'id', preCombineField = 'ts')
LOCATION 's3a://warehouse/employees_hudi';

INSERT INTO employees_hudi VALUES (1, 'Ranga', 'Sales', 1), (2, 'Nishanth', 'Software', 2);
UPDATE employees_hudi SET department = 'Analytics' WHERE id = 1;
SELECT id, name, department FROM employees_hudi ORDER BY id;
```

`primaryKey` and `preCombineField` are required for a Hudi table. The default table type is
`COPY_ON_WRITE`. Add `type = 'mor'` to `TBLPROPERTIES` for `MERGE_ON_READ`.

### Iceberg

The Iceberg catalog is declared on the command line rather than replacing `spark_catalog`,
so tables are addressed as `ice.<database>.<table>`:

```sh
spark-sql --jars $(ls $ICEBERG_HOME/*.jar) \
  --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions \
  --conf spark.sql.catalog.ice=org.apache.iceberg.spark.SparkCatalog \
  --conf spark.sql.catalog.ice.type=hive \
  --conf spark.sql.catalog.ice.uri=thrift://hive-metastore:9083 \
  --conf spark.sql.catalog.ice.warehouse=s3a://warehouse/ice
```

```sql
CREATE DATABASE IF NOT EXISTS ice.sales;
CREATE TABLE ice.sales.employees_iceberg (id INT, name STRING, department STRING) USING iceberg;
INSERT INTO ice.sales.employees_iceberg VALUES (1, 'Ranga', 'Sales'), (2, 'Nishanth', 'Software');
UPDATE ice.sales.employees_iceberg SET department = 'Analytics' WHERE id = 1;
SELECT id, name, department FROM ice.sales.employees_iceberg ORDER BY id;
```

### Delta

`delta-spark` needs `delta-storage` alongside it, so pass the whole directory:

```sh
spark-sql --jars $(ls $DELTA_HOME/*.jar | tr '\n' ',' | sed 's/,$//') \
  --conf spark.sql.extensions=io.delta.sql.DeltaSparkSessionExtension \
  --conf spark.sql.catalog.spark_catalog=org.apache.spark.sql.delta.catalog.DeltaCatalog
```

```sql
CREATE TABLE employees_delta (id INT, name STRING, department STRING)
USING delta LOCATION 's3a://warehouse/employees_delta';

INSERT INTO employees_delta VALUES (1, 'Ranga', 'Sales'), (2, 'Nishanth', 'Software');
UPDATE employees_delta SET department = 'Analytics' WHERE id = 1;
SELECT id, name, department FROM employees_delta ORDER BY id;
```

### Trino

Trino carries a catalog per format, all pointing at the same metastore:

```sh
docker exec -it trino trino
```

```sql
SHOW CATALOGS;   -- delta, hive, hudi, iceberg, memory and postgres, plus Trino's built-ins
SHOW SCHEMAS FROM hudi;
SELECT * FROM hudi.default.employees_hudi;
SELECT * FROM iceberg.sales.employees_iceberg;
SELECT * FROM delta.default.employees_delta;
```

Trino also reads Postgres directly through the `postgres` catalog, which is handy for
comparing CDC output against the source rows:

```sql
SELECT * FROM postgres.public.employees;
```

## S3 paths: `s3a://` and `s3://`

Both schemes address the same MinIO buckets and are interchangeable. A table written through
one reads back through the other:

```sql
CREATE TABLE t1 (id INT, name STRING) USING parquet LOCATION 's3a://warehouse/t1';
CREATE TABLE t2 (id INT, name STRING) USING parquet LOCATION 's3://warehouse/t2';
```

`s3://` is mapped onto `S3AFileSystem` in `docker_build/conf/hadoop/core-site.xml` and
`docker_build/conf/hive/hive-site.xml`. Credentials live only under the `fs.s3a.*` keys.
`S3AFileSystem` reads those whichever scheme the URI used, so they are not duplicated per
scheme. Trino needs no configuration here, since its native S3 support handles both.

## CDC walkthrough: Postgres to Hudi to Trino

This moves rows from `public.employees` in Postgres into a Hudi table on MinIO, registers it
in the metastore and queries it from Trino.

### Step 1: Look at the source data

```sh
docker exec postgres psql -U postgres -c "SELECT * FROM public.employees;"
```

The table is seeded by `docker_run/db_scripts/postgres/employees.sql` with two rows. It is
declared `REPLICA IDENTITY FULL`, which is what lets Debezium emit complete before-images on
updates and deletes.

### Step 2: Register the Debezium source connector

The connector definitions are mounted into the Kafka Connect container at
`/opt/data/connector_configs`, but you can post them from the host:

```sh
curl -s -X POST -H "Content-Type:application/json" \
  http://localhost:8083/connectors/ \
  -d @docker_run/debezium_configs/streamer_connector/register_employees_pg_connector.json | jq
```

Confirm it reached `RUNNING`:

```sh
curl -s http://localhost:8083/connectors/employees_pg_connector/status | jq '.connector.state'
```

```
"RUNNING"
```

If it reports `FAILED`, read the reason with:

```sh
curl -s http://localhost:8083/connectors/employees_pg_connector/status | jq -r '.tasks[].trace' | head -20
```

### Step 3: Confirm the change events reached Kafka

```sh
docker exec kafka kafka-topics --list --bootstrap-server localhost:9092 | grep cdc
```

```
cdc.public.employees
```

The topic name is the `topic.prefix` plus the schema and table. To watch the raw events:

```sh
docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 --topic cdc.public.employees --from-beginning --max-messages 2
```

### Step 4: Write the Hudi Streamer properties

```sh
docker exec -it spark-master bash
```

These use the current `hoodie.streamer.*` prefix. The older `hoodie.deltastreamer.*` names
still resolve in Hudi 1.1.1 but are deprecated:

```sh
cat > /tmp/employees_cdc.properties <<'EOF'
bootstrap.servers=kafka:29092
auto.offset.reset=earliest
schema.registry.url=http://kafka-schema-registry:8081
hoodie.streamer.schemaprovider.registry.url=http://kafka-schema-registry:8081/subjects/cdc.public.employees-value/versions/latest
hoodie.streamer.source.kafka.value.deserializer.class=io.confluent.kafka.serializers.KafkaAvroDeserializer
hoodie.streamer.source.kafka.topic=cdc.public.employees
hoodie.datasource.write.recordkey.field=id
hoodie.datasource.write.keygenerator.class=org.apache.hudi.keygen.NonpartitionedKeyGenerator
hoodie.datasource.hive_sync.enable=true
hoodie.datasource.hive_sync.database=default
hoodie.datasource.hive_sync.table=employees_cdc
EOF
```

Hive sync mode and the metastore URI come from `hudi-defaults.conf`, baked into the image at
`/etc/hudi/conf`, so they do not need repeating here.

### Step 5: Run the Hudi Streamer

The slim utilities bundle needs the Spark bundle on `--jars`:

```sh
export SPARK_BUNDLE=$(ls $HUDI_HOME/hudi-spark*-bundle_*.jar)
export SLIM_BUNDLE=$(ls $HUDI_HOME/hudi-utilities-slim-bundle_*.jar)

spark-submit --jars $SPARK_BUNDLE \
  --conf spark.serializer=org.apache.spark.serializer.KryoSerializer \
  --class org.apache.hudi.utilities.streamer.HoodieStreamer $SLIM_BUNDLE \
  --props file:///tmp/employees_cdc.properties \
  --table-type MERGE_ON_READ \
  --op UPSERT \
  --enable-sync \
  --target-base-path s3a://warehouse/employees_cdc \
  --target-table employees_cdc \
  --source-class org.apache.hudi.utilities.sources.debezium.PostgresDebeziumSource \
  --source-ordering-field _event_lsn \
  --payload-class org.apache.hudi.common.model.debezium.PostgresDebeziumAvroPayload
```

Two things about `--enable-sync`:

- It is the flag that registers the table in the metastore. The properties alone are not
  enough.
- Sync only runs after a successful commit, so a run that finds no new Kafka messages will
  write nothing and register nothing. If the table does not appear, produce a change first
  (Step 7) and run again.

Add `--continuous --min-sync-interval-seconds 60` to keep the job running and ingest
continuously instead of exiting after one batch.

### Step 6: Read the result

From Spark:

```sh
spark-shell --jars $(ls $HUDI_HOME/hudi-spark*-bundle_*.jar) \
  --conf spark.serializer=org.apache.spark.serializer.KryoSerializer
```

```scala
spark.read.format("hudi").load("s3a://warehouse/employees_cdc").
  select("id", "name", "department").orderBy("id").show(false)
```

Because the table is `MERGE_ON_READ`, hive sync registers two views alongside the base name.
`employees_cdc_ro` reads only compacted base files, and `employees_cdc_rt` merges the log
files at query time. From Trino:

```sh
docker exec -it trino trino --execute \
  "SELECT id, name, department FROM hudi.default.employees_cdc_ro ORDER BY id"
```

```
"1","Ranga","Sales"
"2","Nishanth","Software"
```

### Step 7: Watch a change flow through

Insert a row in Postgres:

```sh
docker exec postgres psql -U postgres -c \
  "INSERT INTO public.employees VALUES (6, 'Kiran', 29, 120000, 'Analytics');"
```

Debezium publishes it within a second or two. Re-run the `spark-submit` from Step 5, then
query again and the new row is there:

```
"1","Ranga","Sales"
"2","Nishanth","Software"
"6","Kiran","Analytics"
```

### Step 8: Clean up

```sh
curl -s -X DELETE http://localhost:8083/connectors/employees_pg_connector
docker exec postgres psql -U postgres -c "SELECT pg_drop_replication_slot('debezium');"
docker exec postgres psql -U postgres -c "DELETE FROM public.employees WHERE id = 6;"
docker exec hive-server beeline -u jdbc:hive2://localhost:10000 -n hive \
  -e "DROP TABLE IF EXISTS employees_cdc; DROP TABLE IF EXISTS employees_cdc_ro; DROP TABLE IF EXISTS employees_cdc_rt;"
docker exec mc /usr/bin/mc rm --force --recursive minio/warehouse/employees_cdc
```

Dropping the replication slot matters. Deleting a connector leaves its slot behind, and an
orphaned slot makes Postgres retain WAL indefinitely.

## Multi table CDC

`HoodieMultiTableStreamer` ingests several tables in one job.

Two names to keep straight before you start. The source tables `customers` and `orders` live
in a **separate Postgres database** called `cdc_db`, created by
`docker_run/db_scripts/postgres/multi_table_data.sql`. The Hive database the job writes into
is called `cdc_test_db`, set by `hoodie.streamer.ingestion.tablesToBeIngested` in
`docker_run/hudi_streamer/hudi_multi_table_stream.properties`. They are different names.

**Step 1.** Inspect the source:

```sh
docker exec postgres psql -U postgres -d cdc_db -c "\dt"
docker exec postgres psql -U postgres -d cdc_db -c "SELECT count(*) FROM customers;"
```

**Step 2.** Register the connector:

```sh
curl -s -X POST -H "Content-Type:application/json" \
  http://localhost:8083/connectors/ \
  -d @docker_run/debezium_configs/multi_table_streamer_connector/register_customers_orders_pg_connector.json | jq
```

Both this connector and the employees one specify `slot.name: debezium`. Postgres replication
slot names are unique across the whole cluster, not per database, so registering both at once
fails with `replication slot "debezium" already exists`. Delete one before creating the
other, or edit the `slot.name` in one of the JSON files.

**Step 3.** Submit the job. `docker_run/hudi_streamer` is mounted into the Spark master at
`/opt/hudi_streamer`, so the config folder is visible to the driver:

```sh
docker exec -it spark-master bash

export SPARK_BUNDLE=$(ls $HUDI_HOME/hudi-spark*-bundle_*.jar)
export SLIM_BUNDLE=$(ls $HUDI_HOME/hudi-utilities-slim-bundle_*.jar)

spark-submit --jars $SPARK_BUNDLE \
  --conf spark.serializer=org.apache.spark.serializer.KryoSerializer \
  --conf spark.sql.hive.convertMetastoreParquet=false \
  --class org.apache.hudi.utilities.streamer.HoodieMultiTableStreamer $SLIM_BUNDLE \
  --props file:///opt/hudi_streamer/hudi_multi_table_stream.properties \
  --config-folder file:///opt/hudi_streamer/ \
  --source-class org.apache.hudi.utilities.sources.debezium.PostgresDebeziumSource \
  --payload-class org.apache.hudi.common.model.debezium.PostgresDebeziumAvroPayload \
  --base-path-prefix s3a://warehouse/multi-table/ \
  --source-ordering-field _event_origin_ts_ms \
  --table-type COPY_ON_WRITE \
  --enable-sync \
  --op UPSERT
```

**Step 4.** Query the result from Trino:

```sql
USE hudi.cdc_test_db;
SHOW TABLES;
SELECT * FROM customers;
SELECT * FROM orders;
```

## Day to day operations

| Task | Command |
| ---- | ------- |
| Start | `sh docker_run/run_datalake.sh` |
| Start everything | `PROFILE=all sh docker_run/run_datalake.sh start` |
| Stop, keeping data | `sh docker_run/run_datalake.sh stop` |
| Restart | `sh docker_run/run_datalake.sh restart` |
| Container status | `sh docker_run/run_datalake.sh status` |
| Follow logs | `sh docker_run/run_datalake.sh logs spark-master` |
| Check a compose edit | `sh docker_run/run_datalake.sh validate` |
| Shell into a service | `docker exec -it spark-master bash` |
| Publish images | `./publish-to-dockerhub.sh` |

**Full reset.** Stopping does not delete data. `docker_run/data` holds the Postgres data
directory and the MinIO object store as bind mounts, so state survives restarts:

```sh
sh docker_run/run_datalake.sh stop
rm -rf docker_run/data docker_run/logs
sh docker_run/run_datalake.sh start
```

**Empty the warehouse without a full reset:**

```sh
docker exec mc /usr/bin/mc rm --force --recursive minio/warehouse/
```

**Pin a different version.** `docker_run/.env` holds the image tags. The build script tags
every image with both its version and `latest`, so a pin only resolves if that version was
actually built.

## Changing a Dockerfile

Anything under `docker_build/` — a Dockerfile, a file in `conf/`, the build script — goes
through the same four steps, in this order:

```sh
IMAGES=<what you changed> ./docker_build/build_docker_images.sh
sh docker_run/run_datalake.sh restart
./demos/e2e_test.sh
./publish-to-dockerhub.sh
```

An image that builds is not an image that works, and the gap lands on whoever pulls next.
So the publish step enforces the test step rather than trusting it: a green `e2e_test.sh`
writes `.e2e-passed`, listing the ID of every live `ranga-*` image, and
`publish-to-dockerhub.sh` refuses to push an image whose current ID is not on that list.
Rebuilding changes the ID, so an untested image fails here:

```
Refusing to publish. These images were built or rebuilt after the last green run:
  rangareddy1988/ranga-spark:3.5.9 (954da2a3e8d9)

Re-run demos/e2e_test.sh, or set E2E_OVERRIDE=1 to bypass.
```

`E2E_OVERRIDE=1` exists for the case where the stack cannot be run on the machine doing the
push. It is not the normal path and it announces itself.

Also remember:

- **Config is baked in, not mounted.** `spark-defaults.conf`, `core-site.xml`,
  `hive-site.xml` and the Trino catalog files are `COPY`d at build
  time. Editing one needs a rebuild and a recreate; `restart` will not pick it up.
- **Both compose files hold the shared services verbatim.** Any change to a common service
  goes into `docker-compose.yml` *and* `docker-compose_all.yml`. Validate both:
  `sh docker_run/run_datalake.sh validate` and again with `PROFILE=all`.
- **`.env` and the build script move together.** Compose resolves the tag the build made, so
  a pin that was never built makes Docker try to pull a nonexistent tag from Docker Hub.

## Troubleshooting

### kafka-ui is missing entirely

`docker ps -a` shows `kafka-ui` as `Created`, never `Up`, and it has no logs.

kafka-ui has `depends_on: kafka-connect: condition: service_healthy`, which Compose checks
once at start. If Connect is not healthy then, kafka-ui is skipped. Check Connect, not the
UI:

```sh
docker inspect kafka-connect --format '{{.State.Health.Status}} restarts={{.RestartCount}}'
docker logs kafka-connect 2>&1 | grep -i unsupportedclassversion
```

A climbing restart count with `UnsupportedClassVersionError` means a connector compiled for
a newer Java than the image runs - Debezium 3.x is Java 17, this image is Java 11. Rebuild
it with `IMAGES=kafka-connect ./docker_build/build_docker_images.sh`; a published image can
be older than this repo.

Connect that is merely slow needs no action beyond waiting: it scans every plugin jar before
binding 8083, around 112s on an idle machine, and the healthcheck allows 180s before it
counts a failure.

| Symptom | Cause and fix |
| ------- | ------------- |
| `service "x" depends on undefined service "y": invalid compose project` | The two compose files drifted. Run `sh docker_run/run_datalake.sh validate` on both profiles |
| Compose tries to pull a `rangareddy1988/ranga-*` image | The pin in `docker_run/.env` does not match a locally built tag. Build that version or clear the pin |
| Every write fails, bucket list is empty | The `mc` sidecar did not finish. Check `sh docker_run/run_datalake.sh logs mc` |
| Editing a file under `docker_build/conf` changes nothing | Those files are `COPY`ed into images at build time, not mounted. Rebuild the image and recreate the container |
| A container is `Up` but nothing responds | The custom images end with a keepalive loop, so container state says nothing about the JVM. Run `./demos/e2e_test.sh` |
| `Refusing to publish: no record of a green end-to-end run` | `publish-to-dockerhub.sh` is gated on `demos/e2e_test.sh`. Start the stack and run it |

### On the `all` profile, kafka-connect restarts forever and never goes healthy

It is being killed, not failing. Check:

```sh
docker events --since 30m --until 0s --filter container=kafka-connect \
  --format '{{.Action}} exit={{index .Actor.Attributes "exitCode"}}' | grep -v exec_
```

`oom` followed by `exit=137` means the Docker VM ran out of memory. Connect is usually
the one that dies because it is the largest JVM in the stack, and `restart:
unless-stopped` brings it straight back to be killed again part-way through its plugin
scan — which looks like a slow start rather than a memory problem.

Give Docker 12 GB for the `all` profile. Connect's heap is already capped at 1 GB in
both compose files (`KAFKA_HEAP_OPTS`), down from its 2 GB default, but 22 containers
of mostly JVMs do not fit in 8 GB. Running the `core` profile instead is the other
answer; it holds comfortably in 8 GB.

### A build fails with `404 Not Found` on every `+deb11uN` package

```
E: Failed to fetch http://deb.debian.org/debian-security/pool/updates/main/j/jq/jq_1.6-2.1+deb11u3_amd64.deb  404
```

Debian 11 (bullseye) left LTS on 2026-08-31. `bullseye-security` still publishes an index
advertising those versions, but the pool behind it has been emptied, so apt resolves a
version it then cannot download. `Dockerfile.hive` and both Spark Dockerfiles already
retry against an archive that still has the files — `archive.debian.org` for Hive, the
pinned `snapshot.debian.org` lines for Spark. If you add a new Debian 11 based image, give
it the same fallback, and end the layer with a command that proves the install worked
(`jq --version`, `java -version`). Without that check a failed apt produces an image that
builds cleanly and breaks at runtime.


**The Hudi Streamer runs but no table appears in the metastore.** Either `--enable-sync` was
omitted, or the run found no new Kafka messages. Sync only happens after a commit.

**Registering a second Debezium connector fails with `replication slot "debezium" already
exists`.** Both bundled connectors use the same slot name and slot names are cluster-wide.
Drop the slot or rename one.

**Only the config in bind mounts is live-editable.** That is `docker_run/hudi_streamer`,
`docker_run/debezium_configs` and `docker_run/db_scripts`. Everything under
`docker_build/conf` requires an image rebuild.

## Repository layout

```
docker_build/            image definitions and build inputs
  Dockerfile.*           one per image; ten of them are thin pins on an upstream base
  build_docker_images.sh downloads prerequisites, then builds every image
  conf/                  config baked into the images (spark, hive, kafka, trino, hadoop)
  notebooks/             shipped inside the Spark image, served by SPARK_MODE=notebook
docker_run/              the Compose stack
  docker-compose.yml     core profile
  docker-compose_all.yml all profile, a superset
  run_datalake.sh        start/stop/status/logs/validate wrapper
  .env                   IMAGE_VERSION and the Spark line
  db_scripts/            Postgres and MySQL init SQL
  debezium_configs/      Debezium and Hudi Kafka Connect connector definitions
  hudi_streamer/         Hudi Streamer property files
demos/                   runnable scripts, bind-mounted into spark-master at /opt/demos
  e2e_test.sh            every service, end to end; the gate in front of publishing
  smoke_test_formats.sh  write/update/read in each format the image ships
  run_demo.sh            runs one demo with the jars and catalog config its format needs
publish-to-dockerhub.sh  pushes every local ranga-* image, gated on a green e2e run
```

`docker_build/{software,hadoop-s3-jars,db_connector_jars,lib}` and `docker_run/{data,logs}`
are gitignored. A fresh clone cannot build until `build_docker_images.sh` has populated them.
