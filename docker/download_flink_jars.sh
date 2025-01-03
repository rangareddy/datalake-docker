#!/bin/bash
set -euo pipefail # Enable strict error handling

# Define constants
CURRENT_DIR="$(
    cd "$(dirname "$0")"
    pwd -P
)"

FLINK_LIB="$CURRENT_DIR/flink-lib"
FLINK_VERSION=${FLINK_VERSION:-1.17.2}
FLINK_MAJOR_VERSION=${FLINK_MAJOR_VERSION:-1.17}
SCALA_VERSION=${SCALA_VERSION:-2.12}
HADOOP_VERSION=${HADOOP_VERSION:-3.3.4}
AWS_JAVA_SDK_VERSION=${AWS_JAVA_SDK_VERSION:-1.12.648}
KAFKA_VERSION=${KAFKA_VERSION:-3.4.0}
FLINK_CONNNECTOR_VERSION=${FLINK_CONNNECTOR_VERSION:-3.1.0-1.17}
MVN_URL=https://repo1.maven.org/maven2
APACHE_URL=$MVN_URL/org/apache
POSTGRES_JDBC_VERSION=${POSTGRES_JDBC_VERSION:-42.7.3}
MYSQL_CONNECTOR_JAVA_VERSION=${MYSQL_CONNECTOR_JAVA_VERSION:-8.0.29}
ICEBERG_VERSION=${ICEBERG_VERSION:-1.5.2}
HUDI_VERSION=${HUDI_VERSION:-1.0.0}
DELTA_VERSION=${DELTA_VERSION:-3.2.0}
#HIVE_VERSION=${HIVE_VERSION:-3.1.3}
HIVE_VERSION=3.1.3

mkdir -p "$FLINK_LIB"

HADOOP_JARS=(
    "$APACHE_URL/hadoop/hadoop-client/$HADOOP_VERSION/hadoop-client-$HADOOP_VERSION.jar"
    "$APACHE_URL/hadoop/hadoop-common/$HADOOP_VERSION/hadoop-common-$HADOOP_VERSION.jar"
    "$APACHE_URL/hadoop/hadoop-auth/$HADOOP_VERSION/hadoop-auth-$HADOOP_VERSION.jar"
    "$APACHE_URL/hadoop/hadoop-hdfs-client/$HADOOP_VERSION/hadoop-hdfs-client-$HADOOP_VERSION.jar"
    "$APACHE_URL/hadoop/hadoop-mapreduce-client-core/$HADOOP_VERSION/hadoop-mapreduce-client-core-$HADOOP_VERSION.jar"
    "$APACHE_URL/hadoop/hadoop-aws/$HADOOP_VERSION/hadoop-aws-$HADOOP_VERSION.jar"
    "$MVN_URL/com/amazonaws/aws-java-sdk-bundle/$AWS_JAVA_SDK_VERSION/aws-java-sdk-bundle-$AWS_JAVA_SDK_VERSION.jar"
    "$APACHE_URL/hadoop/thirdparty/hadoop-shaded-guava/1.1.1/hadoop-shaded-guava-1.1.1.jar"
    "$APACHE_URL/commons/commons-configuration2/2.1.1/commons-configuration2-2.1.1.jar"
    "$MVN_URL/commons-logging/commons-logging/1.1.3/commons-logging-1.1.3.jar"
    "$MVN_URL/org/codehaus/woodstox/stax2-api/4.2.1/stax2-api-4.2.1.jar"
    "$MVN_URL/com/fasterxml/woodstox/woodstox-core/5.3.0/woodstox-core-5.3.0.jar"
    "$APACHE_URL/flink/flink-s3-fs-hadoop/$FLINK_VERSION/flink-s3-fs-hadoop-$FLINK_VERSION.jar"
)

KAFKA_JARS=(
    "$APACHE_URL/flink/flink-connector-kafka/$FLINK_VERSION/flink-connector-kafka-$FLINK_VERSION.jar"
    "$APACHE_URL/flink/flink-sql-connector-kafka/$FLINK_VERSION/flink-sql-connector-kafka-$FLINK_VERSION.jar"
    "$APACHE_URL/kafka/kafka-clients/$KAFKA_VERSION/kafka-clients-$KAFKA_VERSION.jar"
)

JDBC_JARS=(
    "$APACHE_URL/flink/flink-connector-jdbc/${FLINK_CONNNECTOR_VERSION}/flink-connector-jdbc-${FLINK_CONNNECTOR_VERSION}.jar"
    "https://jdbc.postgresql.org/download/postgresql-${POSTGRES_JDBC_VERSION}.jar"
    "$MVN_URL/mysql/mysql-connector-java/${MYSQL_CONNECTOR_JAVA_VERSION}/mysql-connector-java-${MYSQL_CONNECTOR_JAVA_VERSION}.jar"
)

HIVE_JARS=(
    "$APACHE_URL/flink/flink-connector-hive_${SCALA_VERSION}/${FLINK_VERSION}/flink-connector-hive_${SCALA_VERSION}-${FLINK_VERSION}.jar"
    "$APACHE_URL/flink/flink-sql-connector-hive-${HIVE_VERSION}_${SCALA_VERSION}/$FLINK_VERSION/flink-sql-connector-hive-${HIVE_VERSION}_${SCALA_VERSION}-${FLINK_VERSION}.jar"
    "$APACHE_URL/hive/hive-exec/${HIVE_VERSION}/hive-exec-${HIVE_VERSION}.jar"
)

HUDI_JARS=(
    "$APACHE_URL/hudi/hudi-flink${FLINK_MAJOR_VERSION}-bundle/${HUDI_VERSION}/hudi-flink${FLINK_MAJOR_VERSION}-bundle-${HUDI_VERSION}.jar"
)

ICEBERG_JARS=(
    "$APACHE_URL/iceberg/iceberg-flink-runtime-$FLINK_MAJOR_VERSION/$ICEBERG_VERSION/iceberg-flink-runtime-$FLINK_MAJOR_VERSION-$ICEBERG_VERSION.jar"
)

DELTA_JARS=(
    "$MVN_URL/io/delta/delta-storage/$DELTA_VERSION/delta-storage-$DELTA_VERSION.jar"
    "$MVN_URL/io/delta/delta-standalone_$SCALA_VERSION/$DELTA_VERSION/delta-standalone_$SCALA_VERSION-$DELTA_VERSION.jar"
    "$MVN_URL/io/delta/delta-flink/$DELTA_VERSION/delta-flink-$DELTA_VERSION.jar"
    "$APACHE_URL/flink/flink-sql-parquet/$FLINK_VERSION/flink-sql-parquet-$FLINK_VERSION.jar"
)

ALL_JARS=("${HADOOP_JARS[@]}" "${KAFKA_JARS[@]}" "${JDBC_JARS[@]}" "${HIVE_JARS[@]}" "${HUDI_JARS[@]}" "${ICEBERG_JARS[@]}" "${DELTA_JARS[@]}")

# Download all JARs
for url in "${ALL_JARS[@]}"; do
    filename=$(basename "$url")     # Extract filename from URL
    filepath="$FLINK_LIB/$filename" # Construct full filepath
    if [[ ! -f "$filepath" ]]; then # Check if file exists
        echo "Downloading: $url"
        wget -P "$FLINK_LIB" "$url"
        if [[ $? -ne 0 ]]; then # Check wget exit code for errors
            echo "Error downloading $url"
        fi
    fi
done
