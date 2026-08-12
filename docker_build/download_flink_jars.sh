#!/bin/bash
set -euo pipefail # Enable strict error handling

# Define constants
CURRENT_DIR="$(
    cd "$(dirname "$0")"
    pwd -P
)"

FLINK_HOME=${FLINK_HOME:-$CURRENT_DIR}
FLINK_LIB="$FLINK_HOME/lib/"
# Flink 1.20 is the newest release all three table formats support together:
# Iceberg publishes iceberg-flink-runtime-1.20 (and stops at 1.6.1 for Flink 1.17),
# Hudi publishes hudi-flink1.20-bundle, and flink-sql-connector-hive has no Flink 2.x
# build at all, which the Hive Metastore catalogs depend on.
FLINK_VERSION=${FLINK_VERSION:-1.20.5}
FLINK_MAJOR_VERSION=${FLINK_MAJOR_VERSION:-1.20}
SCALA_VERSION=${SCALA_VERSION:-2.12}
HADOOP_VERSION=${HADOOP_VERSION:-3.3.4}
AWS_JAVA_SDK_VERSION=${AWS_JAVA_SDK_VERSION:-1.12.648}
KAFKA_VERSION=${KAFKA_VERSION:-3.4.0}
FLINK_CONNNECTOR_VERSION=${FLINK_CONNNECTOR_VERSION:-3.4.0-1.20}
MVN_URL=https://repo1.maven.org/maven2
APACHE_URL=$MVN_URL/org/apache
POSTGRES_JDBC_VERSION=${POSTGRES_JDBC_VERSION:-42.7.3}
MYSQL_CONNECTOR_JAVA_VERSION=${MYSQL_CONNECTOR_JAVA_VERSION:-8.0.29}
# Matches the Spark image. Iceberg 1.11.0 is compiled for Java 17, hence the java17
# base image in Dockerfile.flink.
ICEBERG_VERSION=${ICEBERG_VERSION:-1.11.0}
# Keep in sync with HUDI_VERSION in Dockerfile.flink: that Dockerfile also wgets the
# Hudi Flink bundle into lib/, so a mismatch leaves two bundle versions on the classpath.
# Held at 1.1.1, not 1.2.0: 1.2.0 relocates codahale metrics while keeping the
# org.apache.flink.dropwizard.metrics.* class names, which collides with Iceberg's copy.
# Those classes sit under a parent-first package, so lib/ always wins and passing the
# bundle with sql-client -j cannot work around it. With 1.2.0 present, whichever of
# Hudi/Iceberg loses the sort order fails its INSERT with NoSuchMethodError.
HUDI_VERSION=${HUDI_VERSION:-1.1.1}
# Matches the Spark image. delta-standalone_2.12 tops out at 3.3.2; delta-flink 4.x
# is built against Flink 2.0 and needs delta-kernel, not delta-standalone.
DELTA_VERSION=${DELTA_VERSION:-3.3.2}
SHAPELESS_VERSION=${SHAPELESS_VERSION:-2.3.4}
#HIVE_VERSION=${HIVE_VERSION:-3.1.3}
HIVE_VERSION=3.1.3

HUDI_DIR="$CURRENT_DIR/hudi"
USERNAME=$(whoami)
if [[ "$USERNAME" == *"ranga"* ]]; then
    HUDI_DIR="$HOME/ranga_work/apache/hudi"
fi

HUDI_TARGET_VERSION=$(echo "$HUDI_VERSION" | sed 's/\./_/g')
HUDI_TARGET_DIR="${HUDI_DIR}_${HUDI_TARGET_VERSION}"

mkdir -p "$FLINK_LIB"

