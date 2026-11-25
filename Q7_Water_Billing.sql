-- ICT371 Question 7: Water Meter Readings and Billing (PostgreSQL + pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ===================== (a) Database ======================================
DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

CREATE TABLE customers (
    customer_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id      INT           NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE          NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT ck_reading_month_start CHECK (EXTRACT(DAY FROM reading_month) = 1),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reading_id  INT           NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE          NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL DEFAULT 0
);

-- ===================== (b) Function ======================================
-- First 10 units at K5, units above 10 at K8.
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_units IS NULL THEN
        RAISE EXCEPTION 'Consumption must not be NULL';
    END IF;
    IF p_units < 0 THEN
        RAISE EXCEPTION 'Consumption must not be negative (got %)', p_units;
    END IF;

    RETURN ROUND(LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8, 2);
END;
$$;

-- ===================== (d) Trigger =======================================
CREATE OR REPLACE FUNCTION trg_reading_check_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;            -- raising above means the row is never stored
END;
$$;

CREATE TRIGGER trg_reading_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_reading_check_fn();

-- ===================== (c) Procedure =====================================
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev   NUMERIC(10,2);
    v_curr   NUMERIC(10,2);
    v_charge NUMERIC(12,2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date must not be NULL';
    END IF;

    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_charge := fn_water_charge(v_curr - v_prev);      -- consumption = current - previous

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

-- ===================== (a) Seed data =====================================
INSERT INTO customers (full_name) VALUES ('Agnes Kalaba'), ('Brian Hamoonga'), ('Chileshe Musonda');

-- Six readings (trigger already installed): 0, 8, 10, 10, 15 and 17 units
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, '2026-09-01', 100,  100),    -- 1: 0 units  -> K0
    (1, '2026-10-01', 100,  110),    -- 2: 10 units -> K50
    (2, '2026-09-01',  50,   58),    -- 3: 8 units  -> K40
    (2, '2026-10-01',  58,   75),    -- 4: 17 units -> K106
    (3, '2026-09-01', 200,  215),    -- 5: 15 units -> K90
    (3, '2026-10-01', 215,  225);    -- 6: 10 units -> K50

-- Bills through the procedure; some due dates in the past, some in the future
CALL pr_generate_bill(1, CURRENT_DATE - 30);
CALL pr_generate_bill(2, CURRENT_DATE + 14);
CALL pr_generate_bill(3, CURRENT_DATE - 30);
CALL pr_generate_bill(4, CURRENT_DATE - 3);
CALL pr_generate_bill(5, CURRENT_DATE - 30);
CALL pr_generate_bill(6, CURRENT_DATE + 14);

-- some payments
UPDATE bills SET amount_paid = 40 WHERE bill_id = 3;    -- bill 3 fully paid
UPDATE bills SET amount_paid = 30 WHERE bill_id = 5;    -- bill 5 partly paid (60 outstanding)
UPDATE bills SET amount_paid = 20 WHERE bill_id = 2;    -- bill 2 partly paid, not yet due

SELECT * FROM readings ORDER BY reading_id;
SELECT * FROM bills ORDER BY bill_id;

-- Function tests
SELECT fn_water_charge(0)    AS zero,       -- 0.00
       fn_water_charge(10)   AS exactly_10, -- 50.00
       fn_water_charge(17)   AS above_10,   -- 106.00
       fn_water_charge(12.5) AS fractional; -- 50 + 2.5*8 = 70.00
DO $$ BEGIN PERFORM fn_water_charge(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(-1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Procedure tests
DO $$ BEGIN CALL pr_generate_bill(99, CURRENT_DATE);        -- unknown reading
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(1, CURRENT_DATE);         -- already billed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Trigger tests: rejected rows are not stored
DO $$ BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
            VALUES (1, '2026-11-01', 110, 100);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN UPDATE readings SET current_reading = 40 WHERE reading_id = 3;   -- 40 < previous 50
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT COUNT(*) AS readings_rows FROM readings;             -- still 6

-- ===================== (e) View ==========================================
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills ORDER BY due_on;     -- bill 5 (60.00) and bill 4 (106.00)

-- ===================== (f) Index =========================================
-- Partial index on due_on holding only bills that are not fully paid. Overdue
-- searches are date-based and only ever want unpaid bills; settled bills (the
-- majority over time) are kept out, so the index stays small and fast.
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;

SET enable_seqscan = off;    -- small demo table; force the plan to show the index
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- ===================== (g) Scheduled job =================================
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE,
           COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE          -- same date is replaced on rerun
    SET total_due = EXCLUDED.total_due;
END;
$$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();                     -- rerun: replaced, not doubled
SELECT * FROM receivable_snapshot;                 -- 30 + 106 + 60 + 50 = 246.00

-- daily at 00:30
SELECT cron.schedule('refresh_receivables_daily', '30 0 * * *',
                     $$CALL pr_refresh_receivables()$$);
SELECT jobid, jobname, schedule, command FROM cron.job;
