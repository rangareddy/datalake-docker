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

| Application/Component             | URL                   | Other Details                                |
| --------------------- | --------------------- | -------------------------------------------- |
| Zookeeper             | http://localhost:2181 |                                              |
| Kafka Broker          | http://localhost:9092 |                                              |
| Kafka Schema Registry | http://localhost:8081 |                                              |
| Kafka Connector       | http://localhost:8083 |                                              |
| Debezium UI           | http://localhost:9081 |                                              |
| Kafka Connect REST API          | http://localhost:8082 |                                              |
| Graphite UI           | http://localhost:9083 |                                              |
| Kafka UI              | http://localhost:9082 |                                              |
| Postgres              | http://localhost:5432 | **Username:** postgres **Password**:postgres |
|Spark Master UI| http://localhost:8080 | |
|Spark Worker UI | http://localhost:8081| |


## Start the container

```sh
docker-compose -f docker-compose.yml up -d
docker-compose up --force-recreate --build -d
```

## Kafka Connect is up and running

```sh
$ curl -H "Accept:application/json" localhost:8083/
{"version":"3.3.1","commit":"e23c59d00e687ff5","kafka_cluster_id":"Z6t0i8sNT1W9-0eQ41gUPQ"}
```

## Create Connector using Kafka Connect

```sh
curl -X POST -H "Accept:application/json" -H "Content-Type:application/json" localhost:8083/connectors/ -d ‘
{
  "name": "inventory-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "tasks.max": "1",
    "database.hostname": "postgres",
    "database.port": "5432",
    "database.user": "postgres",
    "database.password": "postgres",
    "database.dbname": "inventory",
    "database.server.name": "dbserver1",
    "database.whitelist": "inventory",
    "database.history.kafka.bootstrap.servers": "kafka:9092",
    "database.history.kafka.topic": "schema-changes.inventory"
  }
}’
```

## Verify the Connector is created

```sh
curl -X GET -H “Accept:application/json” localhost:8083/connectors/inventory-connector
```

## Start a Kafka Console consumer to watch changes

```sh
docker run -it — name watcher — rm — link zookeeper:zookeeper debezium/kafka watch-topic -a -k dbserver1.public.dumb_table
```

## Register a connector to read from Postgres

```json
{
  "name": "pg_employees_connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "plugin.name": "pgoutput",
    "tasks.max": "1",
    "database.hostname": "postgres",
    "database.port": "5432",
    "database.user": "postgres",
    "database.password": "postgres",
    "database.dbname": "movies_db",
    "database.server.name": "postgres",
    "table.include.list": "public.movies",
    "database.history.kafka.bootstrap.servers": "kafka:9092",
    "database.history.kafka.topic": "schema-changes.movies",
    "topic.prefix": "postgres",
    "topic.creation.enable": "true",
    "topic.creation.default.replication.factor": "1",
    "topic.creation.default.partitions": "1",
    "topic.creation.default.cleanup.policy": "delete",
    "topic.creation.default.retention.ms": "604800000"
  }
}
```

`pg-source.json`

```json
{
    "name": "pg-source",
    "config": {
        "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
        "tasks.max": "1",
        "database.hostname": "postgres",
        "database.port": "5432",
        "database.user": "postgres",
        "database.password": "postgres",
        "database.dbname" : "postgres",
        "topic.prefix": "dbserver1",
        "schema.include.list": "inventory"
    }
}
```

To start the PostgreSQL connector instance:

```sh
curl -X POST -H "Content-Type: application/json" --data @pg-source-config.json http://localhost:9090/connectors
```

```json
{
  "name": "inventory-connector",
  "config": {
    "connector.class": "io.debezium.connector.mysql.MySqlConnector",
    "tasks.max": "1",
    "database.hostname": "mysql",
    "database.port": "3306",
    "database.user": "debezium",
    "database.password": "dbz",
    "database.server.id": "184054",
    "database.server.name": "dbserver1",
    "database.include.list": "inventory",
    "database.history.kafka.bootstrap.servers": "kafka:9092",
    "database.history.kafka.topic": "schema-changes.inventory"
  }
}
```

```sh
curl -i -X POST -H "Accept:application/json" -H "Content-Type:application/json" localhost:8083/connectors/ -d '{ "name": "inventory-connector", "config": { "connector.class": "io.debezium.connector.mysql.MySqlConnector", "tasks.max": "1", "database.hostname": "mysql", "database.port": "3306", "database.user": "debezium", "database.password": "dbz", "database.server.id": "184054", "database.server.name": "dbserver1", "database.include.list": "inventory", "database.history.kafka.bootstrap.servers": "kafkaIP:9092", "database.history.kafka.topic": "dbhistory.inventory" } }'

curl -H "Accept:application/json" localhost:8083/connectors/

curl -i -X GET -H "Accept:application/json" localhost:8083/connectors/inventory-connector
```

## Registering the connector

```sh
$ curl -s -X PUT -H "Accept:application/json" -H  "Content-Type:application/json" \
	http://localhost:8083/connector-plugins/io.debezium.connector.postgresql.PostgresConnector/config/validate -d @connect-config.json | jq

{
  "name": "io.debezium.connector.postgresql.PostgresConnector",
  "error_count": 0,
. . .
```

Once we are sure the configuration is valid, i.e. there is zero validation errors, we can submit the configuration to start Postgres connector

```sh
$ curl -i -X POST -H "Accept:application/json" -H  "Content-Type:application/json" http://localhost:8083/connectors/ -d @pg-source.json

{"name":"pg-source","config":{"connector.class":"io.debezium.connector.postgresql.PostgresConnector","tasks.max":"1","database.hostname":"postgres","database.port":"5432","database.user":"postgres","database.password":"postgres","database.dbname":"postgres","topic.prefix":"dbserver1","schema.include.list":"inventory","name":"pg-source"},"tasks":[],"type":"source"}
```

```sh
$ curl -H "Accept:application/json" localhost:8083/connectors/
["pg-source"]
```

