# Datalake Playground Docker

## Start all the services

To start the services, use the following command:

```sh
sh docker_run/run_datalake.sh
```

The script accepts `start` (default), `stop`, `restart`, `status`, `logs [service...]`
and `validate`:

```sh
sh docker_run/run_datalake.sh status
sh docker_run/run_datalake.sh logs spark-master
sh docker_run/run_datalake.sh stop
```

Two profiles are available. The default `core` profile starts
`docker_run/docker-compose.yml`. Setting `PROFILE=all` starts
`docker_run/docker-compose_all.yml`, which additionally brings up MySQL, Trino,
Jupyter, XTable and Flink:

```sh
PROFILE=all sh docker_run/run_datalake.sh start
```

## Build the images

The `rangareddy1988/ranga-*` images are built locally. The build script also
downloads the Spark/Hadoop tarballs and the S3 and JDBC jars that the Dockerfiles
`COPY` in, so it must be run before the first start if the images are not already
present:

```sh
./docker_build/build_docker_images.sh
```

It builds every image in the `image_builds` array: `hive`, `spark`, `kafka-connect`,
`kafka-cat`, `trino`, `jupyter-notebook`, `xtable` and `flink`. Versions are
overridable env vars (`SPARK_VERSION`, `HIVE_VERSION`, `TRINO_VERSION`, ...) defined
at the top of the script. Note that `xtable` builds XTable from source with Maven, so
it dominates the build time.

## Table format versions

| Component | Version | Why this version |
| --------- | ------- | ---------------- |
| Spark     | 3.5.5 (JDK 17) | JDK 17 because Iceberg 1.11.0 is compiled for Java 17 |
| Flink     | 1.20.5 (java17) | Newest Flink all three formats support; there is no `flink-sql-connector-hive` for Flink 2.x, which the Hive Metastore catalogs need |
| Trino     | 483 | Latest release |
| Hudi      | 1.1.1 | Not 1.2.0: that release relocates its codahale metrics but keeps the `org.apache.flink.dropwizard.metrics.*` class names, which collides with Iceberg on Flink and makes the two connectors mutually exclusive |
| Iceberg   | 1.11.0 | Latest; needs Java 17 and Flink >= 1.20 |
| Delta     | 3.3.2 | Ceiling for Scala 2.12. Delta 4.x targets Spark 4.0 / Scala 2.13 and, on Flink, Flink 2.0 |

Hudi must stay on one version across Spark, Flink, Hive and Kafka Connect, since they
all read and write the same tables through the shared metastore.

## S3 paths: `s3a://` and `s3://`

Both schemes address the same MinIO buckets and are interchangeable, so a table
written through one reads back through the other:

```sql
CREATE TABLE t1 (id INT, name STRING) USING parquet LOCATION 's3a://warehouse/t1';
CREATE TABLE t2 (id INT, name STRING) USING parquet LOCATION 's3://warehouse/t2';
```

`s3://` is mapped onto `S3AFileSystem` in `docker_build/conf/hadoop/core-site.xml` and
`docker_build/conf/hive/hive-site.xml`. Credentials live only under the `fs.s3a.*` keys;
`S3AFileSystem` reads those for both schemes, so they are not duplicated per scheme.

## Components

Services marked **all** only exist in the `all` profile.