# Hadoop jars
HADOOP_JARS=(
    "$APACHE_URL/hadoop/hadoop-client/$HADOOP_VERSION/hadoop-client-$HADOOP_VERSION.jar"
    "$APACHE_URL/hadoop/hadoop-common/$HADOOP_VERSION/hadoop-common-$HADOOP_VERSION.jar"
    "$APACHE_URL/hadoop/hadoop-auth/$HADOOP_VERSION/hadoop-auth-$HADOOP_VERSION.jar"
    "$APACHE_URL/hadoop/hadoop-hdfs-client/$HADOOP_VERSION/hadoop-hdfs-client-$HADOOP_VERSION.jar"
    "$APACHE_URL/hadoop/hadoop-hdfs/$HADOOP_VERSION/hadoop-hdfs-$HADOOP_VERSION.jar"
    "$APACHE_URL/hadoop/hadoop-mapreduce-client-core/$HADOOP_VERSION/hadoop-mapreduce-client-core-$HADOOP_VERSION.jar"
    "$APACHE_URL/hadoop/hadoop-aws/$HADOOP_VERSION/hadoop-aws-$HADOOP_VERSION.jar"
    "$MVN_URL/com/amazonaws/aws-java-sdk-bundle/$AWS_JAVA_SDK_VERSION/aws-java-sdk-bundle-$AWS_JAVA_SDK_VERSION.jar"
    "$APACHE_URL/hadoop/thirdparty/hadoop-shaded-guava/1.1.1/hadoop-shaded-guava-1.1.1.jar"
    "$APACHE_URL/commons/commons-configuration2/2.1.1/commons-configuration2-2.1.1.jar"
    "$MVN_URL/commons-logging/commons-logging/1.1.3/commons-logging-1.1.3.jar"
    "$MVN_URL/org/codehaus/woodstox/stax2-api/4.2.1/stax2-api-4.2.1.jar"
    "$MVN_URL/com/fasterxml/woodstox/woodstox-core/5.3.0/woodstox-core-5.3.0.jar"
)

# Flink Common jars
FLINK_COMMON_JARS=(
    "$APACHE_URL/flink/flink-parquet/$FLINK_VERSION/flink-parquet-$FLINK_VERSION.jar"
)

# Flink Kafka Connectors jars.
# The Kafka connector is released independently of Flink, so it is versioned
# <connector>-<flink-minor> (e.g. 3.4.0-1.20), not with the Flink patch version.
# There is no flink-sql-connector-kafka-1.20.5 on Maven Central.
KAFKA_JARS=(
    "$APACHE_URL/flink/flink-sql-connector-kafka/$FLINK_CONNNECTOR_VERSION/flink-sql-connector-kafka-$FLINK_CONNNECTOR_VERSION.jar"
    "$APACHE_URL/kafka/kafka-clients/$KAFKA_VERSION/kafka-clients-$KAFKA_VERSION.jar"
)

# JDBC Connector jars
JDBC_JARS=(
    "$APACHE_URL/flink/flink-connector-jdbc/${FLINK_CONNNECTOR_VERSION}/flink-connector-jdbc-${FLINK_CONNNECTOR_VERSION}.jar"
    "https://jdbc.postgresql.org/download/postgresql-${POSTGRES_JDBC_VERSION}.jar"
    "$MVN_URL/mysql/mysql-connector-java/${MYSQL_CONNECTOR_JAVA_VERSION}/mysql-connector-java-${MYSQL_CONNECTOR_JAVA_VERSION}.jar"
)

# Flink Hive Connector jars
# NOTE: do NOT add a raw hive-exec jar here. flink-sql-connector-hive is already an
# uber jar containing a relocated hive-exec, and the raw one bundles Parquet 1.10,
# which sorts ahead of the Hudi bundle on Flink's lib classpath and shadows Parquet
# 1.13. That surfaces as:
#   NoSuchMethodError: org.apache.parquet.schema.Types$PrimitiveBuilder.as(LogicalTypeAnnotation)
HIVE_JARS=(
    "$APACHE_URL/flink/flink-connector-hive_${SCALA_VERSION}/${FLINK_VERSION}/flink-connector-hive_${SCALA_VERSION}-${FLINK_VERSION}.jar"
    "$APACHE_URL/flink/flink-sql-connector-hive-${HIVE_VERSION}_${SCALA_VERSION}/$FLINK_VERSION/flink-sql-connector-hive-${HIVE_VERSION}_${SCALA_VERSION}-${FLINK_VERSION}.jar"
    "$MVN_URL/org/apache/thrift/libfb303/0.9.3/libfb303-0.9.3.jar"
    "$MVN_URL/org/antlr/antlr-runtime/3.5.2/antlr-runtime-3.5.2.jar"
)

