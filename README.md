# Datalake Playground Docker

## Start all the services

To start the all services, use the following command:

```sh
% docker-compose up -d
```

## Components

| Application/Component  | URL                    | Other Details                                |
| ---------------------- | ---------------------- | -------------------------------------------- |
| Zookeeper              | http://localhost:2181  |                                              |
| Kafka Broker           | http://localhost:9092  |                                              |
| Kafka Schema Registry  | http://localhost:8081  |                                              |
| Kafka Connector        | http://localhost:8083  |                                              |
| Debezium UI            | http://localhost:9081  |                                              |
| Kafka Connect REST API | http://localhost:8082  |                                              |
| Graphite UI            | http://localhost:5555  |                                              |
| Kafka UI               | http://localhost:9082  |                                              |
| Postgres               | http://localhost:5432  | **Username:** postgres **Password**:postgres |
| Spark Master UI        | http://localhost:8080  |                                              |
| Spark Worker UI        | http://localhost:18081 |                                              |
| Trino UI               | http://localhost:9084  |                                              |
| Minio UI               | http://localhost:9001  | **Username:** admin **Password**:password    |
| MySQL                  | http://localhost:3306  | **Username:** admin **Password**:password    |

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
curl -X POST -H "Accept:application/json" -H "Content-Type:application/json" localhost:8083/connectors/ -d @/opt/data/connectors/register_inventory_employees_pg_connector.json
```

## Verify the Connector is Created

To verify that the connector has been created successfully, run:

```sh
curl -s -X GET http://localhost:8083/connectors/inventory_employees_postgres_connector | jq
```

You should see output similar to:

```json
{
  "name": "inventory_employees_postgres_connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "publication.autocreate.mode": "filtered",
    "database.user": "postgres",
    "database.dbname": "postgres",
    "slot.name": "debezium",
    "publication.name": "dbz_publication",
    "database.server.name": "postgres",
    "schema.include.list": "inventory",
    "plugin.name": "pgoutput",
    "database.port": "5432",
    "tombstones.on.delete": "false",
    "value.converter.schema.registry.url": "http://kafka-schema-registry:8081/",
    "topic.prefix": "fulfillment",
    "database.hostname": "postgres",
    "database.password": "postgres",
    "name": "inventory_employees_postgres_connector",
    "value.converter": "io.confluent.connect.avro.AvroConverter",
    "key.converter": "io.confluent.connect.avro.AvroConverter",
    "key.converter.schema.registry.url": "http://kafka-schema-registry:8081/"
  },
  "tasks": [
    {
      "connector": "inventory_employees_postgres_connector",
      "task": 0
    }
  ],
  "type": "source"
}
```

To check that the connector is running, execute:

```sh
$ curl -s -X GET http://localhost:8083/connectors/inventory_employees_postgres_connector/status | jq
```

```json
{
  "name": "inventory_employees_postgres_connector",
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
$ kafka-topics --list --bootstrap-server localhost:9092 | grep fulfillment
```

You should see:

```sh
fulfillment.inventory.employees
```

To consume messages from the topic, use:

```sh
$ kafka-console-consumer --bootstrap-server localhost:9092 --topic fulfillment.inventory.employees --from-beginning
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
hoodie.deltastreamer.schemaprovider.registry.url=http://kafka-schema-registry:8081/subjects/fulfillment.inventory.employees-value/versions/latest
hoodie.deltastreamer.source.kafka.value.deserializer.class=io.confluent.kafka.serializers.KafkaAvroDeserializer
hoodie.deltastreamer.source.kafka.topic=fulfillment.inventory.employees
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

```sql

```

`vi /opt/data/connectors/register_employees_pg_connector.json`

```json
{
  "name": "employees_postgres_connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "plugin.name": "pgoutput",
    "slot.name": "debezium",
    "database.hostname": "postgres",
    "database.port": "5432",
    "database.user": "postgres",
    "database.password": "postgres",
    "database.dbname": "postgres",
    "topic.prefix": "fulfillment",
    "database.server.name": "postgres",
    "schema.include.list" : "public",
    "table.include.list" : "public.employee1,public.employee2",
    "publication.autocreate.mode": "filtered",
    "tombstones.on.delete": "false",
    "key.converter": "io.confluent.connect.avro.AvroConverter",
    "key.converter.schema.registry.url": "http://kafka-schema-registry:8081/",
    "value.converter": "io.confluent.connect.avro.AvroConverter",
    "value.converter.schema.registry.url": "http://kafka-schema-registry:8081/"
  }
}
```

```sh
curl -X POST \
  -H "Accept:application/json" \
  -H "Content-Type:application/json" \
  localhost:8083/connectors/ \
  -d @/opt/data/connectors/register_employees_pg_connector.json
```

`mkdir -p /opt/hudi-streamer-conf/{multi-table-conf,multi-table-stream-conf,spark-conf}`


`vi /opt/hudi-streamer-conf/multi-table-conf/common.properties`

```properties
hoodie.datasource.write.hive_style_partitioning=true
hoodie.datasource.write.keygenerator.class=org.apache.hudi.keygen.ComplexKeyGenerator
hoodie.datasource.hive_sync.use_jdbc=false
hoodie.datasource.hive_sync.partition_extractor_class=org.apache.hudi.hive.MultiPartKeysValueExtractor
```

`vi /opt/hudi-streamer-conf/multi-table-conf/default_employee1_config.properties`

```properties
include=/opt/hudi-streamer-conf/multi-table-conf/common.properties
hoodie.datasource.write.recordkey.field=id
hoodie.datasource.write.partitionpath.field=department
hoodie.datasource.write.hive_style_partitioning=true

hoodie.datasource.meta.sync.enable=true
hoodie.datasource.hive_sync.enable=true
hoodie.datasource.hive_sync.mode=hms
hoodie.datasource.hive_sync.metastore.uris=thrift://hive-metastore:9083
hoodie.datasource.hive_sync.database=default
hoodie.datasource.hive_sync.table=employee_table1
hoodie.datasource.hive_sync.partition_extractor_class=org.apache.hudi.hive.MultiPartKeysValueExtractor

#hoodie.streamer.source.kafka.value.deserializer.class=io.confluent.kafka.serializers.KafkaAvroDeserializer
#hoodie.streamer.ingestion.targetBasePath=s3a://warehouse/default_employee_table1/

hoodie.streamer.source.kafka.topic=fulfillment.public.employee_table1
hoodie.streamer.schemaprovider.registry.url=http://kafka-schema-registry:8081/subjects/fulfillment.public.employee_table1-value/versions/latest
hoodie.streamer.source.dfs.root=s3a://warehouse/default_employee_table1/

bootstrap.servers=kafka:29092
auto.offset.reset=earliest
group.id=multi-table-group
schema.registry.url=http://kafka-schema-registry:8081
```

`vi /opt/hudi-streamer-conf/multi-table-conf/default_employee2_config.properties`

```properties
hoodie.datasource.write.recordkey.field=id
hoodie.datasource.write.partitionpath.field=department
hoodie.datasource.write.hive_style_partitioning=true

hoodie.datasource.meta.sync.enable=true
hoodie.datasource.hive_sync.enable=true
hoodie.datasource.hive_sync.mode=hms
hoodie.datasource.hive_sync.metastore.uris=thrift://hive-metastore:9083
hoodie.datasource.hive_sync.database=default
hoodie.datasource.hive_sync.table=employee_table2
hoodie.datasource.hive_sync.partition_extractor_class=org.apache.hudi.hive.MultiPartKeysValueExtractor

#hoodie.streamer.source.kafka.value.deserializer.class=io.confluent.kafka.serializers.KafkaAvroDeserializer
#hoodie.streamer.ingestion.targetBasePath=s3a://warehouse/default_employee_table2/

hoodie.streamer.source.kafka.topic=fulfillment.public.employee_table2
hoodie.streamer.schemaprovider.registry.url=http://kafka-schema-registry:8081/subjects/fulfillment.public.employee_table2-value/versions/latest
hoodie.streamer.source.dfs.root=s3a://warehouse/default_employee_table2/
```

`vi /opt/hudi-streamer-conf/multi-table-stream-conf/hudi-multi-table-stream-conf.properties`

```properties
# Kafka Properties
bootstrap.servers=kafka:29092
auto.offset.reset=earliest
schema.registry.url=http://kafka-schema-registry:8081

# Hudi Streamer Properties
hoodie.streamer.schemaprovider.registry.baseUrl=http://kafka-schema-registry:8081/subjects/
hoodie.streamer.schemaprovider.registry.sourceUrlSuffix=-value/versions/latest
hoodie.streamer.schemaprovider.registry.targetUrlSuffix=-value/versions/latest

#hoodie.streamer.schemaprovider.registry.url=http://kafka-schema-registry:8081/subjects/random-value/versions/latest
#hoodie.streamer.schemaprovider.registry.targetUrl=http://kafka-schema-registry:8081/subjects/random-value/versions/latest

hoodie.streamer.ingestion.tablesToBeIngested=default.employee_table1,default.employee_table2
#hoodie.streamer.ingestion.default.employee_table1.configFile=file:///opt/hudi-streamer-conf/multi-table-conf/table1_config.properties
#hoodie.streamer.ingestion.default.employee_table2.configFile=file:///opt/hudi-streamer-conf/multi-table-conf/table2_config.properties

# Hudi Writer Properties
hoodie.datasource.write.keygenerator.class=org.apache.hudi.keygen.ComplexKeyGenerator
hoodie.datasource.write.drop.partition.columns=false
```

```sh
export HUDI_UTILITIES_JAR=$(ls $HUDI_HOME/packaging/hudi-utilities-bundle/target/hudi-utilities-bundle*.jar)
#export HUDI_UTILITIES_JAR=$(ls $HUDI_HOME/packaging/hudi-utilities-slim-bundle/target/hudi-utilities-slim-bundle*.jar)
```

```sh
spark-submit \
  --class org.apache.hudi.utilities.streamer.HoodieMultiTableStreamer $HUDI_UTILITIES_JAR \
  --props file:///opt/hudi-streamer-conf/multi-table-stream-conf/hudi-multi-table-stream-conf.properties \
  --config-folder file:///opt/hudi-streamer-conf/multi-table-conf \
  --schemaprovider-class org.apache.hudi.utilities.schema.SchemaRegistryProvider \
  --source-class org.apache.hudi.utilities.sources.debezium.PostgresDebeziumSource \
  --payload-class org.apache.hudi.common.model.debezium.PostgresDebeziumAvroPayload \
  --base-path-prefix s3a://warehouse/multi-table/ \
  --source-ordering-field _event_lsn \
  --table-type COPY_ON_WRITE \
  --enable-sync \
  --op UPSERT \
  --source-limit 4000000 \
  --min-sync-interval-seconds 60
```

```sh
spark-submit \
  --conf spark.serializer=org.apache.spark.serializer.KryoSerializer \
  --conf spark.sql.hive.convertMetastoreParquet=false \
  --class org.apache.hudi.utilities.streamer.HoodieMultiTableStreamer $HUDI_UTILITIES_JAR \
  --props file:///opt/hudi_streamer/hudi_multi_table_stream.properties \
  --config-folder file:///opt/hudi_streamer/ \
  --schemaprovider-class org.apache.hudi.utilities.schema.SchemaRegistryProvider \
  --source-class org.apache.hudi.utilities.sources.debezium.PostgresDebeziumSource \
  --payload-class org.apache.hudi.common.model.debezium.PostgresDebeziumAvroPayload \
  --base-path-prefix s3a://warehouse/multi-table/ \
  --source-ordering-field _event_lsn \
  --table-type COPY_ON_WRITE \
  --enable-sync \
  --op UPSERT \
  --source-limit 4000000 \
  --min-sync-interval-seconds 60
```

```sh
export HUDI1_UTILITIES_JAR=$(ls /opt/hudi_1_0_0//packaging/hudi-utilities-bundle/target/hudi-utilities-bundle*.jar)
#export HUDI1_UTILITIES_JAR=$(ls /opt/hudi_1_0_0//packaging/hudi-utilities-slim-bundle/target/*.jar)
```

```sh
spark-submit \
  --class org.apache.hudi.utilities.streamer.HoodieMultiTableStreamer $HUDI1_UTILITIES_JAR \
  --props file:///opt/hudi_streamer/hudi_multi_table_stream.properties \
  --config-folder file:///opt/hudi_streamer/ \
  --schemaprovider-class org.apache.hudi.utilities.schema.SchemaRegistryProvider \
  --source-class org.apache.hudi.utilities.sources.debezium.PostgresDebeziumSource \
  --payload-class org.apache.hudi.common.model.debezium.PostgresDebeziumAvroPayload \
  --base-path-prefix s3a://warehouse/multi-table/ \
  --source-ordering-field _event_lsn \
  --table-type COPY_ON_WRITE \
  --enable-sync \
  --op UPSERT \
  --source-limit 4000000 \
  --min-sync-interval-seconds 60
```