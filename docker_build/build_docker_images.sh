#!/bin/bash
set -e

CURRENT_DIR="$(
  cd "$(dirname "$0")"
  pwd -P
)"
DOCKER_HUB_USERNAME="rangareddy1988"

# ---------------------------------------------------------------------------- tag
# Every image this repo builds carries one tag, and it is the tag of the *stack*, not
# of the component inside it: rangareddy1988/ranga-<name>:1.0.0.
#
# The component versions below are what 1.0.0 is made of. They are build arguments and
# nothing else - changing Spark from 3.5.9 to 3.5.10 does not produce ranga-spark:3.5.10,
# it produces a different 1.0.0. When a migration changes the stack in a way worth
# telling people about, bump IMAGE_VERSION and update the table in README.md; until
# then, one number describes the whole set and compose needs exactly one pin.
IMAGE_VERSION=${IMAGE_VERSION:-1.0.0}

# ------------------------------------------------------------------- tech stack 1.0.0
HIVE_VERSION=${HIVE_VERSION:-4.0.0}
SPARK_VERSION=${SPARK_VERSION:-3.5.9}
TRINO_VERSION=${TRINO_VERSION:-483}
KAFKA_CONNECT_VERSION=${KAFKA_CONNECT_VERSION:-7.4.7}

# Third-party services are rebuilt under rangareddy1988/ranga-* rather than pulled
# straight from their publishers. The stack then depends only on tags this repo
# controls, so an upstream retag, retirement or relicense is a rebuild here instead of
# a broken stack everywhere. Every pin below is an exact version, never "latest".
CONFLUENT_VERSION=${CONFLUENT_VERSION:-7.4.7}
KAFKA_UI_VERSION=${KAFKA_UI_VERSION:-v0.7.2}
POSTGRES_VERSION=${POSTGRES_VERSION:-16.4}
MYSQL_VERSION=${MYSQL_VERSION:-8.0-20.04_edge}
# MinIO is the exception: quay.io serves only :latest anonymously, so the base is
# pinned by digest inside Dockerfile.minio. This is the label only.
MINIO_VERSION=${MINIO_VERSION:-RELEASE.2025-09-07T16-13-09Z}

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

HADOOP_AWS_JARS_PATH="$CURRENT_DIR/hadoop-s3-jars"
DB_CONNECTOR_JARS_PATH="$CURRENT_DIR/db_connector_jars"
SOFTWARE_PATH="$CURRENT_DIR/software"
# Hadoop 3.3.x S3A uses AWS SDK v1 (com.amazonaws:aws-java-sdk-bundle); Hadoop 3.4.x
# switched to SDK v2 (software.amazon.awssdk:bundle). Shipping the wrong one gives a
# ClassNotFoundException on the first s3a:// call, so the profile picks.
AWS_JAVA_SDK_VERSION=${AWS_JAVA_SDK_VERSION:-1.12.262}
AWS_SDK_V2_VERSION=${AWS_SDK_V2_VERSION:-2.29.52}
MVN_REPO_URL="https://repo1.maven.org/maven2"

# ------------------------------------------------------------------------ selection
# IMAGES limits the run to a subset, space or comma separated. It is the fast path
# after editing one Dockerfile:
#
#   IMAGES=spark SPARK_VERSION=4.1.3 ./docker_build/build_docker_images.sh
#
# Three group names expand to sets, so the common cases need no list:
#
#   upstream  the third-party wrappers - seconds, since most add no layer
#   engines   the images this repo assembles (spark, hive, connect, trino)
#   core      everything docker-compose.yml starts, i.e. not the "all" extras
IMAGES=${IMAGES:-}
GROUP_UPSTREAM="kafka kafka-schema-registry kafka-rest kafka-ui postgres minio mysql"
GROUP_ENGINES="hive $SPARK_IMAGE_NAME kafka-connect trino"
GROUP_CORE="kafka kafka-schema-registry kafka-rest kafka-ui postgres minio hive $SPARK_IMAGE_NAME kafka-connect"

expand_images() {
  local out=""
  for token in $(echo "$IMAGES" | tr ',' ' '); do
    case "$token" in
    upstream) out="$out $GROUP_UPSTREAM" ;;
    engines) out="$out $GROUP_ENGINES" ;;
    core) out="$out $GROUP_CORE" ;;
    *) out="$out $token" ;;
    esac
  done
  echo "$out"
}
IMAGES_EXPANDED="$(expand_images)"

should_build() {
  [ -z "$IMAGES" ] && return 0
  case " $IMAGES_EXPANDED " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# shellcheck source=/dev/null
source $CURRENT_DIR/validate_docker_status.sh

# ------------------------------------------------------------------------ downloads
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
  if [ ! -f "$SOFTWARE_PATH/spark-${SPARK_VERSION}-bin-hadoop3.tgz" ]; then
    wget -P "$SOFTWARE_PATH" https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-hadoop3.tgz
  fi
}

