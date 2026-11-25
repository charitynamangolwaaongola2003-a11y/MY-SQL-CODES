-- ICT371 Question 3: Library Returns and Overdue Fines (PostgreSQL + pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ===================== (a) Database ======================================
DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

CREATE TABLE books (
    book_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    book_id       INT           NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100)  NOT NULL,
    borrowed_on   DATE          NOT NULL,
    due_on        DATE          NOT NULL,
    returned_on   DATE          NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on),
    CONSTRAINT ck_return_after_borrow CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id          INT       NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE      NULL,
    new_returned_on  DATE      NULL,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT           NOT NULL DEFAULT 0,
    total_fine    NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- ===================== (b) Function ======================================
-- K2 per day after the due date; the fine stops growing once the loan is returned.
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'As-of date must not be NULL';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    -- earlier of p_as_of and returned_on (if a return date exists)
    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));

    RETURN 2 * GREATEST(v_end - v_due, 0);       -- date - date = whole days
END;
$$;

-- ===================== (d) Trigger =======================================
CREATE OR REPLACE FUNCTION trg_loan_audit_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)   -- NULL-safe change test
EXECUTE FUNCTION trg_loan_audit_fn();

-- ===================== (c) Procedure =====================================
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC(10,2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date must not be NULL';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrowed date %', p_returned_on, v_borrowed;
    END IF;

    -- the loan is still open, so passing the return date as "as of" gives the final fine
    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans                                  -- one statement: date and fine together
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- ===================== (a) Seed data =====================================
INSERT INTO books (title) VALUES
    ('Database Systems'),
    ('Operating Systems'),
    ('Computer Networks');

-- Six loans; dates are relative to today so the demo stays meaningful.
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Alice Mwale',  CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 1 open, overdue (16 days)
    (2, 'Bob Zulu',     CURRENT_DATE -  5, CURRENT_DATE +  9),  -- 2 open, on time
    (1, 'Carol Banda',  CURRENT_DATE - 20, CURRENT_DATE -  6),  -- 3 returned late
    (3, 'David Phiri',  CURRENT_DATE - 25, CURRENT_DATE - 10),  -- 4 open, overdue (10 days)
    (2, 'Eve Tembo',    CURRENT_DATE - 15, CURRENT_DATE -  5),  -- 5 returned on due date
    (3, 'Frank Lungu',  CURRENT_DATE -  2, CURRENT_DATE + 12);  -- 6 open, on time

CALL pr_return_loan(3, CURRENT_DATE - 3);   -- 3 days late  -> K6
CALL pr_return_loan(5, CURRENT_DATE - 5);   -- on due date  -> K0

SELECT * FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;           -- 2 rows

-- Function tests
SELECT loan_id, fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today FROM loans ORDER BY 1;
-- loan 1 -> 32, loan 4 -> 20, loan 3 -> 6 (frozen at return), loan 5 -> 0, loans 2 and 6 -> 0
SELECT fn_loan_fine(3, CURRENT_DATE + 100) AS returned_loan_does_not_grow;   -- still 6
DO $$ BEGIN PERFORM fn_loan_fine(99, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Procedure rejection tests
DO $$ BEGIN CALL pr_return_loan(99, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(3, CURRENT_DATE);                   -- already returned
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(1, CURRENT_DATE - 60);              -- before borrowed_on
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Trigger test: an UPDATE that leaves returned_on unchanged adds no audit row
UPDATE loans SET borrower_name = borrower_name WHERE loan_id = 3;
SELECT COUNT(*) AS audit_rows FROM loan_audit;                      -- still 2

-- ===================== (e) View ==========================================
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans ORDER BY loan_id;       -- loans 1 and 4

-- ===================== (f) Index =========================================
-- Partial index: only unreturned loans are indexed, so it stays small and holds
-- exactly the rows the search wants; book_id is the search key.
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;

SET enable_seqscan = off;     -- tiny demo table; force the plan to show the index
EXPLAIN
SELECT loan_id, borrower_name, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
RESET enable_seqscan;

-- ===================== (g) Scheduled job =================================
-- Counts loans that are unreturned as of p_as_of (never returned, or returned
-- after that date) and already past due, and sums their fines as of that date.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(2 * GREATEST(p_as_of - due_on, 0)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)
      AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE          -- same date is replaced on rerun
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);             -- rerun: still one row
SELECT * FROM overdue_summary;                     -- 2 loans, fine 32 + 20 = 52

-- daily at 00:10 for CURRENT_DATE
SELECT cron.schedule('refresh_overdue_daily', '10 0 * * *',
                     $$CALL pr_refresh_overdue(CURRENT_DATE)$$);
SELECT jobid, jobname, schedule, command FROM cron.job;
