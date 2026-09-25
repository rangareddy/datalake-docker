#!/bin/bash
set -e

# Define constants
CURRENT_DIR="$(
  cd "$(dirname "$0")"
  pwd -P
)"
DOCKER_HUB_USERNAME="rangareddy1988"
HIVE_VERSION=${HIVE_VERSION:-4.0.0}
SPARK_VERSION=${SPARK_VERSION:-3.5.9}

# Everything below follows from SPARK_VERSION, because the Spark line dictates the
# Scala binary, the bundled Hadoop, and which builds of Hudi/Iceberg/Delta exist.
#
#   Spark 3.5.x -> Scala 2.12, Hadoop 3.3.4, Hudi 1.1.1, Iceberg 1.11.0, Delta 3.3.2
#   Spark 4.1.x -> Scala 2.13, Hadoop 3.4.2, Iceberg 1.11.0 only
#
# The 4.1 line is Iceberg-only, and both exclusions were verified by running them rather
# than inferred from a version table:
#
#   Hudi 1.2.0   NoClassDefFoundError org/apache/parquet/variant/VariantConverters
#                Spark 4.1.3 ships Parquet 1.16.0, which dropped that class; the
#                hudi-spark4.1 bundle is built against 1.15.x and bundles parquet
#                classes that still reference it.
#   Delta 4.0.0  NoSuchMethodError org.apache.spark.internal.LogKey.$init$
#                Spark 4.1 changed an internal trait Delta 4.0.0 was compiled against,
#                and Delta publishes no Scala 2.13 build past 4.0.0.
#
# Both exclusions are a matter of upstream releases, not of this repo: when Hudi and
# Delta publish builds for Spark 4.1, filling in the two versions below is the whole
# change. An unrecognised Spark line is refused rather than silently built against the
# wrong Scala binary.
SPARK_MAJOR_VERSION=${SPARK_MAJOR_VERSION:-$(echo "$SPARK_VERSION" | cut -d. -f1,2)}
case "$SPARK_MAJOR_VERSION" in
3.5)
  SCALA_VERSION=${SCALA_VERSION:-2.12}
  HADOOP_VERSION=${HADOOP_VERSION:-3.3.4}
  HUDI_VERSION=${HUDI_VERSION:-1.1.1}
  DELTA_VERSION=${DELTA_VERSION:-3.3.2}
  ICEBERG_VERSION=${ICEBERG_VERSION:-1.11.0}
  ;;
4.1)
  SCALA_VERSION=${SCALA_VERSION:-2.13}
  HADOOP_VERSION=${HADOOP_VERSION:-3.4.2}
  ICEBERG_VERSION=${ICEBERG_VERSION:-1.11.0}
  HUDI_VERSION=${HUDI_VERSION:-}
  DELTA_VERSION=${DELTA_VERSION:-}
  ;;
*)
  echo "Unsupported SPARK_VERSION '$SPARK_VERSION' (major '$SPARK_MAJOR_VERSION')." >&2
  echo "Supported lines: 3.5.x (e.g. 3.5.9) and 4.1.x (e.g. 4.1.3)." >&2
  exit 1
  ;;
esac

# Spark 3 and Spark 4 are separate Dockerfiles, because the two lines differ in Scala
# binary, in which connectors exist and in which AWS SDK S3A needs.
#
# The Spark 3 image keeps its original name, ranga-spark, so existing pulls and compose
# files carry on working; only the new line is prefixed. SPARK_IMAGE is what Compose
# resolves, so it has to agree with whatever was built.
case "$SPARK_MAJOR_VERSION" in
4.*)
  SPARK_IMAGE_NAME="spark4"
  SPARK_DOCKERFILE="spark4"
  ;;
*)
  SPARK_IMAGE_NAME="spark"
  SPARK_DOCKERFILE="spark3"
  ;;
esac
SPARK_IMAGE="ranga-${SPARK_IMAGE_NAME}"
export SPARK_IMAGE
KAFKA_CONNECT_VERSION=${KAFKA_CONNECT_VERSION:-7.4.7}
CONFLUENT_KAFKACAT_VERSION=${CONFLUENT_KAFKACAT_VERSION:-7.1.15}
HADOOP_AWS_JARS_PATH="$CURRENT_DIR/hadoop-s3-jars"
DB_CONNECTOR_JARS_PATH="$CURRENT_DIR/db_connector_jars"
SOFTWARE_PATH="$CURRENT_DIR/software"
TRINO_VERSION=${TRINO_VERSION:-483}
JUPYTER_VERSION=${JUPYTER_VERSION:-latest}
XTABLE_VERSION=${XTABLE_VERSION:-0.3.0}
FLINK_VERSION=${FLINK_VERSION:-1.20.5}
# Hadoop 3.3.x S3A uses AWS SDK v1 (com.amazonaws:aws-java-sdk-bundle); Hadoop 3.4.x
# switched to SDK v2 (software.amazon.awssdk:bundle). Shipping the wrong one gives a
# ClassNotFoundException on the first s3a:// call, so the profile picks.
AWS_JAVA_SDK_VERSION=${AWS_JAVA_SDK_VERSION:-1.12.262}
AWS_SDK_V2_VERSION=${AWS_SDK_V2_VERSION:-2.29.52}
MVN_REPO_URL="https://repo1.maven.org/maven2"


