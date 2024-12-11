CREATE SCHEMA IF NOT EXISTS inventory AUTHORIZATION postgres;

CREATE TABLE inventory.employees (
    id INT PRIMARY KEY NOT NULL,
    name VARCHAR(100) NOT NULL,
    age INT,
    salary DECIMAL(10, 2),
    department VARCHAR(50)
);

ALTER TABLE inventory.employees REPLICA IDENTITY FULL;

INSERT INTO inventory.employees (id, name, age, salary, department) VALUES (1, 'Ranga', 30, 50000.00, 'Sales');