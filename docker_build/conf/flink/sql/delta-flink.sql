set sql-client.execution.result-mode = tableau;

-- The SET above must be the first statement in the file: sql-client.sh -f only
-- supports the tableau result mode for the trailing SELECT, and Flink 1.17 fails to
-- recognise a leading SET that is preceded by comment lines.

CREATE CATALOG delta_catalog
    WITH ('type'         = 'delta-catalog',
          'catalog-type' = 'in-memory');

USE CATALOG delta_catalog;

CREATE DATABASE delta_db;
USE delta_db;

CREATE TABLE delta_table (
    id BIGINT,
    name STRING)
    WITH ('connector'  = 'delta',
          'table-path' = 's3a://warehouse/');

INSERT INTO delta_table VALUES (1, 'Ranga');

SELECT * FROM delta_table;