Check that the connector is running

```sh
$ curl localhost:8083/connectors/pg-source/status
{"name":"pg-source","connector":{"state":"RUNNING","worker_id":"172.17.0.18:8083"},"tasks":[{"id":0,"state":"RUNNING","worker_id":"172.17.0.18:8083"}],"type":"source"}
```

## List of runing connectors

```sh
$ curl -H "Accept:application/json" localhost:8083/connectors/
[]
```

## Connect to Kafka Broker

```sh
docker exec -it broker bash
```

```sh
kafka-topics --list --bootstrap-server localhost:9092
```

## Connect to Postgres DB

```sh
docker exec -it postgres bash
```

```sh
psql -U your_admin_username -d your_database_name -h your_host
```

```sh
psql -U hive -d hive_metastore -W -h 127.0.0.1
```

**Connect to psql:**

```sh
psql -h postgres -U postgres -W
```

**List all databases:**

```sql
\l
```

**Connect to database:**

```sql
\c movies_db
```

**List database tables:**

```sql
\dt
```

**Describe a table:**

```sql
\d movies
```

**List all schemas:**

```sql
\dn
```

**List users and their roles:**

```sql
\du
```

**Run commands from a file:**

vi `psql_commands.txt`

```sh
\l
\dt
\du
```

```sh
psql \i psql_commands.txt
```

**Quit psql:**

```sql
\q
```

```sh
SHOW SEARCH_PATH;
SET search_path TO inventory;
```

```sh
\l - Display database
\c - Connect to database
\dn - List schemas
\dt - List tables inside public schemas
\dt schema1.* - List tables inside a particular schema.
                For example: 'schema1'.
```

## Create connectors via UI

### MySQL

Topic Prefix: inventory 
Cluster ID: 12345 
Hostname: db-mysql
User: debezium
Password: dbz
Kafka broker addresses: kafka:9092
Database schema history topic name: dbhistory.inventory

```sh
docker exec -it db-mysql bash -c 'mysql -u $MYSQL_USER -p$MYSQL_PASSWORD inventory'
```

### PostgreSQL

Topix prefix: fulfillment 
Hostname: db-pg
User: postgres
Password: postgres
Database:postgres

```sh
docker exec -it db-mysql bash -c 'mysql -u $MYSQL_USER -p$MYSQL_PASSWORD inventory'
```

## Examine the change events

```sh
docker exec -it kafka bash

./bin/kafka-console-consumer.sh --bootstrap-server kafka:9092 --topic [TOPIC_NAME] --from-beginning
```

```sh
#!/bin/bash
SPARK_MASTER="cas001-spark-master"

docker cp ./delte-lake-demo/. ${SPARK_MASTER}:/spark/examples
```


      SERVICE_OPTS: '-Djavax.jdo.option.ConnectionDriverName=org.postgresql.Driver
                     -Djavax.jdo.option.ConnectionURL=jdbc:postgresql://postgres:5432/hive_metastore
                     -Djavax.jdo.option.ConnectionUserName=hive
                     -Djavax.jdo.option.ConnectionPassword=hive'

--packages org.apache.hadoop:hadoop-aws:3.3.4

hive-metastore:
    container_name: hive-metastore
    restart: on-failure
    image: fredrikhgrelland/hive:${LAST_COMMIT_HASH}
    build:
      dockerfile: Dockerfile
      context: ..

docker build -f ./Dockerfile . -t 'waitingforcode_spark:v0.2_spark2.4.4'

!connect jdbc:hive2://localhost:10000/default

beeline -u 'jdbc:hive2://localhost:10000/'

https://github.com/apache/hive/blob/master/packaging/src/docker/build.sh

Airflow:

https://github.com/airscholar/e2e-data-engineering/blob/main/docker-compose.yml

Kafka
https://github.com/conduktor/kafka-stack-docker-compose/blob/master/zk-multiple-kafka-multiple-schema-registry.yml

https://github.com/1ambda/lakehouse/blob/master/docker-compose.yml

Flink
https://github.com/1ambda/lakehouse/blob/master/docker/flink/Dockerfile-flink1.16

## Docker images

