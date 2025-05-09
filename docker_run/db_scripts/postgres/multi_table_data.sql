CREATE DATABASE cdc_db;
\c cdc_db

-- Create the "customers" table
CREATE TABLE IF NOT EXISTS customers (
    customer_id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    phone VARCHAR(15) NOT NULL,
    city VARCHAR(255) NOT NULL,
    state VARCHAR(255) NOT NULL,
    country VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert sample data into the "customers" table
INSERT INTO customers (name, email, phone, city, state, country) VALUES
    ('Ranga Reddy', 'ranga@example.com', '9912345678', 'Bangalore', 'Karnataka', 'India'),
    ('Naveen Kumar', 'naveen.kumar@example.com', '555-987-6543', 'Los Angeles', 'CA', 'USA'),
    ('RajaSekhar Reddy', 'raja.sekhar@example.com', '7899345662', 'Annamayya', 'Andhrapradesh', 'India');

-- Select the customers data
SELECT * FROM customers;

-- Create the "orders" table
CREATE TABLE IF NOT EXISTS orders (
    order_id SERIAL PRIMARY KEY,
    customer_id INT REFERENCES customers(customer_id),
    order_date DATE DEFAULT CURRENT_TIMESTAMP,
    total_amount DECIMAL(10, 2) NOT NULL,
    status VARCHAR(20) NOT NULL
);

-- Insert sample data into the "orders" table
INSERT INTO orders (customer_id, order_date, total_amount, status) VALUES
    (1, '2024-10-01', 150.75, 'Completed'),
    (1, '2024-10-02', 200.00, 'Pending'),
    (2, '2024-10-02', 99.99, 'Completed'),
    (2, '2024-10-03', 250.50, 'Shipped'),
    (3, '2024-10-03', 300.00, 'Completed'),
    (1, '2024-10-01', 120.00, 'Pending'),
    (3, '2024-10-03', 450.00, 'Shipped');

-- Select the orders data
SELECT * FROM orders;