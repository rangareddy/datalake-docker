#!/bin/bash
set -e

# Define constants
CURRENT_DIR=$(pwd)
export HIVE_VERSION=${HIVE_VERSION:-4.0.0}
export SPARK_VERSION=${SPARK_VERSION:-3.5.3}
export KAFKA_CONNECT_VERSION=${KAFKA_CONNECT_VERSION:-7.4.7}
export CONFLUENT_KAFKACAT_VERSION=${CONFLUENT_KAFKACAT_VERSION:-7.1.15}
export HUDI_VERSIONS=("0.15.0" "1.0.0")
export SPARK_MAJOR_VERSION="${SPARK_VERSION%.*}"
export SCALA_VERSION=${SCALA_VERSION:-2.12}
export DOCKER_HUB_USERNAME="rangareddy1988"
export HADOOP_AWS_JARS_PATH="$CURRENT_DIR/hadoop-s3-jars"
export DB_CONNECTOR_JARS_PATH="$CURRENT_DIR/db_connector_jars"
export TRINO_VERSION=${TRINO_VERSION:-460}
export MVN_REPO_URL="https://repo1.maven.org/maven2/"

# Function to check Docker installation
check_docker_installed() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is not installed. Please install docker and rerun."
    exit 1
  fi
  if ! command -v docker-compose >/dev/null 2>&1; then
    echo "ERROR: Docker Compose is not installed."
    exit 1
  fi
}

# Function to check Docker running status
check_docker_running() {
  if ! docker info >/dev/null 2>&1; then
    echo "ERROR: The docker daemon is not running or accessible. Please start docker and rerun."
    exit 1
  fi
}

# Function to determine the architecture
get_docker_architecture() {
  local ARCH=""
  SUPPORTED_PLATFORMS=("linux/amd64" "linux/arm64")
  for PLATFORM in "${SUPPORTED_PLATFORMS[@]}"; do
    if docker buildx ls | grep "$PLATFORM" >/dev/null 2>&1; then
      ARCH=$(echo "${PLATFORM}" | cut -d '/' -f2)
      echo "$ARCH" # Return the architecture
      return 0     # Success
    fi
  done

  # If no supported architecture is found, print an error and exit
  echo "Unsupported Docker architecture." >&2
  exit 1
}

# Function to build Docker images
build_docker_image() {
  local image_version="$1"
  local dockerfile="$2"
  local image_name="$3"
  version_arg=$(echo ${image_name}_VERSION | tr '[:lower:]' '[:upper:]')
  local image_version_str="${version_arg//-/_}"
  if docker build --build-arg "$image_version_str=$image_version" --platform linux/"$ARCH" -f "$dockerfile" . -t "$DOCKER_HUB_USERNAME/ranga-$image_name:$image_version" -t "$DOCKER_HUB_USERNAME/ranga-$image_name:latest"; then
    echo "Successfully built $image_name:$image_version"
  else
    echo "Failed to build $image_name:$image_version"
    exit 1
  fi
}

download_hadoop_aws_jars() {
  if [ ! -d "$HADOOP_AWS_JARS_PATH" ]; then
    echo "Downloading Hadoop AWS jar(s) ..."
    mkdir -p "$HADOOP_AWS_JARS_PATH"
    HADOOP_VERSION=${HADOOP_VERSION:-3.3.4}
    AWS_JAVA_SDK_BUNDLE_VERSION=${AWS_JAVA_SDK_BUNDLE_VERSION:-1.12.262}
    
    curl -s "$MVN_REPO_URL/com/amazonaws/aws-java-sdk-bundle/$AWS_JAVA_SDK_BUNDLE_VERSION/aws-java-sdk-bundle-$AWS_JAVA_SDK_BUNDLE_VERSION.jar" \
      -o "$HADOOP_AWS_JARS_PATH/aws-java-sdk-bundle-$AWS_JAVA_SDK_BUNDLE_VERSION.jar" &&
      curl -s "$MVN_REPO_URL/org/apache/hadoop/hadoop-aws/$HADOOP_VERSION/hadoop-aws-$HADOOP_VERSION.jar" \
        -o "$HADOOP_AWS_JARS_PATH/hadoop-aws-$HADOOP_VERSION.jar"
  fi
}

download_db_connector_jars() {
  if [ ! -d "$DB_CONNECTOR_JARS_PATH" ]; then
    echo "Downloading DB connector jar(s) ..."
    mkdir -p "$DB_CONNECTOR_JARS_PATH"
    POSTGRES_JDBC_VERSION=${POSTGRES_JDBC_VERSION:-42.7.3}
    MYSQL_CONNECTOR_JAVA_VERSION=${MYSQL_CONNECTOR_JAVA_VERSION:-8.0.29}
    curl -s "https://jdbc.postgresql.org/download/postgresql-$POSTGRES_JDBC_VERSION.jar" \
      -o "$DB_CONNECTOR_JARS_PATH/postgresql-jdbc.jar"
    curl -s "$MVN_REPO_URL/mysql/mysql-connector-java/$MYSQL_CONNECTOR_JAVA_VERSION/mysql-connector-java-$MYSQL_CONNECTOR_JAVA_VERSION.jar" \
      -o "$DB_CONNECTOR_JARS_PATH/mysql-connector-java.jar"
  fi
}

check_docker_installed
check_docker_running
ARCH=$(get_docker_architecture)

sh download_and_build_hudi.sh
download_hadoop_aws_jars
download_db_connector_jars

# Build Docker images
build_docker_image "$HIVE_VERSION" "./Dockerfile.hive" "hive"
build_docker_image "$SPARK_VERSION" "./Dockerfile.spark" "spark"
build_docker_image "$KAFKA_CONNECT_VERSION" "./Dockerfile.kafka_connect" "kafka-connect"
build_docker_image "$CONFLUENT_KAFKACAT_VERSION" "./Dockerfile.kafka_cat" "kafka-cat"
build_docker_image "$TRINO_VERSION" "./Dockerfile.trino" "trino"

# Prune unused Docker images
if docker image prune -f; then
  echo "Successfully pruned unused Docker images."
else
  echo "Failed to prune unused Docker images."
fi