```yaml
  debezium-ui:
    image: debezium/debezium-ui:${DEBEZIUM_UI_VERSION:-latest}
    platform: ${PLATFORM:-linux/amd64}
    container_name: debezium-ui
    hostname: debezium-ui
    restart: unless-stopped
    depends_on:
      kafka-connect:
        condition: service_healthy
    environment:
      KAFKA_CONNECT_URIS: http://kafka-connect:8083
    ports:
      - "9081:8080"
    healthcheck:
      test: nc -z localhost 8080 || exit 1
      start_period: 20s
      interval: 30s
      timeout: 30s
      retries: 5
    networks:
      - datalake

  trino:
    ports:
      - "8080:8080"
    image: "trinodb/trino:455"
    volumes:
      - ./conf/trino/catalog:/etc/trino/catalog

  hive-metastore:
    << : *apache-hive
    container_name: hive-metastore
    hostname: hive-metastore
    depends_on:
      postgres:
        condition: service_healthy
      minio:
        condition: service_healthy
    ports:
      - "9083:9083"
    volumes:
      - ./conf/hive/metastore-site.xml:/opt/hive/conf/hive-site.xml
    healthcheck:
      test: bash -c "exec 6<> /dev/tcp/localhost/9083"
      interval: 20s
      timeout: 20s
      retries: 3
    environment:
      DB_DRIVER: postgres
      SERVICE_NAME: 'metastore'
      VERBOSE: 'true'
      #HIVE_AUX_JARS_PATH: /opt/hadoop/share/hadoop/tools/lib/hadoop-aws-3.3.6.jar:/opt/hadoop/share/hadoop/tools/lib/aws-java-sdk-bundle-1.12.367.jar

- SPARK_LOG_CONF=/opt/bitnami/spark/conf/log4j2.properties

trino-coordinator:
    image: 'trinodb/trino:latest'
    hostname: trino-coordinator
    restart: always
    ports:
      - '8080:8080'
    volumes:
      - ./etc:/etc/trino
    networks:
      - trino-network

trino:
    profiles: [ "trino" ]
    container_name: trino
    hostname: trino
    image: "trinodb/trino:425"
    restart: always
    ports:
      - "8889:8889"
    volumes:
      - ./docker/trino/etc-coordinator:/etc/trino
      - ./docker/trino/catalog:/etc/trino/catalog
    depends_on:
      - hive-metastore

  trino-worker:
    profiles: [ "trino-worker" ]
    container_name: trino-worker
    hostname: trino-worker
    image: "trinodb/trino:425"
    restart: always
    volumes:
      - ./docker/trino/etc-worker:/etc/trino
      - ./docker/trino/catalog:/etc/trino/catalog
    depends_on:
      - trino

spark-history-server:
    container_name: spark-history-server
    image: owshq-spark-history-server:3.5
    environment:
      - SPARK_HISTORY_UI_PORT=18080
      - SPARK_DAEMON_MEMORY=5g
      - SPARK_HISTORY_RETAINEDAPPLICATIONS=100
      - SPARK_HISTORY_UI_MAXAPPLICATIONS=50
      - SPARK_HISTORY_STORE_MAXDISKUSAGE=20g
      - SPARK_HISTORY_FS_LOG_DIRECTORY=/opt/bitnami/spark/logs/events
      - SPARK_HISTORY_OPTS=-Dspark.history.fs.logDirectory=/opt/bitnami/spark/logs/events
      - SPARK_LOG_CONF=/opt/bitnami/spark/conf/log4j2.properties
    ports:
      - 18080:18080
      - 4040:4040
    volumes:
      - ${APP_LOG_PATH}:/opt/bitnami/spark/logs/events
    depends_on:
      - spark-master
      - spark-worker-1
      - spark-worker-2


# ElasticSearch
  elasticsearch:
    container_name: elasticsearch
    image: docker.elastic.co/elasticsearch/elasticsearch:7.14.0
    environment:
      - discovery.type=single-node
    ports:
      - "9200:9200"
    volumes:
      - es_data:/usr/share/elasticsearch/data

  # Kibana
  kibana:
    container_name: kibana
    image: docker.elastic.co/kibana/kibana:7.14.0
    ports:
      - "5601:5601"
    environment:
      - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
    depends_on:
      - elasticsearch

  # Logstash
  logstash:
    container_name: logstash
    image: docker.elastic.co/logstash/logstash:7.14.0
    ports:
      - "5044:5044"
    volumes:
      - ${APP_LOG_PATH}:/opt/bitnami/spark/logs/events
      - ${APP_LOGSTASH_PATH}:/usr/share/logstash/pipeline
    environment:
      - LS_JAVA_OPTS=-Xmx1g -Xms1g
    depends_on:
      - elasticsearch

trino:
    container_name: trino
    hostname: trino
    ports:
      - '8080:8080'
    image: 'trinodb/trino:418'
    volumes:
      - ./trino/catalog:/etc/trino/catalog
      - ./data:/home/data
      - ./trino/config/log.properties:/etc/trino/log.properties

grafana:
    image: grafana/grafana
    container_name: grafana
    restart: always
    ports:
      - 3000:3000
    networks:
      - grafana-net
    volumes:
      - grafana-volume

graphite:
    image: graphiteapp/graphite-statsd
    container_name: graphite
    restart: always
    networks:
      - grafana-net

networks:
  grafana-net:

  flink-sql-client:
    image: cnfldemos/flink-sql-client-kafka:1.16.0-scala_2.12-java11
    hostname: flink-sql-client
    container_name: flink-sql-client
    depends_on:
    - flink-jobmanager
    environment:
      FLINK_JOBMANAGER_HOST: flink-jobmanager
    volumes:
    - ./settings/:/settings

  flink-jobmanager:
    image: cnfldemos/flink-kafka:1.16.0-scala_2.12-java11
    hostname: flink-jobmanager
    container_name: flink-jobmanager
    ports:
    - 9081:9081
    command: jobmanager
    environment:
    - |
      FLINK_PROPERTIES=
      jobmanager.rpc.address: flink-jobmanager
      rest.bind-port: 9081

  flink-taskmanager:
    image: cnfldemos/flink-kafka:1.16.0-scala_2.12-java11
    hostname: flink-taskmanager
    container_name: flink-taskmanager
    depends_on:
    - flink-jobmanager
    command: taskmanager
    scale: 1
    environment:
    - |
      FLINK_PROPERTIES=
      jobmanager.rpc.address: flink-jobmanager
      taskmanager.numberOfTaskSlots: 10

    POSTGRES_USER: hue
    POSTGRES_PASSWORD: hue
    POSTGRES_DB: hue

    hue:
      image: gethue/hue:latest
      hostname: hue
      container_name: hue
      ports:
      - "8888:8888"
      volumes:
        - ./conf/hue/hue.ini:/usr/share/hue/desktop/conf/z-hue.ini
      depends_on:
      - "database"

  hue:
    image: gethue/hue:4.6.0
    container_name: hue
    environment:
      SERVICE_PRECONDITION: "namenode:9000 namenode:9870 datanode:9864 hive-metastore-postgresql:5432 hive-metastore:9083 hive-server:10000 resourcemanager:8088"
    ports:
      - "8888:8888"
    env_file:
      - ./hadoop.env
    volumes:
      - ./hue-overrides.ini:/usr/share/hue/desktop/conf/hue-overrides.ini
    depends_on:
      - huedb

  graphite:
    image: graphiteapp/graphite-statsd
    container_name: graphite
    hostname: graphite
    restart: always
    ports:
      - "2003-2004:2003-2004"
      - "2023-2024:2023-2024"
      - "5555:80"
    networks:
      - my_network
```