| Application/Component  | URL/PORT               | Profile | Other Details                                 |
| ---------------------- | ---------------------- | ------- | --------------------------------------------- |
| Zookeeper              | localhost:2181         | core    |                                               |
| Kafka Broker           | localhost:9092         | core    | In-network listener: `kafka:29092`            |
| Kafka JMX              | localhost:9101         | core    |                                               |
| Kafka Schema Registry  | http://localhost:8081  | core    |                                               |
| Kafka REST Proxy       | http://localhost:8082  | core    |                                               |
| Kafka Connect REST API | http://localhost:8083  | core    |                                               |
| Kafka UI               | http://localhost:9082  | core    |                                               |
| Hive Metastore (thrift)| localhost:9083         | core    |                                               |
| HiveServer2            | localhost:10000        | core    | Web UI on http://localhost:10002              |
| Spark Master UI        | http://localhost:8080  | core    | Submit to `spark://spark-master:7077`         |
| Spark Worker UI        | http://localhost:18081 | core    |                                               |
| Spark History Server   | http://localhost:18080 | core    |                                               |
| Spark Application UI   | http://localhost:14040 | core    | Container 4040-4042 mapped to 14040-14042     |
| Minio API              | http://localhost:9000  | core    | Buckets: `warehouse`, `datalake`              |
| Minio UI               | http://localhost:9001  | core    | **Username:** admin **Password**:password     |
| Postgres               | localhost:5432         | core    | **Username:** postgres **Password**:postgres  |
| Cloudbeaver            | http://localhost:8978  | core    | **Username:** cbadmin **Password**:Cbadmin123 |
| MySQL                  | localhost:3306         | all     | **Username:** admin **Password**:password     |
| Trino UI               | http://localhost:9084  | all     |                                               |
| Jupyter Lab            | http://localhost:8888  | all     | Token disabled                                |
| Flink UI               | http://localhost:8084  | all     |                                               |

## Connect to Postgres DB

To connect to the Postgres database running in a Docker container, execute:

```sh
docker exec -it postgres bash
```

```sql
psql -h postgres -U postgres -W
postgres=#
```

Once connected to the Postgres prompt, you can run the following commands:

```sql
postgres=# \l
postgres=# SHOW SEARCH_PATH;
postgres=# SET search_path TO inventory;
postgres=# \dt
postgres=# select * from employees;
```

## Kafka Connect is Up and Running

To connect to the Kafka Connect service, run:

```sh
docker exec -it kafka-connect bash
```

You can verify that Kafka Connect is running by executing:

```sh
curl -s -H "Accept:application/json" localhost:8083/ | jq
```

You should see output similar to:

```json
{
  "version": "7.4.7-ce",
  "commit": "75280b4ccc5d8be9",
  "kafka_cluster_id": "BlMYHQZ5TsmTiU0g7Btwow"
}
```

## Verify the PostgresConnector is Available

```sh
curl -sS http://localhost:8083/connector-plugins | jq '.[].class' | grep postgres
```

If successful, the output should include

```sh
"io.debezium.connector.postgresql.PostgresConnector"
```

## Create Connector Using Kafka Connect

To check for existing connectors, run:

```sh
curl -s localhost:8083/connectors/ | jq
```

If the output is empty ([]), you can create a new connector by posting the configuration:

```sh
curl -s -X POST \
 -H "Accept:application/json" \
 -H "Content-Type:application/json" \
 http://localhost:8083/connectors/ \
 -d @/opt/data/connector_configs/streamer_connector/register_employees_pg_connector.json | jq
```

Output would be

```json
{
  "name": "employees_pg_connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "plugin.name": "pgoutput",
    "slot.name": "debezium",
    "database.hostname": "postgres",
    "database.port": "5432",
    "database.user": "postgres",
    "database.password": "postgres",
    "database.dbname": "postgres",
    "topic.prefix": "cdc",
    "database.server.name": "postgres",
    "schema.include.list": "public",
    "table.include.list": "public.employees",
    "publication.name": "dbz_publication",
    "publication.autocreate.mode": "filtered",
    "tombstones.on.delete": "false",
    "key.converter": "io.confluent.connect.avro.AvroConverter",
    "key.converter.schema.registry.url": "http://kafka-schema-registry:8081/",
    "value.converter": "io.confluent.connect.avro.AvroConverter",
    "value.converter.schema.registry.url": "http://kafka-schema-registry:8081/",
    "name": "employees_pg_connector"
  },
  "tasks": [],
  "type": "source"
}
```

## Verify the Connector is Created

To verify that the connector has been created successfully, run:

```sh
curl -s -X GET \
 http://localhost:8083/connectors/employees_pg_connector | jq
```

You should see output similar to:

