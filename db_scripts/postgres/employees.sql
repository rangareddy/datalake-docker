CREATE TABLE public.employees (
    id INT PRIMARY KEY NOT NULL,
    name VARCHAR(100) NOT NULL,
    age INT,
    salary DECIMAL(10, 2),
    department VARCHAR(50)
);

ALTER TABLE public.employees REPLICA IDENTITY FULL;

INSERT INTO public.employees (id, name, age, salary, department) VALUES (1, 'Ranga', 30, 50000.00, 'Sales');
INSERT INTO public.employees (id, name, age, salary, department) VALUES (2, 'Nishanth', 7, 350000.00, 'Software');

SELECT * FROM public.employees;