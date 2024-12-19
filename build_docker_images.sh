#!/bin/bash
set -e

# Define constants
export HIVE_VERSION=${HIVE_VERSION:-4.0.0}
export SPARK_VERSION=${SPARK_VERSION:-3.5.3}
export KAFKA_CONNECT_VERSION=${KAFKA_CONNECT_VERSION:-7.4.7}
export CONFLUENT_KAFKACAT_VERSION=${CONFLUENT_KAFKACAT_VERSION:-7.1.15}
export HUDI_VERSIONS=("0.15.0" "1.0.0")
export SPARK_MAJOR_VERSION="${SPARK_VERSION%.*}"
export SCALA_VERSION=${SCALA_VERSION:-2.12}
export DOCKER_HUB_USERNAME="rangareddy1988"
export CURRENT_DIR=$(pwd)
export HADOOP_AWS_JARS_PATH="$CURRENT_DIR/hadoop-s3-jars"

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
  if ! docker info > /dev/null 2>&1; then
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
            echo "$ARCH"  # Return the architecture
            return 0  # Success
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
    local version_arg=$(echo ${image_name}_VERSION | tr '[:lower:]' '[:upper:]')
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
        mkdir -p $HADOOP_AWS_JARS_PATH
        curl -s https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.12.262/aws-java-sdk-bundle-1.12.262.jar \
        -o $HADOOP_AWS_JARS_PATH/aws-java-sdk-bundle-1.12.262.jar && \
        curl -s https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.4/hadoop-aws-3.3.4.jar \
        -o $HADOOP_AWS_JARS_PATH/hadoop-aws-3.3.4.jar
    fi 
}

check_docker_installed
check_docker_running
ARCH=$(get_docker_architecture)

sh download_and_build_hudi.sh

download_hadoop_aws_jars

# Build Docker images
build_docker_image "$HIVE_VERSION" "./docker/Dockerfile.hive" "hive"
build_docker_image "$SPARK_VERSION" "./docker/Dockerfile.spark" "spark"
build_docker_image "$KAFKA_CONNECT_VERSION" "./docker/Dockerfile.kafka_connect" "kafka-connect"
build_docker_image "$CONFLUENT_KAFKACAT_VERSION" "./docker/Dockerfile.kafka_cat" "kafka-cat"

# Prune unused Docker images
if docker image prune -f; then
    echo "Successfully pruned unused Docker images."
else
    echo "Failed to prune unused Docker images."
fi