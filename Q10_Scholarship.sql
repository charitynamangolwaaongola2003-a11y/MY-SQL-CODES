-- ICT371 Question 10: Scholarship Application Assessment (PostgreSQL + pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ===================== (a) Database ======================================
DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

CREATE TABLE students (
    student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id          INT           NOT NULL REFERENCES students(student_id),
    age_at_application  INT           NOT NULL CHECK (age_at_application > 0),
    monthly_income      NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark        NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on        DATE          NOT NULL,
    status              VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id INT         NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP   NOT NULL DEFAULT now()
);

-- ===================== (b) Function ======================================
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive (got %)', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must not be negative (got %)', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25      -- inclusive
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$;

-- ===================== (d) Trigger =======================================
CREATE OR REPLACE FUNCTION trg_decision_audit_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)     -- unchanged status: no audit row
EXECUTE FUNCTION trg_decision_audit_fn();

-- ===================== (c) Procedure =====================================
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_status   VARCHAR(10);
    v_age      INT;
    v_income   NUMERIC(10,2);
    v_mark     NUMERIC(5,2);
    v_eligible BOOLEAN;
BEGIN
    SELECT status, age_at_application, monthly_income, average_mark
    INTO v_status, v_age, v_income, v_mark
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;                                    -- stops two sessions assessing the same row

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status %)',
                        p_application_id, v_status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);

    UPDATE applications
    SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- ===================== (a) Seed data =====================================
INSERT INTO students (student_number, full_name) VALUES
    ('SC2026001', 'Lilian Chola'),
    ('SC2026002', 'Mwape Sichone'),
    ('SC2026003', 'Joyce Kaunda');

-- Six PENDING applications across three students
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
    (1, 20, 1500.00, 80.00, '2026-11-01'),   -- 1 qualifies (clearly)
    (1, 18, 3000.00, 70.00, '2026-11-03'),   -- 2 qualifies (every limit exactly on the boundary)
    (2, 25, 2500.00, 75.50, '2026-11-05'),   -- 3 qualifies (upper age boundary)
    (2, 26, 1000.00, 90.00, '2026-11-08'),   -- 4 fails: age 26
    (3, 22, 3000.01, 85.00, '2026-11-10'),   -- 5 fails: income just above K3,000
    (3, 21, 2000.00, 69.99, '2026-11-12');   -- 6 fails: mark just below 70

SELECT * FROM applications ORDER BY application_id;

-- Function tests
SELECT fn_scholarship_eligible(20, 1500, 80)     AS clear_yes,        -- t
       fn_scholarship_eligible(18, 3000, 70)     AS lower_boundaries, -- t
       fn_scholarship_eligible(25, 3000, 100)    AS upper_age,        -- t
       fn_scholarship_eligible(17, 1000, 90)     AS too_young,        -- f
       fn_scholarship_eligible(26, 1000, 90)     AS too_old,          -- f
       fn_scholarship_eligible(20, 3000.01, 90)  AS income_over,      -- f
       fn_scholarship_eligible(20, 1000, 69.99)  AS mark_under;       -- f
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 100, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(0, 100, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 100, 101);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Procedure tests
CALL pr_assess_application(1);                                   -- APPROVED
DO $$ BEGIN CALL pr_assess_application(1);                       -- already assessed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(99);                      -- unknown
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Trigger test: an update that leaves status unchanged writes no audit row
UPDATE applications SET status = status WHERE application_id = 2;
SELECT * FROM decision_audit;                                    -- one row: application 1

-- ===================== (e) View ==========================================
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';                     -- household income deliberately omitted

-- ===================== (g) Scheduled job (needs pr_assess_application) ====
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'                 -- completed applications are never touched
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();                        -- assesses applications 2 to 6
CALL pr_assess_pending();                        -- rerun: nothing pending, nothing changes

SELECT application_id, status FROM applications ORDER BY application_id;
-- 1,2,3 APPROVED; 4,5,6 REJECTED
SELECT COUNT(*) AS audit_rows FROM decision_audit;               -- 6 (one per application, no duplicates)
SELECT * FROM v_approved_applicants ORDER BY student_number, average_mark;

-- every Monday at 08:00
SELECT cron.schedule('assess_pending_weekly', '0 8 * * 1',
                     $$CALL pr_assess_pending()$$);
SELECT jobid, jobname, schedule, command FROM cron.job;

-- ===================== (f) Index =========================================
-- Equality on status first, range on submitted_on second: the index lands on one
-- status and reads the date range in order (PENDING queues are searched this way).
CREATE INDEX idx_app_status_submitted ON applications (status, submitted_on);
ANALYZE applications;

SET enable_seqscan = off;    -- small demo table; force the plan to show the index
EXPLAIN
SELECT application_id, student_id, submitted_on
FROM applications
WHERE status = 'APPROVED'
  AND submitted_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;
