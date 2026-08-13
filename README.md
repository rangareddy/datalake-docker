# Datalake Playground Docker

A local lakehouse you can run on one machine. It wires Postgres and MySQL through
Debezium and Kafka into Apache Hudi, Apache Iceberg and Delta Lake tables stored on
MinIO, catalogued in a shared Hive Metastore, and queryable from Spark, Flink and Trino.

Everything is Docker images plus a Compose stack. There is no application code to build.

## Contents

- [Quick start](#quick-start)
- [Architecture](#architecture)
- [Components and ports](#components-and-ports)
- [Versions](#versions)
- [Working with the table formats](#working-with-the-table-formats)
- [S3 paths: `s3a://` and `s3://`](#s3-paths-s3a-and-s3)
- [CDC walkthrough: Postgres to Hudi to Trino](#cdc-walkthrough-postgres-to-hudi-to-trino)
- [Multi table CDC](#multi-table-cdc)
- [Troubleshooting](#troubleshooting)
- [Repository layout](#repository-layout)

## Quick start

Build the images first. The script also downloads the Spark and Hadoop tarballs and the
S3 and JDBC jars that the Dockerfiles `COPY` in, so it has to run before the first start:

```sh
./docker_build/build_docker_images.sh
```

It builds every entry in the `image_builds` array: `hive`, `spark`, `kafka-connect`,
`kafka-cat`, `trino`, `jupyter-notebook`, `xtable` and `flink`. Versions are env vars with
defaults at the top of the script (`SPARK_VERSION`, `HIVE_VERSION`, `TRINO_VERSION`, and so
on). The `xtable` image compiles XTable from source with Maven and dominates the build time.

Then start the stack:

```sh
sh docker_run/run_datalake.sh
```

The script takes `start` (the default), `stop`, `restart`, `status`, `logs [service...]`
and `validate`:

```sh
sh docker_run/run_datalake.sh status
sh docker_run/run_datalake.sh logs spark-master
sh docker_run/run_datalake.sh validate     # check the compose file without starting anything
sh docker_run/run_datalake.sh stop
```

There are two profiles. The default `core` profile starts `docker_run/docker-compose.yml`
with the Kafka stack, Hive, Spark, Postgres, MinIO and CloudBeaver. `PROFILE=all` starts
`docker_run/docker-compose_all.yml`, which adds MySQL, Trino, Jupyter, XTable and Flink:

```sh
PROFILE=all sh docker_run/run_datalake.sh start
```

Run `validate` after editing either compose file. The two files duplicate their shared
service definitions, so they drift easily, and a dangling `depends_on` makes the whole
project invalid rather than failing on one service.

Stopping does not delete data. `docker_run/data` holds the Postgres data directory and the
MinIO object store as bind mounts, so state survives a restart. Delete that directory for a
clean slate.

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

| Component | Version         | Why this one |
| --------- | --------------- | ------------ |
| Spark     | 3.5.5 on JDK 17 | JDK 17 is required because Iceberg 1.11.0 is compiled for Java 17 |
| Flink     | 1.20.5 on Java 17 | Newest Flink all three formats support. There is no `flink-sql-connector-hive` build for Flink 2.x, and the metastore catalogs need it |
| Trino     | 483             | Latest release. Trino 460 could not read Hudi 1.x tables at all |
| Hudi      | 1.1.1           | Not 1.2.0, see the note below |
| Iceberg   | 1.11.0          | Latest. Needs Java 17 and Flink 1.20 or newer |
| Delta     | 3.3.2           | Ceiling for Scala 2.12. Delta 4.x targets Spark 4.0 and Scala 2.13, and Flink 2.0 |

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

The image ships the format jars under `$HUDI_HOME`, `$ICEBERG_HOME` and `$DELTA_HOME`.

### Hudi

```sh
spark-sql --jars $(ls $HUDI_HOME/hudi-spark3.5-bundle_*.jar) \
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
`docker_build/conf/flink/sql`. Each creates a catalog, a database and a table, then inserts:

```sh
docker exec -it jobmanager /opt/flink/bin/sql-client.sh -f /opt/flink/conf/hudi-flink.sql
docker exec -it jobmanager /opt/flink/bin/sql-client.sh -f /opt/flink/conf/iceberg-flink.sql
docker exec -it jobmanager /opt/flink/bin/sql-client.sh -f /opt/flink/conf/delta-flink.sql
```

For an interactive session, drop the `-f`.

The SQL client submits `INSERT` jobs asynchronously and returns before they finish, so a
clean exit does not mean the write succeeded. Check the job state before trusting it:

```sh
curl -s http://localhost:8084/jobs/overview | jq -r '.jobs[] | "\(.state)  \(.name)"'
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
comparing CDC output against the source rows.

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

### 1. Register the Debezium source connector

The connector definitions are mounted into the Kafka Connect container at
`/opt/data/connector_configs`. Register from the host:

```sh
curl -s -X POST -H "Content-Type:application/json" \
  http://localhost:8083/connectors/ \
  -d @docker_run/debezium_configs/streamer_connector/register_employees_pg_connector.json | jq
```

Confirm it is running and that the topic exists:

```sh
curl -s http://localhost:8083/connectors/employees_pg_connector/status | jq '.connector.state'
docker exec kafka kafka-topics --list --bootstrap-server localhost:9092 | grep cdc
```

The topic is `cdc.public.employees`, built from the `topic.prefix` and the table name. To
watch the raw change events:

```sh
docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 --topic cdc.public.employees --from-beginning
```

### 2. Run the Hudi Streamer

```sh
docker exec -it spark-master bash
```

Write the job properties. These use the current `hoodie.streamer.*` prefix. The older
`hoodie.deltastreamer.*` names still resolve in Hudi 1.1.1 but are deprecated:

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

Hive sync mode and the metastore URI come from `hudi-defaults.conf`, which is baked into the
image at `/etc/hudi/conf`, so they do not need repeating here.

Submit the job. The slim utilities bundle needs the Spark bundle on `--jars`:

```sh
export SPARK_BUNDLE=$(ls $HUDI_HOME/hudi-spark3.5-bundle_*.jar)
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

`--enable-sync` is the flag that registers the table in the metastore. The properties alone
are not enough. Sync only runs after a successful commit, so a run that finds no new Kafka
messages will not create the table.

Add `--continuous --min-sync-interval-seconds 60` to keep the job running and ingest
continuously instead of exiting after one batch.

### 3. Read the result

From Spark:

```sh
spark-shell --jars $(ls $HUDI_HOME/hudi-spark3.5-bundle_*.jar) \
  --conf spark.serializer=org.apache.spark.serializer.KryoSerializer
```

```scala
spark.read.format("hudi").load("s3a://warehouse/employees_cdc").
  select("id", "name", "department").orderBy("id").show(false)
```

Because the table is `MERGE_ON_READ`, hive sync registers two views alongside the base name:
`employees_cdc_ro` reads only compacted base files, and `employees_cdc_rt` merges the log
files at query time. From Trino:

```sql
SELECT id, name, department FROM hudi.default.employees_cdc_ro ORDER BY id;
```

### 4. Watch a change flow through

Insert a row in Postgres, re-run the `spark-submit` above, and it appears in the Hudi table:

```sh
docker exec postgres psql -U postgres -c \
  "INSERT INTO public.employees VALUES (6, 'Kiran', 29, 120000, 'Analytics');"
```

## Multi table CDC

`HoodieMultiTableStreamer` ingests several tables in one job. The source tables `customers`
and `orders` live in a **separate Postgres database** called `cdc_db`, created by
`docker_run/db_scripts/postgres/multi_table_data.sql`. Connect with
`docker exec -it postgres psql -U postgres -d cdc_db` to inspect them. The Hive database the
job writes into is named `cdc_test_db`, set by `hoodie.streamer.ingestion.tablesToBeIngested`
in `docker_run/hudi_streamer/hudi_multi_table_stream.properties`. The two names are different.

Register the connector:

```sh
curl -s -X POST -H "Content-Type:application/json" \
  http://localhost:8083/connectors/ \
  -d @docker_run/debezium_configs/multi_table_streamer_connector/register_customers_orders_pg_connector.json | jq
```

Both this connector and the employees one specify `slot.name: debezium`. Postgres replication
slot names are unique across the whole cluster, not per database, so registering both at once
fails with `replication slot "debezium" already exists`. Delete one before creating the other,
or edit the `slot.name` in one of the JSON files.

Deleting a connector does not drop its replication slot, and an orphaned slot makes Postgres
retain WAL indefinitely. Clean up after removing a connector:

```sh
docker exec postgres psql -U postgres -c "SELECT slot_name FROM pg_replication_slots;"
docker exec postgres psql -U postgres -c "SELECT pg_drop_replication_slot('debezium');"
```

Then submit the job. `docker_run/hudi_streamer` is mounted into the Spark master at
`/opt/hudi_streamer`, so the config folder is visible to the driver:

```sh
export SPARK_BUNDLE=$(ls $HUDI_HOME/hudi-spark3.5-bundle_*.jar)
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

Query the result from Trino:

```sql
USE hudi.cdc_test_db;
SHOW TABLES;
SELECT * FROM customers;
SELECT * FROM orders;
```

## Troubleshooting

**A Flink Hudi job kills the cluster with `Unsupported scheme :s3a`.** Hudi's default
`FileSystemBasedLockProvider` cannot work on object storage, and the failure takes down the
JobMaster rather than just the job. Set a lock provider on the table, as the bundled
`hudi-flink.sql` does:

```sql
'hoodie.write.lock.provider' = 'org.apache.hudi.client.transaction.lock.InProcessLockProvider'
```

**A Flink SQL script reports no errors but writes no data.** The client submits
asynchronously. Check `http://localhost:8084/jobs/overview` for the real job state.

**Hudi Flink DDL fails with `Primary key definition is required`.** From Hudi 1.2.0 on the
record key must be explicit, either as `PRIMARY KEY (col) NOT ENFORCED` or via
`hoodie.datasource.write.recordkey.field`.

**Editing a file under `docker_build/conf` changes nothing.** Those files are `COPY`ed into
the images at build time, not mounted. Rebuild the image and recreate the container. The
only live-editable config is what the compose files bind mount: `docker_run/hudi_streamer`,
`docker_run/debezium_configs` and `docker_run/db_scripts`.

**A container is `Up` but the service inside is not.** The custom images end their entrypoint
with a keepalive loop, so container state says nothing about the JVM. Check the service
directly, for example `curl http://localhost:8084/overview` for Flink, or read the logs with
`sh docker_run/run_datalake.sh logs <service>`.

**Compose tries to pull a `rangareddy1988/ranga-*` image from Docker Hub.** The version pin in
`docker_run/.env` does not match a locally built tag. The build script tags every image with
both its version and `latest`, so either build that version or clear the pin.

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