```sh
docker run -d \
    --name graphite \
    --restart=always \
    -p 2003-2004:2003-2004 \
    -p 2023-2024:2023-2024 \
    -p 9080:80 \
    -p 8125:8125/udp \
    -p 8126:8126 \
    graphiteapp/graphite-statsd
```

`vi postgres-debezium-connector.json`

```json
{
  "name": "postgres-debezium-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "tasks.max": "1",
    "plugin.name": "pgoutput",
    "database.hostname": "postgres",
    "database.port": "5432",
    "database.user": "postgres",
    "database.password": "postgres",
    "database.dbname": "test",
    "topic.prefix": "postgres",
    "database.server.name": "postgres",
    "schema.include.list": "public",
    "table.include.list": "public.employees",
    "publication.autocreate.mode": "filtered",
    "tombstones.on.delete": "false",
    "key.converter": "io.confluent.connect.avro.AvroConverter",
    "key.converter.schema.registry.url": "http://kafka-schema-registry:8081/",
    "value.converter": "io.confluent.connect.avro.AvroConverter",
    "value.converter.schema.registry.url": "http://kafka-schema-registry:8081/",
    "slot.name": "pgslot"
  }
}
```

```sh
docker exec -it kafka-connect bash

curl -s -X POST -H 'Accept: application/json' \
    -H "Content-Type:application/json" \
    -d @debezium-source-postgres.json http://localhost:8083/connectors/ | jq
```

`vi /tmp/my_hudi.properties`

```sh
bootstrap.servers=localhost:9092
auto.offset.reset=earliest
schema.registry.url=http://localhost:8081
hoodie.deltastreamer.schemaprovider.registry.url=http://localhost:8081/subjects/postgres.public.employees-value/versions/latest
hoodie.deltastreamer.source.kafka.value.deserializer.class=io.confluent.kafka.serializers.KafkaAvroDeserializer
hoodie.deltastreamer.source.kafka.topic=postgres.public.employees
hoodie.datasource.write.recordkey.field=id
hoodie.datasource.write.schema.allow.auto.evolution.column.drop=true
hoodie.datasource.write.keygenerator.class=org.apache.hudi.keygen.NonpartitionedKeyGenerator
hoodie.metrics.on=true
hoodie.metrics.reporter.type=GRAPHITE
hoodie.metrics.graphite.host=localhost
hoodie.metrics.graphite.port=2003
hoodie.metrics.graphite.metric.prefix=hudi_metrics
```

```sh
HUDI_HOME=/Users/rangareddy/ranga_work/apache/hudi
HUDI_UTILITIES_JAR=$(ls $HUDI_HOME/packaging/hudi-utilities-bundle/target/hudi-utilities-bundle*.jar | grep -v sources | grep -v tests)
spark-submit \
    --repositories http://packages.confluent.io/maven/,https://jitpack.io,https://dl.bintray.com/kotlin/kotlin-dev/,https://packages.confluent.io/maven/io/confluent/ \
    --packages io.confluent:kafka-protobuf-provider:7.5.4,io.confluent:kafka-json-schema-provider:7.5.4 \
    --class org.apache.hudi.utilities.deltastreamer.HoodieDeltaStreamer $HUDI_UTILITIES_JAR \
    --props /tmp/my_hudi.properties \
    --table-type MERGE_ON_READ \
    --op UPSERT \
    --target-base-path file:///tmp/debezium/postgres/employees \
    --target-table employees_cdc  \
    --source-class org.apache.hudi.utilities.sources.debezium.PostgresDebeziumSource \
    --source-ordering-field _event_lsn \
    --payload-class org.apache.hudi.common.model.debezium.PostgresDebeziumAvroPayload \
    --continuous \
    --min-sync-interval-seconds 60
```

org.apache.hudi.utilities.deltastreamer.ConfigurationHotUpdateStrategy

Re-init delta sync with new config properties:

## JmxMetricsReporter

```properties
hoodie.metrics.on=true
hoodie.metrics.reporter.type=JMX
hoodie.metrics.jmx.host=192.168.0.106
hoodie.metrics.jmx.port=4001
```

## MetricsGraphiteReporter

```properties
hoodie.metrics.on=true
hoodie.metrics.reporter.type=GRAPHITE
hoodie.metrics.graphite.host=192.168.0.106
hoodie.metrics.graphite.port=2003
hoodie.metrics.graphite.metric.prefix=<your metrics prefix>
```

```sh
hoodie.metrics.on -> True
hoodie.metadata.metrics.enable -> True
hoodie.metrics.executor.enable -> True
hoodie.metrics.reporter.type -> GRAPHITE
hoodie.metrics.graphite.host ->
hoodie.metrics.graphite.port -> 2003
hoodie.metrics.graphite.report.period.seconds -> 30
hoodie.metrics.graphite.metric.prefix -> test_prefix_demo_mor
```

## Datadog

```properties
hoodie.metrics.on=true
hoodie.metrics.reporter.type=DATADOG
```

## AWS CloudWatchReporter

```properties
hoodie.metrics.reporter.type=CLOUDWATCH
```

Static AWS credentials to be used can be configured using hoodie.aws.access.key, hoodie.aws.secret.key, hoodie.aws.session.token

```sh
spark-submit \
  --class org.apache.hudi.utilities.deltastreamer.HoodieDeltaStreamer $HUDI_UTILITIES_BUNDLE \
  --table-type COPY_ON_WRITE \
  --source-class org.apache.hudi.utilities.sources.JsonKafkaSource \
  --source-ordering-field ts \
  --target-base-path /user/hive/warehouse/stock_ticks_cow \
  --target-table stock_ticks_cow \
  --props /var/demo/config/kafka-source.properties \
  --schemaprovider-class org.apache.hudi.utilities.schema.FilebasedSchemaProvider
```

Default Installation:
    /opt/graphite

Graphite-Web:
    http://127.0.0.1:9080/
    http://localhost:81/account/login

