CREATE DATABASE IF NOT EXISTS inventory;
GRANT ALL PRIVILEGES ON inventory.* TO 'admin'@'%';

CREATE TABLE IF NOT EXISTS inventory.employees (
    id INT PRIMARY KEY NOT NULL,
    name VARCHAR(100) NOT NULL,
    age INT,
    salary DECIMAL(10, 2),
    department VARCHAR(50)
);

INSERT INTO inventory.employees (id, name, age, salary, department) VALUES (1, 'Ranga', 30, 50000.00, 'Sales');

SELECT * FROM inventory.employees;