# IMAGES limits the run to a subset, space or comma separated. Building all eight
# takes a long time (xtable clones and mvn-installs from source), so a targeted
# rebuild after touching one Dockerfile is:
#
#   IMAGES=spark SPARK_VERSION=4.1.3 ./docker_build/build_docker_images.sh
IMAGES=${IMAGES:-}
should_build() {
  [ -z "$IMAGES" ] && return 0
  case " $(echo "$IMAGES" | tr ',' ' ') " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# shellcheck source=/dev/null
source $CURRENT_DIR/validate_docker_status.sh

download_hadoop_aws_jars() {
  # Cache per Hadoop version, then stage a clean flat directory for the Docker build
  # context. Staging matters: the Spark image COPYs hadoop-s3-jars/* wholesale, so a
  # leftover SDK v1 bundle from a Spark 3.5 build would land in a Spark 4 image and
  # shadow the v2 classes.
  local cache="$CURRENT_DIR/.s3-jar-cache/$HADOOP_VERSION"
  mkdir -p "$cache"

  if [ ! -f "$cache/hadoop-aws-${HADOOP_VERSION}.jar" ]; then
    wget -P "$cache" $MVN_REPO_URL/org/apache/hadoop/hadoop-aws/${HADOOP_VERSION}/hadoop-aws-${HADOOP_VERSION}.jar
  fi

  case "$HADOOP_VERSION" in
  3.4.* | 3.5.*)
    AWS_SDK_JAR="bundle-${AWS_SDK_V2_VERSION}.jar"
    if [ ! -f "$cache/$AWS_SDK_JAR" ]; then
      wget -P "$cache" $MVN_REPO_URL/software/amazon/awssdk/bundle/${AWS_SDK_V2_VERSION}/${AWS_SDK_JAR}
    fi
    ;;
  *)
    AWS_SDK_JAR="aws-java-sdk-bundle-${AWS_JAVA_SDK_VERSION}.jar"
    if [ ! -f "$cache/$AWS_SDK_JAR" ]; then
      wget -P "$cache" $MVN_REPO_URL/com/amazonaws/aws-java-sdk-bundle/${AWS_JAVA_SDK_VERSION}/${AWS_SDK_JAR}
    fi
    ;;
  esac

  rm -rf "$HADOOP_AWS_JARS_PATH"
  mkdir -p "$HADOOP_AWS_JARS_PATH"
  cp "$cache"/*.jar "$HADOOP_AWS_JARS_PATH"/
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
    wget -P "$SOFTWARE_PATH" https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-hadoop3.tgz
  fi
}

ARCH=$(get_docker_architecture)

#sh download_and_build_hudi.sh
should_build flink && sh $CURRENT_DIR/download_flink_jars.sh

download_software_tars
download_hadoop_aws_jars
download_db_connector_jars

# Function to build Docker images
build_docker_image() {
  local image_name="$1"
  local image_version="$2"
  local dockerfile="$3"
  local version_arg_override="${4:-}" # e.g. spark3 still takes SPARK_VERSION, not SPARK3_VERSION
  shift 3
  [ -n "$version_arg_override" ] && shift
  local extra_args=("$@") # further --build-arg pairs, e.g. the Spark version matrix

  version_arg=$(echo "${image_name}_VERSION" | tr '[:lower:]' '[:upper:]')
  local image_version_str="${version_arg//-/_}"
  [ -n "$version_arg_override" ] && image_version_str="$version_arg_override"
  if docker build --build-arg "$image_version_str=$image_version" "${extra_args[@]}" --platform linux/"$ARCH" -f "$CURRENT_DIR/Dockerfile.$dockerfile" "$CURRENT_DIR" -t "$DOCKER_HUB_USERNAME/ranga-$image_name:$image_version" -t "$DOCKER_HUB_USERNAME/ranga-$image_name:latest"; then
    echo "Successfully built $image_name:$image_version"
  else
    echo "Failed to build $image_name:$image_version"
    exit 1
  fi
}

declare -a image_builds=(
  "hive $HIVE_VERSION hive"
  "$SPARK_IMAGE_NAME $SPARK_VERSION $SPARK_DOCKERFILE"
  "kafka-connect $KAFKA_CONNECT_VERSION kafka_connect"
  "kafka-cat $CONFLUENT_KAFKACAT_VERSION kafka_cat"
  "trino $TRINO_VERSION trino"
  "jupyter-notebook $JUPYTER_VERSION jupyter"
  "xtable $XTABLE_VERSION xtable"
  "flink $FLINK_VERSION flink"
)

# Iterate through the array and build images
for build_config in "${image_builds[@]}"; do
  IFS=' ' read -r image_name version dockerfile_ext <<<"$build_config"
  # "spark" selects whichever of spark3/spark4 this SPARK_VERSION resolves to, so the
  # familiar IMAGES=spark keeps working alongside IMAGES=spark4.
  if [ -n "$IMAGES" ] && [ "$image_name" = "$SPARK_IMAGE_NAME" ] && should_build spark; then
    :
  else
    should_build "$image_name" || continue
  fi
  if [ "$image_name" = "$SPARK_IMAGE_NAME" ]; then
    build_docker_image "$image_name" "$version" "$dockerfile_ext" SPARK_VERSION \
      --build-arg "SPARK_MAJOR_VERSION=$SPARK_MAJOR_VERSION" \
      --build-arg "SCALA_VERSION=$SCALA_VERSION" \
      --build-arg "HUDI_VERSION=$HUDI_VERSION" \
      --build-arg "ICEBERG_VERSION=$ICEBERG_VERSION" \
      --build-arg "DELTA_VERSION=$DELTA_VERSION"
  else
    build_docker_image "$image_name" "$version" "$dockerfile_ext"
  fi
done

# Prune unused Docker images
if docker image prune -f; then
  echo "Successfully pruned unused Docker images."
else
  echo "Failed to prune unused Docker images."
fi