```sh
GRAPHITE_CARBON_PAINTEXT_PORT=2003
GRAPHITE_SERVER=localhost
echo "test.bash.stats 42 `date +%s`" | nc ${GRAPHITE_SERVER} ${GRAPHITE_CARBON_PAINTEXT_PORT}
```

vi graphite_sar_monitor_system_devices_withpush.sh

```sh
#!/bin/bash
SAMPLING_INTERVAL=5 
GRAPHITE_SERVER="127.0.0.1"
GRAPHITE_CARBON_PAINTEXT_PORT=2003
LC_ALL=C \
  sar -d $SAMPLING_INTERVAL | \
    gawk -vhostname="$(hostname)"  '{
      if (NF == 10 && $2 != "DEV") {
        timestamp = systime();
        printf("%s.%s.rd_sec %s %d\n", hostname, $2, $4, timestamp);
        printf("%s.%s.wr_sec %s %d\n", hostname, $2, $5, timestamp);
        printf("%s.%s.await %s %d\n", hostname, $2, $8, timestamp);
        printf("%s.%s.util %s %d\n", hostname, $2, $10, timestamp);
      }
    }' | \
    nc ${GRAPHITE_SERVER} ${GRAPHITE_CARBON_PAINTEXT_PORT}
```

./graphite_sar_monitor_system_devices_withpush.sh


vi example_graphite_pickle.py

```python
#!/usr/bin/python

import re
import sys
import time
import socket
import pickle
import struct
import random
import range

DELAY              =  30
CARBON_SERVER      = '127.0.0.1'
CARBON_PICKLE_PORT = 2004

def get_random_load():
    """ Generates random load value """
    return random.sample(range(10,300), 3)

def get_memcache(gsock):
    data      = []
    lines     = []
    timestamp = int(time.time())

    for line in open('/proc/meminfo').readlines():

        bits = line.split()

        # We dont care about the pages.
        if len(bits) == 2:
            continue

        # remove the : from the metric name
        metric = bits[0]
        metric = metric.replace(':', '')

        # Covert the default kb into mb
        value = int(bits[1])
        value = value / 1024

        data.append(("testapp." + metric, (timestamp, value)))
        lines.append("testapp.%s %d %d" % (metric, value, timestamp))

        message = '\n'.join(lines) + '\n'
        print("Sending metrics to Graphite ...")
        print(message)

        # Send metrics
        package = pickle.dumps(data, 2)
        header  = struct.pack('!L', len(package))
        gsock.sendall(header + package)


def run_app(gsock):
    """ Starts the app and metrics collection """

    message = ""

    while True:

        now    = int(time.time())
        tuples = []
        lines  = []

        # Gather metrics
        load = get_random_load()
        for u in range(1, 5):
            # Format: (metric_name, (timestamp, value))
            tuples.append( ('testapp.count', (now, u)) )
            lines.append("testapp.count %d %d" % (u, now))
            
        message = '\n'.join(lines) + '\n'
        print("Sending metrics to Graphite ...")
        print(message)

        # Send metrics
        package = pickle.dumps(tuples)
        header  = struct.pack('!L', len(package))
        gsock.sendall(header + package)
        time.sleep(DELAY)


def main():
    """ Starts the app and its connection with Graphite """
    
    # Open Graphite connection
    gsock = socket.socket()
    try:
        gsock.connect( (CARBON_SERVER, CARBON_PICKLE_PORT) )
    except socket.error:
        # Check if carbon-cache.py is running
        raise SystemExit("Couldn't connect to %(server)s on port %(port)s" % {'server': CARBON_SERVER, 'port': CARBON_PICKLE_PORT})

    try:
        run_app(gsock)
        #get_memcache(gsock)
    except KeyboardInterrupt:
        gsock.close()
        sys.stderr.write("\nExiting on CTRL-c\n")
        sys.exit(0)

if __name__ == "__main__":
    main()
```

<value>jdbc:postgresql://postgres:5432/metastore_db?createDatabaseIfNotExist=true</value>

docker compose up --build -d

CREATE USER hive WITH PASSWORD 'hive';
CREATE DATABASE metastore;
GRANT ALL PRIVILEGES ON DATABASE metastore TO hive;

echo "CREATE DATABASE <HIVEDATABASE>;" | psql -U postgres
echo "CREATE USER <HIVEUSER> WITH PASSWORD '<HIVEPASSWORD>';" | psql -U postgres
echo "GRANT ALL PRIVILEGES ON DATABASE <HIVEDATABASE> TO <HIVEUSER>;" | psql -U postgres

!connect jdbc:hive2://hiveserver2:10000/default

export HIVE_AUX_JARS_PATH=/opt/hive/aux
mkdir -p $HIVE_AUX_JARS_PATH
ln -sf /opt/hadoop/share/hadoop/tools/lib/aws-java-sdk-bundle-1.12.367.jar /opt/hive/aux/aws-java-sdk-bundle.jar
ln -sf /opt/hadoop/share/hadoop/tools/lib/hadoop-aws-3.3.6.jar /opt/hive/aux/hadoop-aws.jar

/opt/hadoop/share/hadoop/tools/lib/aws-java-sdk-bundle-1.12.367.jar
/opt/hadoop/share/hadoop/tools/lib/hadoop-aws-3.3.6.jar

Access Key: Zps1uzU4BBQc85t4MgeE
Secret Key: KzXCMJvqd6ygtZGz1OUB56SdB7JO5oUAMVpjutbd

from pyspark import SparkContext, SparkConf, SQLContext
conf = (
    SparkConf()
    .setAppName("Spark minIO Test")
    .set("spark.hadoop.fs.s3a.endpoint", "http://localhost:9091")
    .set("spark.hadoop.fs.s3a.access.key", os.environ.get('minIO_ACCESS_KEY'))
    .set("spark.hadoop.fs.s3a.secret.key", os.environ.get('minIO_SECRET_KEY'))
    .set("spark.hadoop.fs.s3a.path.style.access", True)
    .set("spark.hadoop.fs.s3a.impl", "org.apache.hadoop.fs.s3a.S3AFileSystem")
)
sc = SparkContext(conf=conf).getOrCreate()
sqlContext = SQLContext(sc)

