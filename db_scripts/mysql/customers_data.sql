CREATE DATABASE IF NOT EXISTS inventory;
GRANT ALL PRIVILEGES ON inventory.* TO 'admin'@'%';

CREATE TABLE inventory.customers (
  id INTEGER NOT NULL AUTO_INCREMENT,
  first_name VARCHAR(255) NOT NULL,
  last_name VARCHAR(255) NOT NULL,
  email VARCHAR(255) NOT NULL,
  PRIMARY KEY (id)
) AUTO_INCREMENT=101;

INSERT INTO inventory.customers (first_name, last_name, email) VALUES ('Ranga','Reddy','ranga@gmail.com'),('Nishanth','Reddy','nish@gmail.com'),('Raja','Sekahr','raj@hotmail.com'),('Vasundra','','vasu@rediff.com');

SELECT * FROM inventory.customers;