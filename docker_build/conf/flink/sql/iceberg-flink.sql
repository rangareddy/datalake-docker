set sql-client.execution.result-mode = tableau;

CREATE CATALOG iceberg_hive_catalog WITH (
  'type'='iceberg',
  'catalog-type'='hive',
  'uri'='thrift://hive-metastore:9083',
  'property-version'='1',
  'hive-conf-dir' = '/opt/flink/conf',
  'warehouse'='s3a://warehouse/iceberg_hive_catalog'
);

USE CATALOG iceberg_hive_catalog;

CREATE DATABASE IF NOT EXISTS iceberg_db;

USE iceberg_db;

CREATE TABLE iceberg_table (
    id BIGINT,
    name STRING
);

SET execution.runtime-mode = batch;

INSERT INTO iceberg_table VALUES (1, 'Ranga');

SELECT * FROM iceberg_table;