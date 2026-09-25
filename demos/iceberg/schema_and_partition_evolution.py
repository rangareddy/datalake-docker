"""Schema and partition evolution without rewriting data.

    docker exec -it spark-master bash /opt/demos/run_demo.sh iceberg/schema_and_partition_evolution.py
"""
from pyspark.sql import SparkSession, functions as F

spark = SparkSession.builder.appName("evolution").getOrCreate()
spark.sparkContext.setLogLevel("ERROR")
S = spark.sql
S("CREATE DATABASE IF NOT EXISTS ice.demo")

# ---------------------------------------------------------------- schema
S("DROP TABLE IF EXISTS ice.demo.evo PURGE")
S("""CREATE TABLE ice.demo.evo (id BIGINT, event_ts TIMESTAMP, region STRING, amount DOUBLE)
     USING iceberg PARTITIONED BY (days(event_ts))""")
for day in (5, 6, 7):
    (spark.range((day - 5) * 3000, (day - 4) * 3000)
          .withColumn("event_ts", F.to_timestamp(F.lit(f"2026-01-0{day} 10:00:00")))
          .withColumn("region", F.concat(F.lit("r"), (F.col("id") % 3).cast("string")))
          .withColumn("amount", (F.col("id") % 500).cast("double"))
          .selectExpr("id", "event_ts", "region", "amount")
          .writeTo("ice.demo.evo").append())

files_before = S("SELECT count(*) c FROM ice.demo.evo.files").collect()[0]["c"]
print("== schema evolution ==")
print("  columns before       ", [f.name for f in spark.table("ice.demo.evo").schema.fields])
S("ALTER TABLE ice.demo.evo ADD COLUMN currency STRING")
S("ALTER TABLE ice.demo.evo RENAME COLUMN amount TO amount_usd")
print("  columns after        ", [f.name for f in spark.table("ice.demo.evo").schema.fields])
print("  rows still readable  ", S("SELECT count(*) c FROM ice.demo.evo").collect()[0]["c"])
print("  NULL currency rows   ",
      S("SELECT count(*) c FROM ice.demo.evo WHERE currency IS NULL").collect()[0]["c"])
print(f"  data files {files_before} -> "
      f"{S('SELECT count(*) c FROM ice.demo.evo.files').collect()[0]['c']}  (unchanged = no rewrite)")

# ---------------------------------------------------------------- partition
S("DROP TABLE IF EXISTS ice.demo.pe PURGE")
S("CREATE TABLE ice.demo.pe (id BIGINT, ts TIMESTAMP, v DOUBLE) USING iceberg PARTITIONED BY (months(ts))")
for m in (1, 2):
    (spark.range(m * 100, m * 100 + 300)
          .withColumn("ts", F.to_timestamp(F.lit(f"2026-0{m}-15 10:00:00")))
          .withColumn("v", F.col("id").cast("double"))
          .selectExpr("id", "ts", "v").writeTo("ice.demo.pe").append())

S("ALTER TABLE ice.demo.pe REPLACE PARTITION FIELD months(ts) WITH days(ts)")
(spark.range(999, 1299)
      .withColumn("ts", F.to_timestamp(F.lit("2026-03-09 10:00:00")))
      .withColumn("v", F.col("id").cast("double"))
      .selectExpr("id", "ts", "v").writeTo("ice.demo.pe").append())

print("\n== partition evolution ==")
print("  spec_id per data file",
      [r["spec_id"] for r in S("SELECT spec_id FROM ice.demo.pe.files").collect()])
print("  rows total           ", S("SELECT count(*) c FROM ice.demo.pe").collect()[0]["c"])
print("\nExpected: data file count unchanged across the schema change, and files split")
print("between spec_id 0 and 1 with nothing rewritten.")
spark.stop()
