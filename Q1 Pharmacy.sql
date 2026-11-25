-- ICT371 Question 2: University Fee Payment
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ===================== (a) Database ======================================
DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

CREATE TABLE students (
    student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(20)   NOT NULL UNIQUE,
    full_name      VARCHAR(100)  NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id INT           NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id INT           NOT NULL REFERENCES payments(payment_id),
    student_id INT           NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP     NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INT           NOT NULL DEFAULT 0,
    total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- ===================== (b) Function ======================================
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee  NUMERIC(12,2);
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid     -- 0 when no payments exist
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;
END;
$$;

-- ===================== (d) Trigger =======================================
CREATE OR REPLACE FUNCTION trg_payment_audit_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_payment_audit_fn();

-- ===================== (c) Procedure =====================================
-- Note: the procedure does NOT write to payment_audit; the trigger does.
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive (got %)', p_amount;
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date must not be NULL';
    END IF;

    -- lock the student row so two simultaneous payments cannot both overpay
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % for student %',
                        p_amount, v_balance, p_student_id;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)   -- fee_due is never changed
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- ===================== (a) Seed data =====================================
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('S2026001', 'Mary Banda',   5000.00),   -- will owe 2000
    ('S2026002', 'John Phiri',   3000.00),   -- will be fully settled
    ('S2026003', 'Grace Tembo',  4000.00);   -- no payments at all

-- six payments (loaded through the procedure so the trigger audits them)
CALL pr_receive_payment(1, 1500.00, '2026-11-20');
CALL pr_receive_payment(1, 1000.00, '2026-11-21');
CALL pr_receive_payment(1,  500.00, '2026-11-23');
CALL pr_receive_payment(2, 1000.00, '2026-11-20');
CALL pr_receive_payment(2,  500.00, '2026-11-23');
CALL pr_receive_payment(2, 1500.00, '2026-11-23');

SELECT * FROM payments ORDER BY payment_id;
SELECT * FROM payment_audit ORDER BY audit_id;           -- 6 rows written by trigger

-- Function tests
SELECT student_id, fn_fee_balance(student_id) AS balance FROM students ORDER BY 1;
-- expected 2000, 0, 4000 (student 3 has no payments -> full fee)
DO $$ BEGIN PERFORM fn_fee_balance(99);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Procedure rejection tests (each leaves payments unchanged)
DO $$ BEGIN CALL pr_receive_payment(1, NULL, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, 0, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, -50, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, 2500, CURRENT_DATE);        -- balance is only 2000
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT COUNT(*) AS payments_rows FROM payments;                    -- still 6

-- ===================== (e) View ==========================================
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;     -- settled students excluded

SELECT * FROM v_fee_balances ORDER BY student_number;   -- S2026001 and S2026003 only

-- ===================== (f) Index =========================================
-- Equality on student_id first, range on paid_on second: one index lookup finds
-- that student's payments and returns them already in paid_on order.
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;

SET enable_seqscan = off;      -- small demo table; force the plan to show the index
EXPLAIN
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN '2026-11-20' AND '2026-11-23';
RESET enable_seqscan;

-- ===================== (g) Scheduled job =================================
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE      -- replace an existing summary on rerun
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections('2026-11-23');
CALL pr_refresh_collections('2026-11-23');       -- rerun: still one row, same totals
SELECT * FROM daily_collections;                 -- 3 payments, 3000.00

-- daily at 01:00 for the previous day
--SELECT cron.schedule('refresh_collections_daily', '0 1 * * *',
                     --$$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);
--SELECT jobid, jobname, schedule, command FROM cron.job;