ARCH=$(get_docker_architecture)

# Only fetch what the selected images actually COPY. IMAGES=upstream is otherwise a few
# seconds of building behind several GB of tarballs nothing in that set consumes.
needs_any() {
  for name in "$@"; do should_build "$name" && return 0; done
  return 1
}
needs_any "$SPARK_IMAGE_NAME" spark && download_software_tars
needs_any "$SPARK_IMAGE_NAME" spark hive kafka-connect && download_hadoop_aws_jars
needs_any hive trino && download_db_connector_jars

# --------------------------------------------------------------------------- build
# build_docker_image <image-name> <component-version> <dockerfile-suffix> <version-arg> [--build-arg ...]
#
# <component-version> is what goes into the image as a build arg; the *tag* is always
# IMAGE_VERSION. <version-arg> is passed explicitly rather than derived from the image
# name. Deriving it was silently wrong for two images, and Docker only warns about an
# unknown --build-arg, so both quietly built whatever their ARG default happened to be.
# Any new entry in image_builds must name its arg.
build_docker_image() {
  local image_name="$1" component_version="$2" dockerfile="$3" version_arg="$4"
  shift 4
  local extra_args=("$@")

  local image="$DOCKER_HUB_USERNAME/ranga-$image_name"
  if docker build \
    --build-arg "$version_arg=$component_version" \
    "${extra_args[@]}" \
    --platform linux/"$ARCH" \
    -f "$CURRENT_DIR/Dockerfile.$dockerfile" "$CURRENT_DIR" \
    -t "$image:$IMAGE_VERSION" -t "$image:latest"; then
    echo "Successfully built $image_name:$IMAGE_VERSION ($version_arg=$component_version)"
  else
    echo "Failed to build $image_name:$IMAGE_VERSION"
    exit 1
  fi
}

# image-name | component version | Dockerfile suffix | build-arg name
#
# The first block is the third-party wrappers: thin, pinned re-tags that move the stack
# off tags other people control. The second is what this repo assembles.
#
# There is no separate zookeeper, minio-mc, jupyter or kcat image. cp-kafka already ships
# zookeeper-server-start and the kafka-console-* tools, the MinIO image already ships mc,
# and the Spark image already ships JupyterLab and its kernels - so those services run
# from ranga-kafka, ranga-minio and ranga-spark. About 5.6GB of duplicated content gone.
declare -a image_builds=(
  "kafka $CONFLUENT_VERSION kafka CONFLUENT_VERSION"
  "kafka-schema-registry $CONFLUENT_VERSION kafka_schema_registry CONFLUENT_VERSION"
  "kafka-rest $CONFLUENT_VERSION kafka_rest CONFLUENT_VERSION"
  "kafka-ui $KAFKA_UI_VERSION kafka_ui KAFKA_UI_VERSION"
  "postgres $POSTGRES_VERSION postgres POSTGRES_VERSION"
  "minio $MINIO_VERSION minio MINIO_VERSION"
  "mysql $MYSQL_VERSION mysql MYSQL_VERSION"
  "hive $HIVE_VERSION hive HIVE_VERSION"
  "$SPARK_IMAGE_NAME $SPARK_VERSION $SPARK_DOCKERFILE SPARK_VERSION"
  "kafka-connect $KAFKA_CONNECT_VERSION kafka_connect KAFKA_CONNECT_VERSION"
  "trino $TRINO_VERSION trino TRINO_VERSION"
)

for build_config in "${image_builds[@]}"; do
  IFS=' ' read -r image_name version dockerfile_ext version_arg <<<"$build_config"
  # "spark" selects whichever of spark3/spark4 this SPARK_VERSION resolves to, so the
  # familiar IMAGES=spark keeps working alongside IMAGES=spark4.
  if [ -n "$IMAGES" ] && [ "$image_name" = "$SPARK_IMAGE_NAME" ] && should_build spark; then
    :
  else
    should_build "$image_name" || continue
  fi
  if [ "$image_name" = "$SPARK_IMAGE_NAME" ]; then
    build_docker_image "$image_name" "$version" "$dockerfile_ext" "$version_arg" \
      --build-arg "SPARK_MAJOR_VERSION=$SPARK_MAJOR_VERSION" \
      --build-arg "SCALA_VERSION=$SCALA_VERSION" \
      --build-arg "HUDI_VERSION=$HUDI_VERSION" \
      --build-arg "ICEBERG_VERSION=$ICEBERG_VERSION" \
      --build-arg "DELTA_VERSION=$DELTA_VERSION"
  else
    build_docker_image "$image_name" "$version" "$dockerfile_ext" "$version_arg"
  fi
done

if docker image prune -f; then
  echo "Successfully pruned unused Docker images."
else
  echo "Failed to prune unused Docker images."
fi
