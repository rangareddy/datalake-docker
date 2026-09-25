# Demos

Runnable scripts that reproduce the measurements from the blog posts, against this
stack rather than against a bespoke environment.

## Running them

Start the stack, then copy the demos into the Spark master and run one:

```sh
sh docker_run/run_datalake.sh start
docker cp demos spark-master:/opt/demos

docker exec -it spark-master bash /opt/demos/smoke_test_formats.sh
docker exec -it spark-master bash /opt/demos/run_demo.sh iceberg/cow_vs_mor.py
```

`run_demo.sh` supplies the jars and catalog configuration each format needs, inferred
from the first path component, so a demo script contains only its own logic. Jar names
are resolved with globs rather than pinned versions, so every demo runs unchanged on
both the Spark 3.5 and Spark 4.0 images.

## What is here

| Script | Reproduces |
| ------ | ---------- |
| `smoke_test_formats.sh` | Write, update and read in Hudi, Iceberg and Delta. The end-to-end check after building an image |
| `iceberg/cow_vs_mor.py` | The same `DELETE` under copy-on-write and merge-on-read, with the file accounting for each |
| `iceberg/time_travel.py` | Reading an old snapshot, rolling back a bad write, and the history entry the rollback leaves |
| `iceberg/schema_and_partition_evolution.py` | A rename and an added column that rewrite no data, and a partition spec change that leaves old files on the old spec |

Each script prints what it expects at the end, so a run that drifts from the post is
visible without going back to the post.

## Verified on

Both profiles, using the stack's own MinIO and Hive Metastore:

| | Spark 3.5.5 / Scala 2.12 | Spark 4.0.2 / Scala 2.13 |
| --- | --- | --- |
| Hudi | 1.1.1 | 1.2.0 |
| Iceberg | 1.11.0 | 1.11.0 |
| Delta | 3.3.2 | 4.0.0 |

One note from running these: Hudi's **first** write to a new table initialises its
metadata table and takes appreciably longer than later writes — around twenty seconds
on a cold stack. A smoke test that runs immediately after `start` can see that as a
failure; re-running passes.
