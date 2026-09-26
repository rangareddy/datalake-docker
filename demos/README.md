# Demos

Runnable scripts that reproduce the measurements from the blog posts, against this
stack rather than against a bespoke environment.

## The publish gate

`e2e_test.sh` is the check that stands in front of `docker push`. **Change anything under
`docker_build/`, and the order is: rebuild, start, run this, then publish.** An image that
builds is not an image that works, and the difference lands on whoever follows a blog post.

```sh
./docker_build/build_docker_images.sh        # or IMAGES=<subset>
sh docker_run/run_datalake.sh restart
./demos/e2e_test.sh                          # exits non-zero if anything failed
./publish-to-dockerhub.sh                    # only once the line above is green
```

It exercises every component rather than probing ports: a Kafka message produced and
consumed back, a Debezium connector created and its snapshot row read off the topic, a
Spark job submitted to the cluster, a table written and read in each format the image
ships, a Hive query over the shared metastore, an object written to and read from MinIO.
It also asserts that no third-party image is running, which is what keeps the stack off
tags this repo does not control.

```sh
./demos/e2e_test.sh                  # core profile
PROFILE=all ./demos/e2e_test.sh      # also Trino, Jupyter and MySQL
./demos/e2e_test.sh kafka spark      # only checks whose names start with these
SKIP_FORMATS=1 ./demos/e2e_test.sh   # skip the slow table writes
```

Output is one line per check, and the summary is the verdict:

```
  PASS  kafka:produce-consume              e2e-message
  PASS  kafka-connect:cdc                  snapshot row on e2ee2e.public.employees
  FAIL  hive:server-query                  expected [e2e_ok]

  passed 44   failed 1   skipped 0
  failing: hive:server-query

  Do not push images while this is red.
```

## Running a single demo

The `demos/` directory is bind-mounted into the Spark master at `/opt/demos`, so an edit
on the host takes effect on the next run with no copy step:

```sh
sh docker_run/run_datalake.sh start
docker exec -it spark-master bash /opt/demos/smoke_test_formats.sh
docker exec -it spark-master bash /opt/demos/run_demo.sh iceberg/cow_vs_mor.py
```

`run_demo.sh` supplies the jars and catalog configuration each format needs, inferred
from the first path component, so a demo script contains only its own logic. Jar names
are resolved with globs rather than pinned versions, so every demo runs unchanged on
both the Spark 3.5 and Spark 4.1 images.

## What is here

| Script | Reproduces |
| ------ | ---------- |
| `e2e_test.sh` | Every service in the stack, end to end. The gate in front of publishing |
| `smoke_test_formats.sh` | Write, update and read in Hudi, Iceberg and Delta. Called by `e2e_test.sh` |
| `iceberg/cow_vs_mor.py` | The same `DELETE` under copy-on-write and merge-on-read, with the file accounting for each |
| `iceberg/time_travel.py` | Reading an old snapshot, rolling back a bad write, and the history entry the rollback leaves |
| `iceberg/schema_and_partition_evolution.py` | A rename and an added column that rewrite no data, and a partition spec change that leaves old files on the old spec |

Each script prints what it expects at the end, so a run that drifts from the post is
visible without going back to the post.

## Verified on

Both profiles, using the stack's own MinIO and Hive Metastore:

| | Spark 3.5.9 / Scala 2.12 | Spark 4.1.3 / Scala 2.13 |
| --- | --- | --- |
| Hudi | 1.1.1 | not shipped |
| Iceberg | 1.11.0 | 1.11.0 |
| Delta | 3.3.2 | not shipped |

The Spark 4.1 image carries Iceberg alone, because neither Hudi nor Delta has a build
that runs on Spark 4.1 yet — `hudi-spark4.1-bundle` 1.2.0 fails with
`NoClassDefFoundError org/apache/parquet/variant/VariantConverters` against Spark 4.1.3's
Parquet 1.16.0, and Delta 4.0.0 fails with
`NoSuchMethodError org.apache.spark.internal.LogKey.$init$`. `smoke_test_formats.sh`
reports a format with no jars as skipped rather than failed, so a clean run on 4.1 is
"passed 2, failed 0, skipped 2". Use the 3.5.9 profile to exercise all three.

One more note from running these: Hudi's **first** write to a new table initialises its
metadata table and takes appreciably longer than later writes — around twenty seconds
on a cold stack. A smoke test that runs immediately after `start` can see that as a
failure; re-running passes.
