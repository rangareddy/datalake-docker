"""Time travel and rollback, measured.

    docker exec -it spark-master bash /opt/demos/run_demo.sh iceberg/time_travel.py
"""
from pyspark.sql import SparkSession

spark = SparkSession.builder.appName("time-travel").getOrCreate()
spark.sparkContext.setLogLevel("ERROR")
S = spark.sql
S("CREATE DATABASE IF NOT EXISTS ice.demo")
S("DROP TABLE IF EXISTS ice.demo.tt PURGE")
S("CREATE TABLE ice.demo.tt (id BIGINT, v STRING) USING iceberg")

S("INSERT INTO ice.demo.tt VALUES (1,'a'),(2,'b')")
S("INSERT INTO ice.demo.tt VALUES (3,'c')")
snaps = [r["snapshot_id"] for r in
         S("SELECT snapshot_id FROM ice.demo.tt.snapshots ORDER BY committed_at").collect()]

print("== time travel ==")
print("  snapshots            ", snaps)
print("  current rows         ", S("SELECT count(*) c FROM ice.demo.tt").collect()[0]["c"])
print("  VERSION AS OF first  ",
      S(f"SELECT count(*) c FROM ice.demo.tt VERSION AS OF {snaps[0]}").collect()[0]["c"])

S("INSERT INTO ice.demo.tt VALUES (4,'OOPS'),(5,'OOPS')")
print("  after a bad write    ", S("SELECT count(*) c FROM ice.demo.tt").collect()[0]["c"])

S(f"CALL ice.system.rollback_to_snapshot('demo.tt', {snaps[1]})")
print("  after rollback       ", S("SELECT count(*) c FROM ice.demo.tt").collect()[0]["c"])

print("  history:")
for r in S("""SELECT snapshot_id, is_current_ancestor
              FROM ice.demo.tt.history ORDER BY made_current_at""").collect():
    print(f"      snap={r['snapshot_id']} is_current_ancestor={r['is_current_ancestor']}")

print("\nExpected: 2 rows at the first snapshot, 3 now, 5 after the bad write, 3 after rollback,")
print("and the abandoned snapshot still listed with is_current_ancestor=false.")
spark.stop()