print(sc.wholeTextFiles('s3a://datalake/test.txt').collect())
# Returns: [('s3a://datalake/test.txt', 'Some text\nfor testing\n')]
path = "s3a://user-jitsejan/mario-colors-two/"
rdd = sc.parallelize([('Mario', 'Red'), ('Luigi', 'Green'), ('Princess', 'Pink')])
rdd.toDF(['name', 'color']).write.csv(path)

find . -name *aws*.jar 

beeline -u jdbc:hive2://hiveserver2:10000/default -n hive -p hive --verbose=true

docker-compose up -d --build --force-recreate 

#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
  CREATE USER hive WITH PASSWORD 'hive';
  CREATE DATABASE metastore;
  GRANT ALL PRIVILEGES ON DATABASE metastore TO hive;

  \c metastore

  \i /hive/hive-schema-2.3.0.postgres.sql
  \i /hive/hive-txn-schema-2.3.0.postgres.sql
  \i /hive/upgrade-2.3.0-to-3.0.0.postgres.sql
  \i /hive/upgrade-3.0.0-to-3.1.0.postgres.sql

  \pset tuples_only
  \o /tmp/grant-privs
SELECT 'GRANT SELECT,INSERT,UPDATE,DELETE ON "' || schemaname || '"."' || tablename || '" TO hive ;'
FROM pg_tables
WHERE tableowner = CURRENT_USER and schemaname = 'public';
  \o
  \i /tmp/grant-privs
EOSQL

psql –h postgres –U hive –d metastore

psql -h postgres -d metastore_db -U hive
docker volume rm $(docker volume ls -q)

test:
    [
      "CMD-SHELL",
      "pg_isready",
      "-U",
      "${POSTGRES_USER:-postgres}",
      "-c",
      "wal_level=logical",
    ]

docker-compose up -d --build

