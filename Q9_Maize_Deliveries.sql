-- ICT371 Question 9: Farmer Cooperative Maize Deliveries (PostgreSQL + pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ===================== (a) Database ======================================
DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

CREATE TABLE farmers (
    farmer_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    farmer_id    INT           NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10,2) NOT NULL,      -- set by trigger
    total_value  NUMERIC(12,2) NOT NULL,      -- set by trigger
    delivered_on DATE          NOT NULL,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE
);
-- NOT NULL is checked after BEFORE triggers run, so the trigger can fill both columns.

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12,2) NOT NULL DEFAULT 0,
    total_value   NUMERIC(14,2) NOT NULL DEFAULT 0
);

-- ===================== (b) Function ======================================
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_rate NUMERIC(10,2);
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade must not be NULL';
    END IF;

    v_rate := CASE p_grade WHEN 'A' THEN 5.00
                           WHEN 'B' THEN 4.00
                           WHEN 'C' THEN 3.00
              END;                                  -- NULL for anything else

    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
    END IF;

    RETURN v_rate;
END;
$$;

-- ===================== (d) Trigger =======================================
CREATE OR REPLACE FUNCTION trg_delivery_pricing_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);              -- same rule for every route in
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_delivery_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_delivery_pricing_fn();

-- ===================== (c) Procedure =====================================
-- Only basic fields are inserted; the trigger supplies unit_rate and total_value.
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade VARCHAR, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;

    PERFORM fn_maize_rate(p_grade);                           -- rejects NULL / unsupported grade

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date must not be NULL';
    END IF;

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- ===================== (a) Seed data (after the trigger) ==================
INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Moses Lubinda'),
    ('F002', 'Alice Mukuka'),
    ('F003', 'Peter Sinkala');

-- direct SQL inserts: price columns are omitted and computed by the trigger
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
    (1, 'A', 100, '2026-11-20', TRUE),     -- 500
    (1, 'B',  80, '2026-11-21', FALSE),    -- 320
    (2, 'C', 150, '2026-11-21', TRUE),     -- 450
    (3, 'A',  60, '2026-11-22', FALSE);    -- 300

-- two more through the procedure
CALL pr_receive_delivery(2, 'B',  40, '2026-11-23');    -- 160
CALL pr_receive_delivery(3, 'C', 200, '2026-11-23');    -- 600

UPDATE deliveries SET is_paid = TRUE WHERE farmer_id = 2;   -- farmer 2 fully paid

SELECT * FROM deliveries ORDER BY delivery_id;

-- Function tests
SELECT fn_maize_rate('A') AS a, fn_maize_rate('B') AS b, fn_maize_rate('C') AS c;
DO $$ BEGIN PERFORM fn_maize_rate(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_maize_rate('D');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Procedure tests
DO $$ BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);   -- unknown farmer
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'Z', 10, CURRENT_DATE);    -- bad grade
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);    -- bad weight
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Trigger tests: direct SQL follows the same pricing rule
DO $$ BEGIN INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
            VALUES (1, 'A', 0, 99, 99, CURRENT_DATE);               -- non-positive weight
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
-- A hand-supplied wrong price is overwritten by the trigger:
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
VALUES (1, 'C', 10, 100, 1000, CURRENT_DATE, TRUE);
SELECT grade, weight_kg, unit_rate, total_value FROM deliveries ORDER BY delivery_id DESC LIMIT 1;  -- 3.00 / 30.00
DELETE FROM deliveries WHERE delivered_on = CURRENT_DATE;           -- remove the test row

-- ===================== (e) View ==========================================
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d
       ON d.farmer_id = f.farmer_id AND NOT d.is_paid   -- condition in ON keeps farmers with no unpaid rows
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;   -- 320, 0, 900

-- ===================== (f) Index =========================================
-- Equality on farmer_id first, range on delivered_on second: the index jumps to one
-- farmer's deliveries and reads the date range in order.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;

SET enable_seqscan = off;    -- small demo table; force the plan to show the index
EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN '2026-11-20' AND '2026-11-23';
RESET enable_seqscan;

-- ===================== (g) Scheduled job =================================
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day,
           COALESCE(SUM(weight_kg), 0),
           COALESCE(SUM(total_value), 0)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE          -- replace, never add again
    SET total_weight = EXCLUDED.total_weight,
        total_value  = EXCLUDED.total_value;
END;
$$;

CALL pr_refresh_purchases('2026-11-23');
CALL pr_refresh_purchases('2026-11-23');           -- rerun: same totals
SELECT * FROM daily_purchases;                     -- weight 240.00, value 760.00

-- daily at 01:30 for the previous day
SELECT cron.schedule('refresh_purchases_daily', '30 1 * * *',
                     $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);
SELECT jobid, jobname, schedule, command FROM cron.job;