```json
{
  "name": "employees_pg_connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "publication.autocreate.mode": "filtered",
    "database.user": "postgres",
    "database.dbname": "postgres",
    "slot.name": "debezium",
    "publication.name": "dbz_publication",
    "database.server.name": "postgres",
    "schema.include.list": "public",
    "plugin.name": "pgoutput",
    "database.port": "5432",
    "tombstones.on.delete": "false",
    "value.converter.schema.registry.url": "http://kafka-schema-registry:8081/",
    "topic.prefix": "cdc",
    "database.hostname": "postgres",
    "database.password": "postgres",
    "name": "employees_pg_connector",
    "table.include.list": "public.employees",
    "value.converter": "io.confluent.connect.avro.AvroConverter",
    "key.converter": "io.confluent.connect.avro.AvroConverter",
    "key.converter.schema.registry.url": "http://kafka-schema-registry:8081/"
  },
  "tasks": [
    {
      "connector": "employees_pg_connector",
      "task": 0
    }
  ],
  "type": "source"
}
```

To check that the connector is running, execute:

```sh
curl -s -X GET \
 http://localhost:8083/connectors/employees_pg_connector/status | jq
```

```json
{
  "name": "employees_pg_connector",
  "connector": {
    "state": "RUNNING",
    "worker_id": "kafka-connect:8083"
  },
  "tasks": [
    {
      "id": 0,
      "state": "RUNNING",
      "worker_id": "kafka-connect:8083"
    }
  ],
  "type": "source"
}
```

## Connect to Kafka Broker

To connect to the Kafka broker, run:

```sh
docker exec -it kafka bash
```

You can list the topics to verify that the connector is working:

```sh
kafka-topics --list --bootstrap-server localhost:9092 | grep cdc
```

You should see:

```sh
cdc.public.employees
```

To consume messages from the topic, use:

```sh
kafka-console-consumer --bootstrap-server localhost:9092 --topic cdc.public.employees --from-beginning
```

Press Ctrl+C to stop the console consumer.

## Connect to Spark

To connect to the Spark master, execute:

```sh
docker exec -it spark-master bash
```

Create or edit the properties file for Hudi:

`vi /tmp/my_hudi.properties`

Add the following configuration:

```sh
bootstrap.servers=kafka:29092
auto.offset.reset=earliest
schema.registry.url=http://kafka-schema-registry:8081
hoodie.deltastreamer.schemaprovider.registry.url=http://kafka-schema-registry:8081/subjects/cdc.public.employees-value/versions/latest
hoodie.deltastreamer.source.kafka.value.deserializer.class=io.confluent.kafka.serializers.KafkaAvroDeserializer
hoodie.deltastreamer.source.kafka.topic=cdc.public.employees
hoodie.datasource.write.recordkey.field=id
hoodie.datasource.write.schema.allow.auto.evolution.column.drop=true
hoodie.datasource.write.keygenerator.class=org.apache.hudi.keygen.NonpartitionedKeyGenerator
```

### Run the Hudi Delta Streamer

Next, you will need to run the Hudi Delta Streamer using the properties file you just created. First, set the path to the Hudi utilities JAR:

```sh
export HUDI_UTILITIES_JAR=$(ls $HUDI_HOME/hudi-utilities-bundle*.jar)
```

Then, execute the following command to start the Delta Streamer:

**Hudi 0.x**

```sh
spark-submit \
    --class org.apache.hudi.utilities.deltastreamer.HoodieDeltaStreamer $HUDI_UTILITIES_JAR \
    --props file:///tmp/my_hudi.properties \
    --table-type MERGE_ON_READ \
    --op UPSERT \
    --target-base-path s3a://warehouse/employees_cdc \
    --target-table employees_cdc  \
    --source-class org.apache.hudi.utilities.sources.debezium.PostgresDebeziumSource \
    --source-ordering-field _event_lsn \
    --payload-class org.apache.hudi.common.model.debezium.PostgresDebeziumAvroPayload \
    --continuous \
    --min-sync-interval-seconds 60
```

**Hudi 1.x**

