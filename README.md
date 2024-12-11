# Debezium Connector for PostgreSQL

## Apache Kafka

Apache Kafka is a messaging system that allows clients to publish and read streams of data (also called events). It has an ecosystem of open-source solutions that you can combine to store, process and integrate these data streams with other parts of your system in a secure, reliable and scalable way.

## Kafka Connect

To build integration solutions, you can use the Kafka Connect framework, which provides a suite of connectors to integrate Kafka with external systems. There are two types of Kafka connectors:

1. Source connector, used to move data from source systems to Kafka topics
2. Sink connector, used to send data from Kafka topics into the target (sink) system.

## Debezium

Debezium is a set of distributed services that capture row-level changes in your databases so that your applications can see and respond to those changes. Debezium records in a transaction log all row-level changes committed to each database table. Each application simply reads the transaction logs they’re interested in, seeing all the events in the same order they occur.

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
| Minio UI               | http://localhost:9001  |                                              |
| MySQL                  | http://localhost:3306  |                                              |

## Start the container

```sh
docker-compose up --force-recreate -d
```

## Connect to Postgres DB

```sh
$ docker exec -it postgres bash
# psql -h postgres -U postgres -W
postgres=#
postgres=# \l
postgres=# SHOW SEARCH_PATH;
postgres=# SET search_path TO inventory;
postgres=# \dt
postgres=# select * from employees;
```

## Kafka Connect is up and running

```sh
$ docker exec -it kafka-connect bash
```

```sh
$ curl -s -H "Accept:application/json" localhost:8083/ | jq
{
  "version": "7.4.7-ce",
  "commit": "75280b4ccc5d8be9",
  "kafka_cluster_id": "BlMYHQZ5TsmTiU0g7Btwow"
}
```

## Create Connector using Kafka Connect

```sh
$ curl -s localhost:8083/connectors/ | jq
[]
```

```sh
curl -X POST -H "Accept:application/json" -H "Content-Type:application/json" localhost:8083/connectors/ -d @/opt/data/connectors/register_inventory_employees_pg_connector.json
```

## Verify the Connector is created

```sh
curl -s -X GET http://localhost:8083/connectors/inventory_employees_postgres_connector | jq
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

Check that the connector is running

```sh
$ curl -s -X GET http://localhost:8083/connectors/inventory_employees_postgres_connector/status | jq
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

```sh
% docker exec -it kafka bash

$ kafka-topics --list --bootstrap-server localhost:9092 | grep fulfillment
fulfillment.inventory.employees

$ kafka-console-consumer --bootstrap-server localhost:9092 --topic fulfillment.inventory.employees --from-beginning
```

## Connect to Spark

```sh
% docker exec -it spark-master bash
```

`vi /tmp/my_hudi.properties`

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
hoodie.metrics.on=true
hoodie.metrics.reporter.type=GRAPHITE
hoodie.metrics.graphite.host=graphite
hoodie.metrics.graphite.port=2003
hoodie.metrics.graphite.metric.prefix=hudi_metrics
```

```sh
export HUDI_UTILITIES_JAR=$(ls $HUDI_HOME/packaging/hudi-utilities-bundle/target/hudi-utilities-bundle*.jar)

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

```sql
insert into employees values(2, 'Nishanth', 7, 300000, 'Software');
insert into employees values(3, 'Reddy', 60, 350000, 'Hardware');
```

```sh
export HUDI_SPARK_BUNDLE_JAR=$(ls $HUDI_HOME/packaging/hudi-spark-bundle/target/hudi-spark*-bundle_*.jar)

spark-shell \
--jars $HUDI_SPARK_BUNDLE_JAR \
--conf 'spark.serializer=org.apache.spark.serializer.KryoSerializer' \
--conf 'spark.sql.catalog.spark_catalog=org.apache.spark.sql.hudi.catalog.HoodieCatalog' \
--conf 'spark.sql.extensions=org.apache.spark.sql.hudi.HoodieSparkSessionExtension' \
--conf 'spark.kryo.registrator=org.apache.spark.HoodieSparkKryoRegistrar'
```

```scala
val basePath = "s3a://warehouse/employees_cdc"
val employeesDF = spark.read.format("hudi").load(basePath)
employeesDF.show(truncate=false)
```

