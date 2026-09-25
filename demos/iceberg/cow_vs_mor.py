"""Copy-on-write versus merge-on-read, measured.

Reproduces the file accounting from the blog post: the same DELETE against two
tables that differ only in write.delete.mode.

    docker exec -it spark-master bash /opt/demos/run_demo.sh iceberg/cow_vs_mor.py
"""
from pyspark.sql import SparkSession, functions as F

spark = SparkSession.builder.appName("cow-vs-mor").getOrCreate()
spark.sparkContext.setLogLevel("ERROR")
S = spark.sql
S("CREATE DATABASE IF NOT EXISTS ice.demo")

LABEL = {0: "data", 1: "position-delete", 2: "equality-delete"}


def build(name, mode):
    S(f"DROP TABLE IF EXISTS ice.demo.{name} PURGE")
    S(f"""CREATE TABLE ice.demo.{name} (id BIGINT, v STRING) USING iceberg
          TBLPROPERTIES ('write.delete.mode'='{mode}',
                         'write.update.mode'='{mode}',
                         'write.merge.mode'='{mode}')""")
    (spark.range(0, 4000)
          .withColumn("v", F.concat(F.lit("v"), F.col("id").cast("string")))
          .selectExpr("id", "v")
          .writeTo(f"ice.demo.{name}").append())


def accounting(name, tag):
    rows = S(f"""SELECT content, count(*) AS files, sum(record_count) AS records
                 FROM ice.demo.{name}.files GROUP BY content ORDER BY content""").collect()
    desc = "  ".join(f"{LABEL.get(r['content'], r['content'])}={r['files']}f/{r['records']}r"
                     for r in rows)
    live = S(f"SELECT count(*) c FROM ice.demo.{name}").collect()[0]["c"]
    print(f"  {tag:<30} {desc:<52} query returns {live}")


print("== copy-on-write vs merge-on-read ==")
for name, mode in (("cow_demo", "copy-on-write"), ("mor_demo", "merge-on-read")):
    build(name, mode)
    accounting(name, f"{mode} before")
    S(f"DELETE FROM ice.demo.{name} WHERE id < 100")
    accounting(name, f"{mode} after DELETE")
    ops = [r["operation"] for r in
           S(f"SELECT operation FROM ice.demo.{name}.snapshots ORDER BY committed_at").collect()]
    print(f"  {'snapshot ops':<30} {ops}")

print("\nExpected: copy-on-write rewrites to 2 files / 3900 records (op 'overwrite');")
print("merge-on-read keeps 2 files / 4000 records plus a 100-record delete file (op 'delete').")
spark.stop()
