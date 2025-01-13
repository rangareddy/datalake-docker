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