```sh
export HUDI_SPARK_BUNDLE_JAR=$(ls $HUDI_HOME/hudi-spark*-bundle_*.jar)
export HUDI_UTILITIES_SLIM_JAR=$(ls $HUDI_HOME/hudi-utilities-slim-bundle*.jar)

spark-submit \
    --jars $HUDI_SPARK_BUNDLE_JAR \
    --class org.apache.hudi.utilities.streamer.HoodieStreamer $HUDI_UTILITIES_SLIM_JAR \
    --props file:///tmp/my_hudi.properties \
    --table-type MERGE_ON_READ \
    --op UPSERT \
    --target-base-path s3a://warehouse/employees_cdc \
    --target-table employees_cdc  \
    --source-class org.apache.hudi.utilities.sources.debezium.PostgresDebeziumSource \
    --source-ordering-field _event_lsn \
    --payload-class org.apache.hudi.common.model.debezium.PostgresDebeziumAvroPayload \
    --continuous \
    --min-sync-interval-seconds 60
```

```sh
export HUDI_UTILITIES_JAR=$(ls $HUDI_HOME/hudi-utilities-bundle*.jar)

spark-submit --verbose \
    --class org.apache.hudi.utilities.streamer.HoodieStreamer $HUDI_UTILITIES_JAR \
    --props file:///tmp/my_hudi.properties \
    --table-type MERGE_ON_READ \
    --op UPSERT \
    --target-base-path file:\/\/\/tmp/employees_cdc \
    --target-table employees_cdc  \
    --source-class org.apache.hudi.utilities.sources.debezium.PostgresDebeziumSource \
    --source-ordering-field _event_lsn \
    --payload-class org.apache.hudi.common.model.debezium.PostgresDebeziumAvroPayload \
    --hoodie-conf hoodie.streamer.schemaprovider.registry.schemaconverter=org.apache.hudi.utilities.schema.converter.ProtoSchemaToAvroSchemaConverter
```

```sh
spark-submit \
    --packages org.apache.spark:spark-avro_2.12:3.5.3 \
    --class org.apache.hudi.utilities.streamer.HoodieStreamer hudi-utilities-bundle_2.12-1.1.0-SNAPSHOT.jar \
    --props file:///tmp/my_hudi.properties \
    --table-type MERGE_ON_READ \
    --op UPSERT \
    --target-base-path file:\/\/\/tmp/employees_cdc \
    --target-table employees_cdc  \
    --source-class org.apache.hudi.utilities.sources.debezium.PostgresDebeziumSource \
    --source-ordering-field _event_lsn \
    --payload-class org.apache.hudi.common.model.debezium.PostgresDebeziumAvroPayload
```

```properties
hoodie.datasource.write.recordkey.field=VendorID
hoodie.datasource.write.partitionpath.field=date_col
hoodie.datasource.write.precombine.field=date_col
hoodie.deltastreamer.source.dfs.root=s3a//datalake
```

```sh
export HUDI_UTILITIES_JAR=$(ls hudi-utilities-bundle*.jar)

spark-submit \
--class org.apache.hudi.utilities.deltastreamer.HoodieDeltaStreamer $HUDI_UTILITIES_JAR \
--props my_hudi.properties \
--source-class org.apache.hudi.utilities.sources.ParquetDFSSource \
--source-ordering-field date_col \
--table-type MERGE_ON_READ \
--target-base-path file:\/\/\/tmp/hudi-deltastreamer-ny/ \
--target-table ny_hudi_tbl 

spark-submit \
--class org.apache.hudi.utilities.streamer.HoodieStreamer $HUDI_UTILITIES_JAR \
--props my_hudi.properties \
--source-class org.apache.hudi.utilities.sources.ParquetDFSSource \
--source-ordering-field date_col \
--table-type MERGE_ON_READ \
--target-base-path file:\/\/\/tmp/hudi-deltastreamer-ny/ \
--target-table ny_hudi_tbl 
```

## Insert Sample Data into Employees Table

You can insert sample data into the employees table in Postgres to test the setup:

```sh
psql -h postgres -U postgres -W
postgres=#
```

```sql
insert into employees values(4, 'Nishanth', 7, 300000, 'Software');
insert into employees values(5, 'Reddy', 60, 350000, 'Hardware');
```

## Connect to Spark Shell

To connect to the Spark shell with the necessary Hudi dependencies, run:

