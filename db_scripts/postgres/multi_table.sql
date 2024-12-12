CREATE TABLE public.employee_table1 (
    id INT PRIMARY KEY NOT NULL,
    name VARCHAR(100) NOT NULL,
    age INT,
    salary DECIMAL(10, 2),
    department VARCHAR(50),
    jod timestamp DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE public.employee_table1 REPLICA IDENTITY FULL;

INSERT INTO public.employee_table1 (id, name, age, salary, department) VALUES (1, 'Ranga', 35, 50000.00, 'Sales');
INSERT INTO public.employee_table1 (id, name, age, salary, department) VALUES (3, 'Meena', 31, 450000.00, 'Software');

SELECT * FROM public.employee_table1;

CREATE TABLE public.employee_table2 (
    id INT PRIMARY KEY NOT NULL,
    name VARCHAR(100) NOT NULL,
    age INT,
    salary DECIMAL(10, 2),
    department VARCHAR(50),
    jod timestamp DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE public.employee_table2 REPLICA IDENTITY FULL;

INSERT INTO public.employee_table2 (id, name, age, salary, department) VALUES (2, 'Nishanth', 7, 350000.00, 'Hardware');
INSERT INTO public.employee_table2 (id, name, age, salary, department) VALUES (4, 'Raja', 61, 70000.00, 'HR');

SELECT * FROM public.employee_table2;