entrypoint: >
      /bin/sh -c "
      until (/usr/bin/mc config host add minio http://minio:9000 admin password); do
        echo '...waiting...' && sleep 1;
      done;
      /usr/bin/mc mb minio/warehouse;  # Create the warehouse bucket
      /usr/bin/mc policy set public minio/warehouse;  # Set bucket policy
      echo 'my content' > myfile.txt;
      /usr/bin/mc cp myfile.txt minio/warehouse;
      tail -f /dev/null
      "
      
## Hudi Spark-SQL

```sh
spark-sql \
--packages org.apache.hudi:hudi-spark3.5-bundle_2.12:0.15.0 \
--conf 'spark.serializer=org.apache.spark.serializer.KryoSerializer' \
--conf 'spark.sql.extensions=org.apache.spark.sql.hudi.HoodieSparkSessionExtension' \
--conf 'spark.sql.catalog.spark_catalog=org.apache.spark.sql.hudi.catalog.HoodieCatalog' \
--conf 'spark.kryo.registrator=org.apache.spark.HoodieSparkKryoRegistrar'
```

```sh
# Create a Kafka topic
kafka-topics --create --topic hudi-sink-topic --partitions 1 --replication-factor 1 --bootstrap-server localhost:9092
kafka-topics --list --bootstrap-server localhost:9092
```

`vi employees.avro'

```json
{
    "type": "record",
    "name": "Employee",
    "fields": [
      {
        "name": "id",
        "type": [
          "null",
          "long"
        ]
      },
      {
        "name": "name",
        "type": [
          "null",
          "string"
        ]
      },
      {
        "name": "age",
        "type": [
          "null",
          "int"
        ]
      },
      {
        "name": "salary",
        "type": [
          "null",
          "float"
        ]
      },
      {
        "name": "department",
        "type": [
          "null",
          "string"
        ]
      }
    ]
}
```

```sh
# Setup the schema registry
curl -s -X GET http://localhost:8081/subjects | jq
export KAFKA_TOPIC_NAME='hudi-sink-topic'
curl -s -X POST -H "Content-Type: application/vnd.schemaregistry.v1+json" --data '{"schema":"{\"type\":\"record\",\"name\":\"Employee\",\"fields\":[{\"name\":\"id\",\"type\":[\"null\",\"long\"]},{\"name\":\"name\",\"type\":[\"null\",\"string\"]},{\"name\":\"age\",\"type\":[\"null\",\"int\"]},{\"name\":\"salary\",\"type\":[\"null\",\"float\"]},{\"name\":\"department\",\"type\":[\"null\",\"string\"]}]}"}' http://localhost:8081/subjects/${KAFKA_TOPIC_NAME}/versions | jq
curl -s -X GET http://localhost:8081/subjects/${KAFKA_TOPIC_NAME}/versions/latest | jq
```

```sh
curl -s http://localhost:8083/connectors | jq
curl -s -X GET http://localhost:8083/connector-plugins | jq '.[].class' | grep 'HoodieSinkConnector'
```

`vi connect-distributed.properties`

```json
{
    "bootstrap.servers": "kafka:9092",
    "group.id": "hudi-connect-group",
    "connector.class": "org.apache.hudi.connect.HoodieSinkConnector",
    "tasks.max": "1",
    "errors.deadletterqueue.context.headers.enable": "false",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true",
    "errors.tolerance": "all",
    "offset.flush.interval.ms": "60000",
    "listeners": "HTTP://:8083",
    "header.converter": "org.apache.kafka.connect.storage.SimpleHeaderConverter",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter.schemas.enable": "false",
    "topics": "hudi-sink-topic",
    "hoodie.table.name": "hudi_sink_table",
    "hoodie.table.type": "COPY_ON_WRITE",
    "hoodie.base.path": "s3a:/warehouse/hudi_sink_table",
    "hoodie.datasource.transactional": "false",
    "hoodie.datasource.write.recordkey.field": "id",
    "hoodie.datasource.write.precombine.field" : "name",
    "hoodie.datasource.write.partitionpath.field": "department",
    "hoodie.schemaprovider.class": "org.apache.hudi.schema.SchemaRegistryProvider",
    "hoodie.streamer.schemaprovider.registry.url": "http://kafka-schema-registry:8081/subjects/hudi-sink-topic/versions/latest",
    "hoodie.kafka.commit.interval.secs": "60",
    "hoodie.meta.sync.enable": "true",
    "hoodie.meta.sync.classes": "org.apache.hudi.hive.HiveSyncTool",
    "hoodie.datasource.hive_sync.table": "hudi_sink_table",
    "hoodie.datasource.hive_sync.partition_fields": "department",
    "hoodie.datasource.hive_sync.partition_extractor_class": "org.apache.hudi.hive.MultiPartKeysValueExtractor",
    "hoodie.datasource.hive_sync.use_jdbc": "false",
    "hoodie.datasource.hive_sync.mode": "hms",
    "hive.metastore.uris": "thrift://hive-metastore:9083",
    "hive.metastore.client.socket.timeout": "1500s"
}
```

`vi stock_ticks.avsc`

```json
{
  "type":"record",
  "name":"stock_ticks",
  "fields":[{
     "name": "volume",
     "type": "long"
  }, {
     "name": "ts", 
     "type": "string"
  }, {
     "name": "symbol", 
     "type": "string"
  },{
     "name": "year", 
     "type": "int"
  },{
     "name": "month", 
     "type": "string"
  },{
     "name": "high", 
     "type": "double"
  },{
     "name": "low", 
     "type": "double"
  },{
     "name": "key", 
     "type": "string"
  },{
     "name": "date", 
     "type":"string"
  }, {
     "name": "close", 
     "type": "double"
  }, {
     "name": "open", 
     "type": "double"
  }, {
     "name": "day", 
     "type":"string"
  }
]}
```

```sh
curl -s -X DELETE http://localhost:8083/connectors/hudi-sink-connector

curl -i -X PUT -H  "Content-Type:application/json" \
    http://localhost:8083/connectors/hudi-sink-connector/config \
    -d '
{
    "bootstrap.servers": "kafka:29092",
    "connector.class": "org.apache.hudi.connect.HoodieSinkConnector",
    "group.id": "hudi-control-group",
    "tasks.max": "1",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter.schemas.enable": "false",
    "topics": "hudi-test-topic",
    "hoodie.table.name": "hudi-test-table",
    "hoodie.table.type": "MERGE_ON_READ",
    "hoodie.base.path": "file:///tmp/hoodie/hudi-test-table",
    "hoodie.datasource.write.recordkey.field": "volume",
    "hoodie.datasource.write.precombine.field" : "ts",
    "hoodie.datasource.write.partitionpath.field": "date",
    "hoodie.schemaprovider.class": "org.apache.hudi.schema.SchemaRegistryProvider",
    "hoodie.streamer.schemaprovider.registry.url": "http://kafka-schema-registry:8081/subjects/hudi-test-topic/versions/latest",
    "hoodie.kafka.commit.interval.secs": 60
}'
```

Load the connector. 

hudi-sink-connect.json

```json
{
    "name": "hudi-sink-connect",
    "config": {
        "bootstrap.servers": "kafka:29092",
        "connector.class": "org.apache.hudi.connect.HoodieSinkConnector",
        "group.id": "hudi-control-group",
        "tasks.max": "1",
        "key.converter": "org.apache.kafka.connect.storage.StringConverter",
        "value.converter": "org.apache.kafka.connect.storage.StringConverter",
        "value.converter.schemas.enable": "false",
        "topics": "hudi-test-topic",
        "hoodie.table.name": "hudi-test-topic",
        "hoodie.table.type": "MERGE_ON_READ",
        "hoodie.base.path": "file:///tmp/hoodie/hudi-test-topic",
        "hoodie.datasource.write.recordkey.field": "volume",
        "hoodie.datasource.write.partitionpath.field": "date",
        "hoodie.schemaprovider.class": "org.apache.hudi.schema.SchemaRegistryProvider",
        "hoodie.streamer.schemaprovider.registry.url": "http://kafka-schema-registry:8081/subjects/hudi-test-topic/versions/latest",
        "hoodie.kafka.commit.interval.secs": 60
    }
}
```

```sh
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type:application/json" \
  -H "Accept:application/json" \
  -d @hudi-sink-connect.json

curl http://localhost:8083/connectors/hudi-sink-connect/status
```

Update the configuration of the existing connector.

```sh
curl -s -X PUT -H 'Content-Type: application/json' --data @kafka-connect-scylladb.json http://localhost:8083/connectors/scylladb/config
```

```sh
kafka-avro-console-producer
--broker-list localhost:9092
--topic example
--property parse.key=true
--property key.schema='{"type":"record",name":"key_schema","fields":[{"name":"id","type":"int"}]}'
--property "key.separator=$"
--property value.schema='{"type":"record","name":"value_schema","fields":[{"name":"id","type":"int"},
{"name":"firstName","type":"string"},{"name":"lastName","type":"string"}]}'
{"id":1}${"id":1,"firstName":"first","lastName":"last"}
```

```json
{"volume":"","symbol":"MSFT","ts":"2018-08-31 09:30:00","month":"08","high":111.74,"low":111.55,"key":"MSFT_2018-08-31 09","year":2018,"date":"partition_0","close":111.72,"open":111.55,"day":"31"}
{"volume":"1","symbol":"AAPL","ts":"2018-08-31 09:30:00","month":"08","high":227.3101,"low":226.23,"key":"AAPL_2018-08-31 09","year":2018,"date":"partition_0","close":227.3101,"open":226.53,"day":"31"}
```

```sh
curl -s -X DELETE http://localhost:8083/connectors/hudi-sink-connector