```sh
export HUDI_SPARK_BUNDLE_JAR=$(ls $HUDI_HOME/hudi-spark*-bundle_*.jar)

spark-shell \
--jars $HUDI_SPARK_BUNDLE_JAR \
--conf 'spark.serializer=org.apache.spark.serializer.KryoSerializer' \
--conf 'spark.sql.catalog.spark_catalog=org.apache.spark.sql.hudi.catalog.HoodieCatalog' \
--conf 'spark.sql.extensions=org.apache.spark.sql.hudi.HoodieSparkSessionExtension' \
--conf 'spark.kryo.registrator=org.apache.spark.HoodieSparkKryoRegistrar'
```

## Load and Display Data from Hudi Table

Once in the Spark shell, you can load the data from the Hudi table and display it:

```scala
val basePath = "s3a://warehouse/employees_cdc"
val employeesDF = spark.read.format("hudi").load(basePath)
employeesDF.show(truncate=false)
```

## Hudi Multi Table Streamer Example

```sh
docker exec -it kafka-connect bash
```

```sh
curl -s -X POST \
  -H "Accept:application/json" \
  -H "Content-Type:application/json" \
  localhost:8083/connectors/ \
  -d @/opt/data/connector_configs/multi_table_streamer_connector/register_customers_orders_pg_connector.json | jq
```

```sh
docker exec -it spark-master bash
```

```sh
export HUDI_SPARK_BUNDLE_JAR=$(ls $HUDI_HOME/hudi-spark*-bundle_*.jar)
export HUDI_UTILITIES_SLIM_JAR=$(ls $HUDI_HOME/hudi-utilities-slim-bundle*.jar)
```

```sh
spark-submit \
  --jars $HUDI_SPARK_BUNDLE_JAR \
  --conf spark.serializer=org.apache.spark.serializer.KryoSerializer \
  --conf spark.sql.hive.convertMetastoreParquet=false \
  --class org.apache.hudi.utilities.streamer.HoodieMultiTableStreamer $HUDI_UTILITIES_SLIM_JAR \
  --props file:///opt/hudi_streamer/hudi_multi_table_stream.properties \
  --config-folder file:///opt/hudi_streamer/ \
  --source-class org.apache.hudi.utilities.sources.debezium.PostgresDebeziumSource \
  --payload-class org.apache.hudi.common.model.debezium.PostgresDebeziumAvroPayload \
  --base-path-prefix s3a://warehouse/multi-table/ \
  --source-ordering-field _event_origin_ts_ms \
  --table-type COPY_ON_WRITE \
  --enable-sync \
  --op UPSERT \
  --source-limit 4000000 \
  --min-sync-interval-seconds 60
```

```sh
spark-sql \
  --jars $HUDI_SPARK_BUNDLE_JAR
```

```sh
docker exec -it trino bash
```

```sh
trino> show schemas;
trino> use cdc_test_db;
trino:cdc_test_db> show tables;
trino:cdc_test_db> select * from customers;
trino:cdc_test_db> select * from orders;
```

```sh
export HUDI_SPARK_BUNDLE_JAR=$(ls $HUDI_HOME/hudi-spark*-bundle_*.jar)
export HUDI_UTILITIES_SLIM_JAR=$(ls $HUDI_HOME/hudi-utilities-slim-bundle*.jar)

spark-submit \
  --jars $HUDI_SPARK_BUNDLE_JAR \
  --conf spark.serializer=org.apache.spark.serializer.KryoSerializer \
  --conf spark.sql.hive.convertMetastoreParquet=false \
  --class org.apache.hudi.utilities.streamer.HoodieMultiTableStreamer $HUDI_UTILITIES_SLIM_JAR \
  --props file:///opt/hudi_streamer/hudi_multi_table_stream.properties \
  --config-folder file:///opt/hudi_streamer/ \
  --source-class org.apache.hudi.utilities.sources.debezium.PostgresDebeziumSource \
  --payload-class org.apache.hudi.common.model.debezium.PostgresDebeziumAvroPayload \
  --base-path-prefix s3a://warehouse/multi-table/ \
  --target-table customers,orders \
  --source-ordering-field _event_origin_ts_ms \
  --table-type COPY_ON_WRITE \
  --enable-sync \
  --op UPSERT \
  --source-limit 4000000 \
  --min-sync-interval-seconds 60 \
  --continuous
```
