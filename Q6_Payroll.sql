-- ICT371 Question 6: Monthly Payroll Processing (PostgreSQL + pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ===================== (a) Database ======================================
DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

CREATE TABLE employees (
    employee_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id INT           NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE          NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    CONSTRAINT ck_pay_month_start CHECK (EXTRACT(DAY FROM pay_month) = 1),   -- first day of a month
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id INT           NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP     NOT NULL DEFAULT now()
);

-- ===================== (b) Function ======================================
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic     NUMERIC(12,2);
    v_allowance NUMERIC(12,2);
    v_deduction NUMERIC(12,2);
    v_net       NUMERIC(12,2);
BEGIN
    SELECT basic_salary, allowance, deduction
    INTO v_basic, v_allowance, v_deduction
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := (v_basic + v_allowance) - v_deduction;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- ===================== (d) Trigger =======================================
CREATE OR REPLACE FUNCTION trg_salary_audit_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)   -- only real salary changes
EXECUTE FUNCTION trg_salary_audit_fn();

-- ===================== (c) Procedure =====================================
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    r       RECORD;
    v_net   NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'Payroll month must be the first day of a month (got %)', p_month;
    END IF;

    FOR r IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active
        ORDER BY employee_id
    LOOP
        v_net := fn_net_pay(r.employee_id);     -- raises (and aborts the whole CALL) if invalid

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows stay unchanged
    END LOOP;
END;
$$;

-- ===================== (a) Seed data =====================================
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Alice Mwila',  5000.00, 500.00, 600.00, TRUE),
    ('Bob Kasonde',  4000.00, 300.00, 400.00, TRUE),
    ('Carol Njovu',  6000.00, 700.00, 800.00, TRUE),
    ('Dan Mutale',   3500.00, 200.00, 300.00, FALSE);    -- inactive from the start

-- two payroll months
CALL pr_process_payroll('2026-09-01');
CALL pr_process_payroll('2026-10-01');

SELECT * FROM payroll ORDER BY pay_month, employee_id;    -- 3 employees x 2 months = 6 rows

-- Function tests
SELECT employee_id, fn_net_pay(employee_id) AS net FROM employees ORDER BY 1;
DO $$ BEGIN PERFORM fn_net_pay(99);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Procedure tests
DO $$ BEGIN CALL pr_process_payroll('2026-11-15');         -- not a month start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Reprocessing leaves existing rows unchanged, even after a salary change
UPDATE employees SET basic_salary = 5200 WHERE employee_id = 1;   -- trigger logs this
CALL pr_process_payroll('2026-10-01');
SELECT * FROM payroll WHERE employee_id = 1 ORDER BY pay_month;   -- October gross still 5500.00

-- An invalid calculation fails the WHOLE call (nothing is inserted for anyone)
DO $$
BEGIN
    INSERT INTO employees (full_name, basic_salary, allowance, deduction)
    VALUES ('Bad Calc', 100, 0, 500);                      -- net would be negative
    CALL pr_process_payroll('2026-11-01');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Whole call failed: %', SQLERRM;
END $$;
SELECT COUNT(*) AS november_rows FROM payroll WHERE pay_month = '2026-11-01';   -- 0
SELECT COUNT(*) AS employees_total FROM employees;                              -- 4 (test row rolled back)

-- Trigger tests
UPDATE employees SET basic_salary = basic_salary WHERE employee_id = 2;   -- no change -> no audit
UPDATE employees SET allowance = 350 WHERE employee_id = 2;               -- not salary -> no audit
SELECT * FROM salary_audit;                                               -- only Alice 5000 -> 5200

-- ===================== (e) View ==========================================
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id,
       e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;     -- no filter on active

UPDATE employees SET active = FALSE WHERE employee_id = 3;   -- Carol leaves
SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;   -- Carol's history is still there

-- ===================== (f) Index =========================================
-- The UNIQUE (employee_id, pay_month) index leads with employee_id, so it cannot
-- efficiently answer "all employees for one month". A single-column index on
-- pay_month does exactly that without duplicating the unique index.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;

SET enable_seqscan = off;    -- small demo table; force the plan to show the index
EXPLAIN
SELECT employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = '2026-10-01';
RESET enable_seqscan;

-- ===================== (g) Scheduled job =================================
-- 02:00 on the 1st of every month, processing the previous month
SELECT cron.schedule(
    'process_payroll_monthly',
    '0 2 1 * *',
    $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$
);

-- Inspect the job definition
SELECT jobid, jobname, schedule, command, active FROM cron.job;

-- Inspect run history (status, messages, timings)
SELECT jobid, runid, status, return_message, start_time, end_time
FROM cron.job_run_details
ORDER BY start_time DESC
LIMIT 10;