curl -i -X PUT -H  "Content-Type:application/json" \
    http://localhost:8083/connectors/hudi-sink-connector/config \
    -d '{
            "bootstrap.servers": "kafka:29092",
            "group.id": "hudi-connect-group",
            "connector.class": "org.apache.hudi.connect.HoodieSinkConnector",
            "tasks.max": "1",
            "errors.deadletterqueue.context.headers.enable": "false",
            "errors.log.enable": "true",
            "errors.log.include.messages": "true",
            "errors.tolerance": "all",
            "offset.flush.interval.ms": "60000",
            "listeners": "HTTP://:8083",
            "header.converter": "org.apache.kafka.connect.storage.SimpleHeaderConverter",
            "key.converter": "org.apache.kafka.connect.storage.StringConverter",
            "value.converter": "org.apache.kafka.connect.json.JsonConverter",
            "key.converter.schemas.enable": "false",
            "value.converter.schemas.enable": "false",
            "topics": "hudi-sink-topic",
            "hoodie.table.name": "hudi_sink_table",
            "hoodie.table.type": "COPY_ON_WRITE",
            "hoodie.base.path": "s3a:/warehouse/hudi_sink_table",
            "hoodie.datasource.transactional": "false",
            "hoodie.datasource.write.recordkey.field": "id",
            "hoodie.datasource.write.precombine.field" : "name",
            "hoodie.datasource.write.partitionpath.field": "department",
            "hoodie.schemaprovider.class": "org.apache.hudi.schema.SchemaRegistryProvider",
            "hoodie.streamer.schemaprovider.registry.url": "http://kafka-schema-registry:8081/subjects/hudi-sink-topic/versions/latest",
            "hoodie.kafka.commit.interval.secs": "60",
            "hoodie.meta.sync.enable": "true",
            "hoodie.meta.sync.classes": "org.apache.hudi.hive.HiveSyncTool",
            "hoodie.datasource.hive_sync.table": "hudi_sink_table",
            "hoodie.datasource.hive_sync.partition_fields": "department",
            "hoodie.datasource.hive_sync.partition_extractor_class": "org.apache.hudi.hive.MultiPartKeysValueExtractor",
            "hoodie.datasource.hive_sync.use_jdbc": "false",
            "hoodie.datasource.hive_sync.mode": "hms",
            "hive.metastore.uris": "thrift://hive-metastore:9083",
            "hive.metastore.client.socket.timeout": "1500s"
        }'
```

```sh
curl -s http://localhost:8083/connectors/hudi-sink-connector/config| jq

curl -XPOST http://localhost:8083/connectors/connector_name/restart
curl -XPOST http://localhost:8083/connectors/connector_name/tasks/n/restart
```

```sh
jq -rc . sampledata.json | kafka-console-producer --broker-list localhost:9092 --topic hudi-sink-topic
kafka-console-producer --broker-list localhost:9092 --topic hudi-sink-topic--property value.serializer=custom.class.serialization.JsonSerializer 

kafka-console-producer --broker-list localhost:9092 --topic hudi-sink-topic
{"title":"The Matrix","year":1999,"cast":["Keanu Reeves","Laurence Fishburne","Carrie-Anne Moss","Hugo Weaving","Joe Pantoliano"],"genres":["Science Fiction"]}
```

```json
{"id":1,"name":"Ranga","age":35,"salary":15000.00,"department":"Engineering"}
```

```sh
{
    "name": "test-hudi-connector-1",
    "bootstrap.servers": "kafka:9092",
    "group.id": "hudi-connect-cluster",
    "connector.class": "org.apache.hudi.connect.HoodieSinkConnector",
    "errors.deadletterqueue.context.headers.enable": "false",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true",
    "header.converter": "org.apache.kafka.connect.storage.SimpleHeaderConverter",
    "hoodie.base.path": "s3:/warehouse/hudi_sync_connector/",
    "hoodie.datasource.transactional": "false",
    "hoodie.datasource.write.commit.interval": "30",
    "hoodie.datasource.write.operation": "upsert",
    "hoodie.datasource.write.partitionpath.field": "date",
    "hoodie.datasource.write.recordkey.field": "volume",
    "hoodie.insert.shuffle.parallelism": "2",
    "hoodie.bulkinsert.shuffle.parallelism": "2",
    "hoodie.upsert.shuffle.parallelism": "2",
    "hoodie.kafka.commit.interval.secs": "60",
    "hoodie.metadata.enable": "false",
    "hoodie.schemaprovider.class": "org.apache.hudi.schema.SchemaRegistryProvider",
    "hoodie.streamer.schemaprovider.registry.url": "http://schema-registry:8081/subjects/input-key/versions/latest",
    "hoodie.table.type": "COPY_ON_WRITE",
    "hoodie.table.name": "hudi_sync_connector",
    "topics": "input",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.storage.StringConverter",
    "key.converter.schemas.enable": "true",
    "value.converter.schemas.enable": "true"
}
```

```sh
#https://rmoff.net/2018/12/15/docker-tips-and-tricks-with-kafka-connect-ksqldb-and-kafka/
#https://www.confluent.io/hub/confluentinc/kafka-connect-hdfs3
#docker build . -t my-custom-image:1.0.0
#docker build -f ./Dockerfile.kafka_connect -t rangareddy1988/cp-kafka-connect:6.0.0_1.0.3_confluent .
#https://github.com/confluentinc/demo-scene/blob/master/kafka-connect-zero-to-hero/docker-compose.yml#L89-L101
#https://github.com/1ambda/lakehouse/blob/master/docker-compose.yml
#https://github.com/alberttwong/onehouse-demos/blob/main/hudi-spark-minio-trino/xtable.md
```

```sh
$ curl -sS localhost:8083/connector-plugins | jq .[].class | grep postgres 
"io.debezium.connector.postgresql.PostgresConnector"
```

```sh
curl -i -X POST -H "Accept:application/json" -H  "Content-Type:application/json" http://localhost:8083/connectors/ -d @register_inventory_employees_pg_connector.json
```

```sh
curl -X DELETE localhost:8083/connectors/inventory_employees_postgres_connector
```

