#!/bin/bash
# Run a demo script with the jars and catalog configuration its format needs.
#
#   docker exec -it spark-master bash /opt/demos/run_demo.sh iceberg/cow_vs_mor.py
#
# FORMAT is inferred from the first path component (iceberg | hudi | delta), so a
# demo does not have to repeat the --conf block that every script of its kind needs.
set -uo pipefail

SCRIPT="${1:?usage: run_demo.sh <format>/<script>.py}"
shift || true
DEMO_DIR="$(cd "$(dirname "$0")" && pwd -P)"
FORMAT="${SCRIPT%%/*}"
MASTER="${SPARK_MASTER:-local[2]}"

case "$FORMAT" in
iceberg)
  JARS="$(ls "$ICEBERG_HOME"/*.jar | tr '\n' ',' | sed 's/,$//')"
  CONF=(
    --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions
    --conf spark.sql.catalog.ice=org.apache.iceberg.spark.SparkCatalog
    --conf spark.sql.catalog.ice.type=hive
    --conf spark.sql.catalog.ice.uri=thrift://hive-metastore:9083
    --conf spark.sql.catalog.ice.warehouse=s3a://warehouse/ice
  )
  ;;
hudi)
  JARS="$(ls "$HUDI_HOME"/hudi-spark*-bundle_*.jar | head -1)"
  CONF=(
    --conf spark.serializer=org.apache.spark.serializer.KryoSerializer
    --conf spark.sql.catalog.spark_catalog=org.apache.spark.sql.hudi.catalog.HoodieCatalog
    --conf spark.sql.extensions=org.apache.spark.sql.hudi.HoodieSparkSessionExtension
    --conf spark.kryo.registrator=org.apache.spark.HoodieSparkKryoRegistrar
  )
  ;;
delta)
  JARS="$(ls "$DELTA_HOME"/*.jar | tr '\n' ',' | sed 's/,$//')"
  CONF=(
    --conf spark.sql.extensions=io.delta.sql.DeltaSparkSessionExtension
    --conf spark.sql.catalog.spark_catalog=org.apache.spark.sql.delta.catalog.DeltaCatalog
  )
  ;;
*)
  echo "unknown format '$FORMAT' - expected iceberg, hudi or delta" >&2
  exit 2
  ;;
esac

exec spark-submit --master "$MASTER" --jars "$JARS" "${CONF[@]}" \
  --conf spark.ui.enabled=false --conf spark.eventLog.enabled=false \
  "$DEMO_DIR/$SCRIPT" "$@"
