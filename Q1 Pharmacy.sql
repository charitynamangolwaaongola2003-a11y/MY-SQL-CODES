-- ICT371 Question 1: Pharmacy Stock and Daily Sales (PostgreSQL + pg_cron)
--CREATE EXTENSION IF NOT EXISTS pg_cron;
-- ===================== (a) Database ======================================
DROP TABLE IF EXISTS daily_sales, stock_audit, sales, medicines CASCADE;

CREATE TABLE medicines (
    medicine_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_name VARCHAR(100)  NOT NULL UNIQUE,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INT           NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id INT           NOT NULL REFERENCES medicines(medicine_id),
    quantity    INT           NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),   -- price at time of sale
    sold_on     DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id INT       NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INT       NOT NULL,
    new_qty     INT       NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INT           NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- ===================== (b) Function ======================================
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be positive)', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- ===================== (d) Trigger (installed before sales are loaded) ===
CREATE OR REPLACE FUNCTION trg_stock_audit_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
    RETURN NEW;                       -- ignored for AFTER triggers
END;
$$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)   -- only when stock really changes
EXECUTE FUNCTION trg_stock_audit_fn();

-- ===================== (c) Procedure =====================================
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INT;
BEGIN
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date must not be NULL';
    END IF;

    PERFORM fn_sale_value(p_medicine_id, p_quantity);   -- validates medicine and quantity

    -- lock the row so concurrent sales cannot oversell
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: requested %, available %',
                        p_medicine_id, p_quantity, v_stock;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines                         -- deducted exactly once
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
    -- any exception above aborts the whole CALL, so both tables stay unchanged
END;
$$;

-- ===================== (a) Seed data =====================================
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 8.00,  50),
    ('ORS Sachet',        1.50,  30);

-- six valid sales loaded through the procedure
CALL pr_record_sale(1, 20, '2026-11-22');
CALL pr_record_sale(2, 10, '2026-11-22');
CALL pr_record_sale(3, 15, '2026-11-23');
CALL pr_record_sale(1, 15, '2026-11-23');
CALL pr_record_sale(2, 35, '2026-11-23');
CALL pr_record_sale(3, 10, '2026-11-23');

SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM stock_audit ORDER BY audit_id;     -- one row per stock change

-- Function tests
SELECT fn_sale_value(1, 4) AS value_of_4_paracetamol;      -- 10.00
DO $$ BEGIN PERFORM fn_sale_value(99, 1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_sale_value(1, 0);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Procedure failure test: oversell leaves everything unchanged
DO $$ BEGIN CALL pr_record_sale(2, 9999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT medicine_id, stock_qty FROM medicines ORDER BY 1;   -- unchanged
SELECT COUNT(*) AS sales_rows FROM sales;                  -- still 6

-- Trigger test: update that does not change stock creates no audit row
UPDATE medicines SET unit_price = unit_price WHERE medicine_id = 1;
SELECT COUNT(*) AS audit_rows FROM stock_audit;            -- unchanged

-- ===================== (e) View ==========================================
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id,
       medicine_name,
       unit_price,
       stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

CALL pr_record_sale(3, 2, CURRENT_DATE);        -- a sale, then query the view
SELECT * FROM v_low_stock ORDER BY medicine_id;

-- ===================== (f) Index =========================================
-- Equality column (medicine_id) first, range column (sold_on) second: the B-tree
-- jumps to one medicine and then scans a contiguous sold_on range, with no sort
-- and no scan of other medicines' rows.
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;

SET enable_seqscan = off;       -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN '2026-11-22' AND '2026-11-23';
RESET enable_seqscan;

-- ===================== (g) Scheduled job =================================
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    -- recomputed from the sales table and UPSERTed: a rerun replaces, never adds
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
    SET total_qty    = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_sales('2026-11-23');
CALL pr_refresh_sales('2026-11-23');            -- rerun: same figures, one row
SELECT * FROM daily_sales;

-- daily at 00:15 for the previous day
--SELECT cron.schedule('refresh_sales_daily', '15 0 * * *',
                    -- $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$);
--SELECT jobid, jobname, schedule, command FROM cron.job;