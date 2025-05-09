# Datalake Playground Docker

## Start all the services

To start the all services, use the following command:

```sh
$ sh docker_run/run_datalake.sh
```

## Components

| Application/Component  | URL/PORT               | Other Details                                 |
| ---------------------- | ---------------------- | --------------------------------------------- |
| Zookeeper              | http://localhost:2181  |                                               |
| Kafka Broker           | http://localhost:9092  |                                               |
| Kafka Schema Registry  | http://localhost:8081  |                                               |
| Kafka Connector        | http://localhost:8083  |                                               |
| Debezium UI            | http://localhost:9081  |                                               |
| Kafka Connect REST API | http://localhost:8082  |                                               |
| Kafka UI               | http://localhost:9082  |                                               |
| Spark Master UI        | http://localhost:8080  |                                               |
| Spark Worker UI        | http://localhost:18081 |                                               |
| Spark History Server   | http://localhost:18080 |                                               |
| Trino UI               | http://localhost:9084  |                                               |
| Minio UI               | http://localhost:9001  | **Username:** admin **Password**:password     |
| Postgres               | http://localhost:5432  | **Username:** postgres **Password**:postgres  |
| MySQL                  | http://localhost:3306  | **Username:** admin **Password**:password     |
| Cloudbeaver            | http://localhost:8978  | **Username:** cbadmin **Password**:Cbadmin123 |
| Flink UI               | http://localhost:8084  |                                               |

## Connect to Postgres DB

To connect to the Postgres database running in a Docker container, execute:

```sh
% docker exec -it postgres bash
```

```sql
# psql -h postgres -U postgres -W
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
$ docker exec -it kafka-connect bash
```

You can verify that Kafka Connect is running by executing:

```sh
$ curl -s -H "Accept:application/json" localhost:8083/ | jq
```

You should see output similar to:

```json
{
  "version": "7.4.7-ce",
  "commit": "75280b4ccc5d8be9",
  "kafka_cluster_id": "BlMYHQZ5TsmTiU0g7Btwow"
}
```

## Create Connector Using Kafka Connect

To check for existing connectors, run:

```sh
$ curl -s localhost:8083/connectors/ | jq
```

If the output is empty ([]), you can create a new connector by posting the configuration:

```sh
curl -s -X POST -H "Accept:application/json" -H "Content-Type:application/json" localhost:8083/connectors/ -d @/opt/data/connectors/register_employees_pg_connector.json | jq
```

## Verify the Connector is Created

To verify that the connector has been created successfully, run:

```sh
curl -s -X GET http://localhost:8083/connectors/employees_pg_connector | jq
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
$ curl -s -X GET http://localhost:8083/connectors/employees_pg_connector/status | jq
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
% docker exec -it kafka bash
```

You can list the topics to verify that the connector is working:

```sh
$ kafka-topics --list --bootstrap-server localhost:9092 | grep cdc
```

You should see:

```sh
cdc.public.employees
```

To consume messages from the topic, use:

```sh
$ kafka-console-consumer --bootstrap-server localhost:9092 --topic cdc.public.employees --from-beginning
```

## Connect to Spark

To connect to the Spark master, execute:

```sh
% docker exec -it spark-master bash
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

Run the Hudi Delta Streamer

Next, you will need to run the Hudi Delta Streamer using the properties file you just created. First, set the path to the Hudi utilities JAR:

```sh
export HUDI_UTILITIES_JAR=$(ls $HUDI_HOME/packaging/hudi-utilities-bundle/target/hudi-utilities-bundle*.jar)
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
export HUDI_SPARK_BUNDLE_JAR=$(ls $HUDI_HOME/hudi-spark-bundle/hudi-spark*-bundle_*.jar)
export HUDI_UTILITIES_SLIM_JAR=$(ls $HUDI_HOME/hudi-utilities-slim-bundle/hudi-utilities-slim-bundle*.jar)

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
export HUDI_UTILITIES_JAR=$(ls $HUDI_HOME/hudi-utilities-bundle/hudi-utilities-bundle*.jar)

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

```sql
insert into employees values(2, 'Nishanth', 7, 300000, 'Software');
insert into employees values(3, 'Reddy', 60, 350000, 'Hardware');
```

## Connect to Spark Shell

To connect to the Spark shell with the necessary Hudi dependencies, run:

```sh
export HUDI_SPARK_BUNDLE_JAR=$(ls $HUDI_HOME/packaging/hudi-spark-bundle/target/hudi-spark*-bundle_*.jar)

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
export HUDI_SPARK_BUNDLE_JAR=$(ls $HUDI_HOME/packaging/hudi-spark-bundle/target/hudi-spark*-bundle_*.jar)
export HUDI_UTILITIES_SLIM_JAR=$(ls $HUDI_HOME/packaging/hudi-utilities-slim-bundle/target/hudi-utilities-slim-bundle*.jar)
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
export HUDI_SPARK_BUNDLE_JAR=$(ls $HUDI_HOME/packaging/hudi-spark-bundle/target/hudi-spark*-bundle_*.jar)
export HUDI_UTILITIES_SLIM_JAR=$(ls $HUDI_HOME/packaging/hudi-utilities-slim-bundle/target/hudi-utilities-slim-bundle*.jar)

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
