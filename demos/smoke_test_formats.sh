#!/bin/bash
# End-to-end smoke test: write, update and read a table in each of Hudi, Iceberg
# and Delta, against MinIO through the stack. Run it inside the Spark master:
#
#   docker exec -it spark-master bash /opt/demos/smoke_test_formats.sh
#
# Jar names are resolved with globs rather than hardcoded versions, so the same
# script works on both the Spark 3.5 and Spark 4.0 images.
set -uo pipefail

SUFFIX="${SUFFIX:-smoke}"
PASS=0
FAIL=0
SKIP=0

hudi_bundle() { ls "$HUDI_HOME"/hudi-spark*-bundle_*.jar 2>/dev/null | head -1; }
iceberg_jars() { ls "$ICEBERG_HOME"/*.jar 2>/dev/null | tr '\n' ',' | sed 's/,$//'; }
delta_jars() { ls "$DELTA_HOME"/*.jar 2>/dev/null | tr '\n' ',' | sed 's/,$//'; }

# A format with no jars in the image is not shipped for this Spark line - the 4.1
# profile is Iceberg-only - so that is a skip, not a failure.
have() { ls $1 >/dev/null 2>&1; }

skip() {
  echo "  SKIP  $1: not shipped on this Spark line"
  SKIP=$((SKIP + 1))
}

report() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS  $name: $actual"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $name: expected [$expected], got [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

echo "== environment =="
echo "  spark        $(spark-submit --version 2>&1 | grep -oE 'version [0-9]+\.[0-9]+\.[0-9]+' | head -1)"
echo "  scala        ${SCALA_VERSION:-unset}"
echo "  hudi         ${HUDI_VERSION:-unset}   $(basename "$(hudi_bundle)" 2>/dev/null)"
echo "  iceberg      ${ICEBERG_VERSION:-unset}"
echo "  delta        ${DELTA_VERSION:-unset}"
echo "  java         $(java -version 2>&1 | head -1 | grep -oE '"[^"]+"')"

# ---------------------------------------------------------------- Iceberg
echo "== iceberg =="
ICE_OUT=$(spark-sql --master "${SPARK_MASTER:-local[2]}" \
  --jars "$(iceberg_jars)" \
  --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions \
  --conf spark.sql.catalog.ice=org.apache.iceberg.spark.SparkCatalog \
  --conf spark.sql.catalog.ice.type=hive \
  --conf spark.sql.catalog.ice.uri=thrift://hive-metastore:9083 \
  --conf spark.sql.catalog.ice.warehouse=s3a://warehouse/ice \
  -e "
    CREATE DATABASE IF NOT EXISTS ice.demo;
    DROP TABLE IF EXISTS ice.demo.emp_${SUFFIX};
    CREATE TABLE ice.demo.emp_${SUFFIX} (id INT, name STRING, dept STRING) USING iceberg;
    INSERT INTO ice.demo.emp_${SUFFIX} VALUES (1,'Ranga','Sales'),(2,'Nishanth','Software');
    UPDATE ice.demo.emp_${SUFFIX} SET dept='Analytics' WHERE id=1;
    DELETE FROM ice.demo.emp_${SUFFIX} WHERE id=2;
    SELECT concat('ROWS=', count(*), ' DEPT=', max(dept)) FROM ice.demo.emp_${SUFFIX};
  " 2>/dev/null | grep -oE 'ROWS=[0-9]+ DEPT=[A-Za-z]+' | tail -1)
report "iceberg write/update/delete" "ROWS=1 DEPT=Analytics" "$ICE_OUT"

# snapshots prove the commits landed
ICE_SNAP=$(spark-sql --master "${SPARK_MASTER:-local[2]}" --jars "$(iceberg_jars)" \
  --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions \
  --conf spark.sql.catalog.ice=org.apache.iceberg.spark.SparkCatalog \
  --conf spark.sql.catalog.ice.type=hive \
  --conf spark.sql.catalog.ice.uri=thrift://hive-metastore:9083 \
  --conf spark.sql.catalog.ice.warehouse=s3a://warehouse/ice \
  -e "SELECT concat('SNAPS=', count(*)) FROM ice.demo.emp_${SUFFIX}.snapshots;" 2>/dev/null \
  | grep -oE 'SNAPS=[0-9]+' | tail -1)
report "iceberg snapshot history" "SNAPS=3" "$ICE_SNAP"

# ---------------------------------------------------------------- Hudi
echo "== hudi =="
if ! have "$HUDI_HOME/hudi-spark*-bundle_*.jar"; then
  skip "hudi write/update"
else
HUDI_OUT=$(spark-sql --master "${SPARK_MASTER:-local[2]}" \
  --jars "$(hudi_bundle)" \
  --conf spark.serializer=org.apache.spark.serializer.KryoSerializer \
  --conf spark.sql.catalog.spark_catalog=org.apache.spark.sql.hudi.catalog.HoodieCatalog \
  --conf spark.sql.extensions=org.apache.spark.sql.hudi.HoodieSparkSessionExtension \
  --conf spark.kryo.registrator=org.apache.spark.HoodieSparkKryoRegistrar \
  -e "
    DROP TABLE IF EXISTS emp_hudi_${SUFFIX};
    CREATE TABLE emp_hudi_${SUFFIX} (id INT, name STRING, dept STRING, ts LONG)
      USING hudi TBLPROPERTIES (primaryKey='id', preCombineField='ts')
      LOCATION 's3a://warehouse/emp_hudi_${SUFFIX}';
    INSERT INTO emp_hudi_${SUFFIX} VALUES (1,'Ranga','Sales',1),(2,'Nishanth','Software',2);
    UPDATE emp_hudi_${SUFFIX} SET dept='Analytics' WHERE id=1;
    SELECT concat('ROWS=', count(*), ' DEPT=', max(dept)) FROM emp_hudi_${SUFFIX};
  " 2>/dev/null | grep -oE 'ROWS=[0-9]+ DEPT=[A-Za-z]+' | tail -1)
report "hudi write/update" "ROWS=2 DEPT=Software" "$HUDI_OUT"
fi

# ---------------------------------------------------------------- Delta
echo "== delta =="
if ! have "$DELTA_HOME/*.jar"; then
  skip "delta write/update/delete"
else
DELTA_OUT=$(spark-sql --master "${SPARK_MASTER:-local[2]}" \
  --jars "$(delta_jars)" \
  --conf spark.sql.extensions=io.delta.sql.DeltaSparkSessionExtension \
  --conf spark.sql.catalog.spark_catalog=org.apache.spark.sql.delta.catalog.DeltaCatalog \
  -e "
    DROP TABLE IF EXISTS emp_delta_${SUFFIX};
    CREATE TABLE emp_delta_${SUFFIX} (id INT, name STRING, dept STRING)
      USING delta LOCATION 's3a://warehouse/emp_delta_${SUFFIX}';
    INSERT INTO emp_delta_${SUFFIX} VALUES (1,'Ranga','Sales'),(2,'Nishanth','Software');
    UPDATE emp_delta_${SUFFIX} SET dept='Analytics' WHERE id=1;
    DELETE FROM emp_delta_${SUFFIX} WHERE id=2;
    SELECT concat('ROWS=', count(*), ' DEPT=', max(dept)) FROM emp_delta_${SUFFIX};
  " 2>/dev/null | grep -oE 'ROWS=[0-9]+ DEPT=[A-Za-z]+' | tail -1)
report "delta write/update/delete" "ROWS=1 DEPT=Analytics" "$DELTA_OUT"
fi

echo
echo "== summary =="
echo "  passed $PASS, failed $FAIL, skipped $SKIP"
[ "$FAIL" -eq 0 ] || exit 1
