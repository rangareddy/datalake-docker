# Datalake Playground Docker

A local lakehouse you can run on one machine. It wires Postgres and MySQL through Debezium
and Kafka into Apache Hudi, Apache Iceberg and Delta Lake tables stored on MinIO, catalogued
in a shared Hive Metastore, and queryable from Spark, Flink and Trino.

Everything is Docker images plus a Compose stack. There is no application code to build.

## Contents

- [Prerequisites](#prerequisites)
- [Setup, step by step](#setup-step-by-step)
  - [Step 1: Check your machine](#step-1-check-your-machine)
  - [Step 2: Build the images](#step-2-build-the-images)
  - [Step 3: Start the stack](#step-3-start-the-stack)
  - [Step 4: Verify every service](#step-4-verify-every-service)
  - [Step 5: Create your first table](#step-5-create-your-first-table)
- [Architecture](#architecture)
- [Components and ports](#components-and-ports)
- [Versions](#versions)
- [Working with the table formats](#working-with-the-table-formats)
- [S3 paths: `s3a://` and `s3://`](#s3-paths-s3a-and-s3)
- [CDC walkthrough: Postgres to Hudi to Trino](#cdc-walkthrough-postgres-to-hudi-to-trino)
- [Multi table CDC](#multi-table-cdc)
- [Day to day operations](#day-to-day-operations)
- [Troubleshooting](#troubleshooting)
- [Repository layout](#repository-layout)

## Prerequisites

| Requirement | Detail |
| ----------- | ------ |
| Docker      | With Compose v2 (`docker compose`). The v1 `docker-compose` binary also works |
| Disk        | About 25 GB. The built images total roughly 22 GB, and the build inputs another 1.5 GB |
| Memory      | Give Docker at least 8 GB. Spark and Flink each run a JVM pair, and Trino wants headroom |
| Network     | The first build downloads the Spark and Hadoop tarballs plus about 40 jars from Maven Central |
| Free ports  | 2181, 3306, 5432, 6121-6123, 7077, 8080-8084, 8888, 8978, 9000-9001, 9082-9084, 9092, 9101, 10000, 10002, 14040-14042, 18080-18081, 29092 |

The stack runs `linux/amd64` images. On Apple Silicon they run under emulation, which works
but is slower. Set `PLATFORM=linux/arm64` in `docker_run/.env` if you rebuild natively.

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
3. Runs `download_flink_jars.sh`, which assembles the Flink connector set in
   `docker_build/lib` and prunes any jar left over from a previous version.
4. Builds every entry in the `image_builds` array: `hive`, `spark`, `kafka-connect`,
   `kafka-cat`, `trino`, `jupyter-notebook`, `xtable` and `flink`.

Each image prints a line on success:

```
Successfully built spark:3.5.5
```

This takes a while on a cold cache. The `xtable` image compiles XTable from source with
Maven and dominates the total. Every image is tagged twice, with its version and with
`latest`, so `docker_run/.env` can pin exact versions.

#### Choosing a Spark line

The build supports two profiles, selected by `SPARK_VERSION`. Everything else follows from
it, because the Spark line dictates the Scala binary, the bundled Hadoop, and which builds
of Hudi, Iceberg and Delta exist:

| `SPARK_VERSION` | Scala | Hadoop | Hudi  | Iceberg | Delta |
| --------------- | ----- | ------ | ----- | ------- | ----- |
| `3.5.5` (default) | 2.12 | 3.3.4 | 1.1.1 | 1.11.0 | 3.3.2 |
| `4.0.2`           | 2.13 | 3.4.1 | 1.2.0 | 1.11.0 | 4.0.0 |

```sh
SPARK_VERSION=4.0.2 ./docker_build/build_docker_images.sh
```

Then pin the same version for the stack, so Compose resolves the tag that was built:

```sh
SPARK_VERSION=4.0.2 sh docker_run/run_datalake.sh restart
```

Spark 4.1 is deliberately not offered. Delta publishes no Scala 2.13 build past 4.0.0, so a
4.1 image would come without Delta, and this stack exists to run all three formats side by
side.

Note the S3A dependency changes with the profile: Hadoop 3.3.x uses AWS SDK v1
(`aws-java-sdk-bundle`) and Hadoop 3.4.x uses SDK v2 (`software.amazon.awssdk:bundle`). The
build script downloads the right one and stages a clean `hadoop-s3-jars/` for the image, so
switching profiles does not leave the previous SDK behind on the classpath.

To build only some images, which is much faster than the full set:

```sh
IMAGES=spark SPARK_VERSION=4.0.2 ./docker_build/build_docker_images.sh
IMAGES=spark,trino ./docker_build/build_docker_images.sh
```

To rebuild one image only, for example after editing a config file:

```sh
cd docker_build
docker build --build-arg SPARK_VERSION=3.5.5 --platform linux/amd64 \
  -f "$PWD/Dockerfile.spark" "$PWD" \
  -t rangareddy1988/ranga-spark:3.5.5 -t rangareddy1988/ranga-spark:latest
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
| `core` (default) | `docker-compose.yml` | Kafka stack, Hive, Spark, Postgres, MinIO, CloudBeaver |
| `all` | `docker-compose_all.yml` | Everything in `core` plus MySQL, Trino, Jupyter, XTable and Flink |

To bring up the full stack, which you need for the Trino and Flink sections below:

```sh
PROFILE=all sh docker_run/run_datalake.sh start
```

Startup is ordered by health checks, so services wait for their dependencies. Expect the
first start to take a couple of minutes while Hive initialises its metastore schema.

### Step 4: Verify every service

First check the containers:

```sh
sh docker_run/run_datalake.sh status
```

Every row should read `Up ... (healthy)`, except `hive-server`, `taskmanager`, `mc` and
`kafka-cat`, which have no health check defined:

```
NAME             IMAGE                               SERVICE          STATUS
hive-metastore   rangareddy1988/ranga-hive:4.0.0     hive-metastore   Up 28 hours (healthy)
jobmanager       rangareddy1988/ranga-flink:1.20.5   jobmanager       Up 28 hours (healthy)
kafka            confluentinc/cp-kafka:7.4.7         kafka            Up 28 hours (healthy)
```

A container being `Up` does not mean the service inside is serving. The custom images end
their entrypoint with a keepalive loop, so check the endpoints too:

```sh
printf 'MinIO        : %s\n' "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:9000/minio/health/live)"
printf 'Schema Reg   : %s\n' "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8081/subjects)"
printf 'Kafka Connect: %s\n' "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8083/)"
printf 'Spark master : %s\n' "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080)"
printf 'Metastore    : %s\n' "$(docker exec hive-metastore bash -c 'exec 6<>/dev/tcp/localhost/9083' 2>/dev/null && echo open || echo closed)"
printf 'Trino        : %s\n' "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:9084/v1/info)"
printf 'Flink        : %s\n' "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8084/overview)"
```

All of these should report `200`, and the metastore `open`:

```
MinIO        : 200
Schema Reg   : 200
Kafka Connect: 200
Spark master : 200
Metastore    : open
Trino        : 200
Flink        : 200
```

Then confirm the storage and catalog wiring. The `mc` sidecar creates two buckets on
startup:

```sh
docker exec mc /usr/bin/mc ls minio
```

```
[2026-08-12 05:56:27 UTC]     0B datalake/
[2026-08-12 05:56:27 UTC]     0B warehouse/
```

If the bucket list is empty, the storage layer is not ready and every write will fail. Check
`sh docker_run/run_datalake.sh logs mc`.

Finally, confirm the engines report the versions you expect:

```sh
curl -s http://localhost:8084/overview | jq -c '{taskmanagers,"slots-total","flink-version"}'
curl -s http://localhost:9084/v1/info | jq -c '{version:.nodeVersion.version,starting}'
docker exec spark-master bash -lc 'spark-submit --version 2>&1 | grep "version 3"'
```

```
{"taskmanagers":1,"slots-total":4,"flink-version":"1.20.5"}
{"version":"483","starting":false}
   /___/ .__/\_,_/_/ /_/\_\   version 3.5.5
```

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
 Hive Metastore  <---- shared catalog ---->  Spark | Flink | Trino
```

Three planes are worth understanding:

**Storage.** MinIO is the S3 endpoint at `http://minio:9000`. The `mc` sidecar creates the
`warehouse` and `datalake` buckets on startup, then idles. `core-site.xml` is baked into the
Spark and Flink images and sets `fs.defaultFS` to `s3a://warehouse/`.

**Catalog.** One Hive Metastore at `thrift://hive-metastore:9083`, backed by Postgres, is the
shared catalog for Spark, Flink and Trino. Anything written with metadata sync enabled becomes
queryable from the other engines without extra registration.

**Ingestion.** Two independent routes land CDC data in Hudi: the Hudi Streamer submitted to
Spark, and the Hudi Kafka Connect sink running inside the `kafka-connect` container. Both are
driven interactively with `docker exec`.

## Components and ports

Rows marked `all` exist only in the `all` profile.

| Component              | URL / port             | Profile | Notes                                         |
| ---------------------- | ---------------------- | ------- | --------------------------------------------- |
| Zookeeper              | localhost:2181         | core    |                                               |
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
| CloudBeaver            | http://localhost:8978  | core    | `cbadmin` / `Cbadmin123`                      |
| MySQL                  | localhost:3306         | all     | `admin` / `password`                          |
| Trino                  | http://localhost:9084  | all     | Container port 8080                           |
| Jupyter Lab            | http://localhost:8888  | all     | Token disabled                                |
| Flink UI               | http://localhost:8084  | all     | Not the Flink default 8081                    |

Host ports are not always the same as container ports. The Spark worker UI and Trino are
remapped to avoid colliding with the Schema Registry on 8081 and the Spark master on 8080.

All credentials are uniform demo values and are hardcoded across `aws.env`, `core-site.xml`,
the Trino catalog files and the compose files. Changing one means changing all of them.

## Versions

The table below is the default (Spark 3.5) profile. See
[Choosing a Spark line](#choosing-a-spark-line) for the Spark 4.0 set.

| Component | Version         | Why this one |
| --------- | --------------- | ------------ |
| Spark     | 3.5.5 on JDK 17 | Default profile. JDK 17 is required because Iceberg 1.11.0 is compiled for Java 17. `SPARK_VERSION=4.0.2` switches to the Scala 2.13 profile |
| Flink     | 1.20.5 on Java 17 | Newest Flink all three formats support. There is no `flink-sql-connector-hive` build for Flink 2.x, and the metastore catalogs need it |
| Trino     | 483             | Latest release. Trino 460 could not read Hudi 1.x tables at all |
| Hudi      | 1.1.1           | Not 1.2.0, see the note below |
| Iceberg   | 1.11.0          | Latest. Needs Java 17 and Flink 1.20 or newer |
| Delta     | 3.3.2           | Ceiling for Scala 2.12. On the Spark 4.0 profile this becomes Delta 4.0.0, the only Scala 2.13 build |

Hudi stays on one version across Spark, Flink, Hive and Kafka Connect, because all of them
read and write the same tables through the shared metastore.

Hudi is deliberately held at 1.1.1. Release 1.2.0 relocated its codahale metrics to
`org.apache.hudi.com.codahale.metrics.*` but kept exporting
`org.apache.flink.dropwizard.metrics.*` under the original package name, so its wrapper no
longer matches the one Iceberg expects. On Flink, whichever bundle loses the classpath sort
order fails its `INSERT` with `NoSuchMethodError`, which makes the Hudi and Iceberg
connectors mutually exclusive. Because `org.apache.flink.` is a parent-first package, passing
one bundle with `sql-client -j` does not avoid it. Hudi 1.1.1 does not relocate codahale and
coexists with Iceberg.

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

### Flink SQL

The `all` profile ships one ready-made script per format in `/opt/flink/conf`, built from
`docker_build/conf/flink/sql`. Each creates a catalog, a database and a table, then inserts.

**Step 1.** Run a script:

```sh
docker exec -it jobmanager /opt/flink/bin/sql-client.sh -f /opt/flink/conf/hudi-flink.sql
docker exec -it jobmanager /opt/flink/bin/sql-client.sh -f /opt/flink/conf/iceberg-flink.sql
docker exec -it jobmanager /opt/flink/bin/sql-client.sh -f /opt/flink/conf/delta-flink.sql
```

For an interactive session, drop the `-f`.

**Step 2.** Check the job actually succeeded. The SQL client submits `INSERT` jobs
asynchronously and returns before they finish, so a clean exit does not mean the write
worked:

```sh
curl -s http://localhost:8084/jobs/overview | jq -r '.jobs[] | "\(.state)  \(.name)"'
```

```
FINISHED  insert-into_hudi_hive_catalog.hudi_db.hudi_table
```

Anything other than `FINISHED` or `RUNNING` means the write failed. Get the reason with:

```sh
curl -s "http://localhost:8084/jobs/<job-id>/exceptions" | jq -r '."root-exception"' | head -20
```

**Step 3.** Confirm the data:

```sh
docker exec mc /usr/bin/mc ls -r minio/warehouse/hudi_db/hudi_table | grep parquet | head -3
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

## Troubleshooting

| Symptom | Cause and fix |
| ------- | ------------- |
| `service "x" depends on undefined service "y": invalid compose project` | The two compose files drifted. Run `sh docker_run/run_datalake.sh validate` on both profiles |
| Compose tries to pull a `rangareddy1988/ranga-*` image | The pin in `docker_run/.env` does not match a locally built tag. Build that version or clear the pin |
| Every write fails, bucket list is empty | The `mc` sidecar did not finish. Check `sh docker_run/run_datalake.sh logs mc` |
| Editing a file under `docker_build/conf` changes nothing | Those files are `COPY`ed into images at build time, not mounted. Rebuild the image and recreate the container |
| A container is `Up` but nothing responds | The custom images end with a keepalive loop, so container state says nothing about the JVM. Probe the endpoint directly |

**A Flink Hudi job kills the whole cluster with `Unsupported scheme :s3a`.** Hudi's default
`FileSystemBasedLockProvider` cannot work on object storage, and the failure takes down the
JobMaster rather than just the job. Set a lock provider on the table, as the bundled
`hudi-flink.sql` does:

```sql
'hoodie.write.lock.provider' = 'org.apache.hudi.client.transaction.lock.InProcessLockProvider'
```

**A Flink SQL script reports no errors but writes no data.** The client submits
asynchronously and returns before the job finishes. Check
`http://localhost:8084/jobs/overview` for the real state.

**Hudi Flink DDL fails with `Primary key definition is required`.** From Hudi 1.2.0 on the
record key must be explicit, either as `PRIMARY KEY (col) NOT ENFORCED` or via
`hoodie.datasource.write.recordkey.field`.

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
  Dockerfile.*           one per image
  build_docker_images.sh downloads prerequisites, then builds every image
  download_flink_jars.sh assembles the Flink connector set into lib/
  conf/                  config baked into the images (spark, hive, flink, trino, hadoop)
    flink/sql/           ready-made Hudi, Iceberg and Delta SQL scripts
docker_run/              the Compose stack
  docker-compose.yml     core profile
  docker-compose_all.yml all profile, a superset
  run_datalake.sh        start/stop/status/logs/validate wrapper
  .env                   image version pins
  db_scripts/            Postgres and MySQL init SQL
  debezium_configs/      Debezium and Hudi Kafka Connect connector definitions
  hudi_streamer/         Hudi Streamer property files
publish-to-dockerhub.sh  pushes every local ranga-* image
```

`docker_build/{software,hadoop-s3-jars,db_connector_jars,lib}` and `docker_run/{data,logs}`
are gitignored. A fresh clone cannot build until `build_docker_images.sh` has populated them.
