#!/bin/bash
set -e

# Define constants
CURRENT_DIR="$(
  cd "$(dirname "$0")"
  pwd -P
)"
DOCKER_HUB_USERNAME="rangareddy1988"
HIVE_VERSION=${HIVE_VERSION:-4.0.0}
SPARK_VERSION=${SPARK_VERSION:-3.5.5}
SCALA_VERSION=${SCALA_VERSION:-2.12}
KAFKA_CONNECT_VERSION=${KAFKA_CONNECT_VERSION:-7.4.7}
CONFLUENT_KAFKACAT_VERSION=${CONFLUENT_KAFKACAT_VERSION:-7.1.15}
HADOOP_AWS_JARS_PATH="$CURRENT_DIR/hadoop-s3-jars"
DB_CONNECTOR_JARS_PATH="$CURRENT_DIR/db_connector_jars"
SOFTWARE_PATH="$CURRENT_DIR/software"
TRINO_VERSION=${TRINO_VERSION:-460}
JUPYTER_VERSION=${JUPYTER_VERSION:-latest}
XTABLE_VERSION=${XTABLE_VERSION:-0.3.0}
FLINK_VERSION=${FLINK_VERSION:-1.17.2}
HADOOP_VERSION=${HADOOP_VERSION:-3.3.4}
MVN_REPO_URL="https://repo1.maven.org/maven2"

# shellcheck source=/dev/null
source $CURRENT_DIR/validate_docker_status.sh

download_hadoop_aws_jars() {
  mkdir -p "$HADOOP_AWS_JARS_PATH"
  if [ ! -f "$HADOOP_AWS_JARS_PATH"/aws-java-sdk-bundle-1.12.262.jar ]; then
    wget -P "$HADOOP_AWS_JARS_PATH" https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.12.262/aws-java-sdk-bundle-1.12.262.jar
  fi

  if [ ! -f "$HADOOP_AWS_JARS_PATH"/hadoop-aws-${HADOOP_VERSION}.jar ]; then
    wget -P "$HADOOP_AWS_JARS_PATH" https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_VERSION}/hadoop-aws-${HADOOP_VERSION}.jar
  fi
}

download_db_connector_jars() {
  mkdir -p "$DB_CONNECTOR_JARS_PATH"
  POSTGRES_JDBC_VERSION=${POSTGRES_JDBC_VERSION:-42.7.3}
  MYSQL_CONNECTOR_JAVA_VERSION=${MYSQL_CONNECTOR_JAVA_VERSION:-8.0.29}

  if [ ! -f "$DB_CONNECTOR_JARS_PATH/postgresql-$POSTGRES_JDBC_VERSION.jar" ]; then
    wget -P "$DB_CONNECTOR_JARS_PATH" "https://jdbc.postgresql.org/download/postgresql-$POSTGRES_JDBC_VERSION.jar"
  fi

  if [ ! -f "$DB_CONNECTOR_JARS_PATH/mysql-connector-java-$MYSQL_CONNECTOR_JAVA_VERSION.jar" ]; then
    wget -P "$DB_CONNECTOR_JARS_PATH" "$MVN_REPO_URL/mysql/mysql-connector-java/$MYSQL_CONNECTOR_JAVA_VERSION/mysql-connector-java-$MYSQL_CONNECTOR_JAVA_VERSION.jar"
  fi
}

download_software_tars() {
  mkdir -p "$SOFTWARE_PATH"
  if [ ! -f "$SOFTWARE_PATH/hadoop-${HADOOP_VERSION}.tar.gz" ]; then
    wget -P "$SOFTWARE_PATH" https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz
  fi

  if [ ! -f "$SOFTWARE_PATH/spark-${SPARK_VERSION}-bin-hadoop3.tgz" ]; then
    wget -P "$SOFTWARE_PATH" https://dlcdn.apache.org/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-hadoop3.tgz
  fi
}

ARCH=$(get_docker_architecture)

#sh download_and_build_hudi.sh
sh $CURRENT_DIR/download_flink_jars.sh

download_software_tars
download_hadoop_aws_jars
download_db_connector_jars

# Function to build Docker images
build_docker_image() {
  local image_name="$1"
  local image_version="$2"
  local dockerfile="$3"

  version_arg=$(echo "${image_name}_VERSION" | tr '[:lower:]' '[:upper:]')
  local image_version_str="${version_arg//-/_}"
  if docker build --build-arg "$image_version_str=$image_version" --platform linux/"$ARCH" -f "$CURRENT_DIR/Dockerfile.$dockerfile" . -t "$DOCKER_HUB_USERNAME/ranga-$image_name:$image_version" -t "$DOCKER_HUB_USERNAME/ranga-$image_name:latest"; then
    echo "Successfully built $image_name:$image_version"
  else
    echo "Failed to build $image_name:$image_version"
    exit 1
  fi
}

declare -a image_builds=(
  "hive $HIVE_VERSION hive"
  "spark $SPARK_VERSION spark"
  "kafka-connect $KAFKA_CONNECT_VERSION kafka_connect"
  "kafka-cat $CONFLUENT_KAFKACAT_VERSION kafka_cat"
  "trino $TRINO_VERSION trino"
  #"jupyter-notebook $JUPYTER_VERSION jupyter"
  "xtable $XTABLE_VERSION xtable"
  "flink $FLINK_VERSION flink"
)

# Iterate through the array and build images
for build_config in "${image_builds[@]}"; do
  IFS=' ' read -r image_name version dockerfile_ext <<<"$build_config"
  build_docker_image "$image_name" "$version" "$dockerfile_ext"
done

# Prune unused Docker images
if docker image prune -f; then
  echo "Successfully pruned unused Docker images."
else
  echo "Failed to prune unused Docker images."
fi