# Flink Hudi Connector jars
HUDI_JARS=(
    "$MVN_URL/org/apache/calcite/calcite-core/1.10.0/calcite-core-1.10.0.jar"
)
if [ ! -d "$HUDI_TARGET_DIR" ]; then
    HUDI_JARS=(
        "$APACHE_URL/hudi/hudi-flink${FLINK_MAJOR_VERSION}-bundle/${HUDI_VERSION}/hudi-flink${FLINK_MAJOR_VERSION}-bundle-${HUDI_VERSION}.jar"
        "$MVN_URL/org/apache/calcite/calcite-core/1.10.0/calcite-core-1.10.0.jar"
    )
fi

# Flink Iceberg Connector jars
ICEBERG_JARS=(
    "$APACHE_URL/iceberg/iceberg-flink-runtime-$FLINK_MAJOR_VERSION/$ICEBERG_VERSION/iceberg-flink-runtime-$FLINK_MAJOR_VERSION-$ICEBERG_VERSION.jar"
)

# Flink Delta Connector jars
# NOTE: do NOT add flink-sql-parquet here. It ships its own copy of
# org.apache.parquet.avro.AvroSchemaConverter compiled against Flink's shaded Avro,
# and it sorts ahead of the Hudi bundle on Flink's lib classpath, so Hudi's call with
# its own shaded Avro Schema fails with:
#   NoSuchMethodError: AvroSchemaConverter.convert(org.apache.hudi.org.apache.avro.Schema)
# Delta does not need it; delta-standalone does need shapeless at runtime.
DELTA_JARS=(
    "$MVN_URL/io/delta/delta-storage/$DELTA_VERSION/delta-storage-$DELTA_VERSION.jar"
    "$MVN_URL/io/delta/delta-standalone_$SCALA_VERSION/$DELTA_VERSION/delta-standalone_$SCALA_VERSION-$DELTA_VERSION.jar"
    "$MVN_URL/io/delta/delta-flink/$DELTA_VERSION/delta-flink-$DELTA_VERSION.jar"
    "$MVN_URL/com/chuusai/shapeless_$SCALA_VERSION/$SHAPELESS_VERSION/shapeless_$SCALA_VERSION-$SHAPELESS_VERSION.jar"
)

ALL_JARS=("${KAFKA_JARS[@]}" "${JDBC_JARS[@]}" "${HIVE_JARS[@]}" "${HUDI_JARS[@]}" "${ICEBERG_JARS[@]}" "${DELTA_JARS[@]}")

# lib/ is gitignored and persists between runs, so jars from earlier builds accumulate:
# a Flink or connector version bump leaves the previous jar sitting next to the new one.
# Flink puts *every* jar in lib/ on the classpath, so a leftover is not inert; two Hudi
# bundles, or a stale Iceberg runtime, shadow each other's relocated classes and fail at
# runtime in order-dependent ways. Prune anything not in the expected set for this run.
expected_names=""
for url in "${ALL_JARS[@]}"; do
    expected_names="$expected_names $(basename "$url")"
done
for existing in "$FLINK_LIB"/*.jar; do
    [ -e "$existing" ] || continue
    name=$(basename "$existing")
    case " $expected_names " in
    *" $name "*) ;;
    *)
        echo "Removing stale jar: $name"
        rm -f "$existing"
        ;;
    esac
done

# A local Hudi source build, if present, supplies the Flink bundle instead of Maven.
if [ -d "$HUDI_TARGET_DIR" ]; then
    cp -r "$HUDI_TARGET_DIR"/packaging/hudi-flink-bundle/target/*.jar "$FLINK_LIB"
fi

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
