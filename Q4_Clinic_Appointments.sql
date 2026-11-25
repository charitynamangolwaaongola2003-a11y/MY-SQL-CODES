-- ICT371 Question 4: Clinic Appointment Scheduling (PostgreSQL + pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ===================== (a) Database ======================================
DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

CREATE TABLE patients (
    patient_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id      INT         NOT NULL REFERENCES patients(patient_id),
    doctor_id       INT         NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE        NOT NULL,
    slot_time       TIME        NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT ck_slot   CHECK (slot_time IN ('09:00'::time, '10:00'::time, '11:00'::time, '12:00'::time)),
    CONSTRAINT ck_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

-- Safety net against two sessions racing past the trigger's check.
-- (The BEFORE trigger below is still the primary rule and gives the friendly message.)
CREATE UNIQUE INDEX uq_doctor_slot_active
    ON appointments (doctor_id, appointment_day, slot_time)
    WHERE status <> 'CANCELLED';

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INT NOT NULL DEFAULT 0,
    attended_count  INT NOT NULL DEFAULT 0,
    cancelled_count INT NOT NULL DEFAULT 0
);

-- ===================== (b) Function ======================================
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INT;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count               -- COUNT is 0 when the day has no bookings
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$;

-- ===================== (d) Trigger =======================================
CREATE OR REPLACE FUNCTION trg_appointment_clash_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1
            FROM appointments a
            WHERE a.doctor_id       = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time       = NEW.slot_time
              AND a.status         <> 'CANCELLED'
              AND a.appointment_id IS DISTINCT FROM NEW.appointment_id   -- exclude the row being changed
        ) THEN
            RAISE EXCEPTION 'Doctor % already has an appointment on % at %',
                            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_appointment_clash_fn();

-- ===================== (c) Procedure =====================================
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    -- lock the doctor row so concurrent bookings for the same doctor are serialised
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date must not be in the past (got %)', p_day;
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN ('09:00'::time, '10:00'::time, '11:00'::time, '12:00'::time) THEN
        RAISE EXCEPTION 'Unsupported slot %. Use 09:00, 10:00, 11:00 or 12:00', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');   -- trigger checks the clash
END;
$$;

-- ===================== (a) Seed data =====================================
INSERT INTO patients (full_name) VALUES ('Peter Mumba'), ('Ruth Sakala'), ('Joseph Daka');
INSERT INTO doctors  (full_name) VALUES ('Dr. Chanda'), ('Dr. Mwansa'), ('Dr. Nkhoma');

-- Six appointments, none breaking the slot rule (trigger is already installed)
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
    (2, 1, CURRENT_DATE,     '10:00', 'BOOKED'),
    (3, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
    (1, 2, CURRENT_DATE + 1, '11:00', 'BOOKED'),
    (2, 3, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
    (3, 3, CURRENT_DATE - 1, '10:00', 'CANCELLED');

SELECT * FROM appointments ORDER BY appointment_id;

-- Function tests
SELECT fn_daily_load(1, CURRENT_DATE)      AS dr1_today;        -- 2
SELECT fn_daily_load(3, CURRENT_DATE - 1)  AS dr3_yesterday;    -- 1 (cancelled one ignored)
SELECT fn_daily_load(3, CURRENT_DATE + 30) AS no_bookings;      -- 0
DO $$ BEGIN PERFORM fn_daily_load(99, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Procedure tests
CALL pr_book_appointment(3, 1, CURRENT_DATE + 2, '12:00');      -- valid
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE, '09:00');       -- clash
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '09:00');   -- past date
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, '13:00');   -- bad slot
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(99, 1, CURRENT_DATE + 1, '09:00');  -- unknown patient
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Trigger UPDATE tests
UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 1;       -- OK: own row excluded from the search
DO $$ BEGIN UPDATE appointments SET slot_time = '10:00' WHERE appointment_id = 1;   -- clashes with #2
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
UPDATE appointments SET status = 'CANCELLED' WHERE appointment_id = 2;    -- free the slot
CALL pr_book_appointment(3, 1, CURRENT_DATE, '10:00');                    -- now allowed

-- ===================== (e) View ==========================================
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.appointment_id,
       p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time, doctor_name;

-- ===================== (f) Index =========================================
-- Non-unique composite index: the clinic's common question is "what does this
-- doctor have on this day?". Both columns are equality filters, so the index
-- jumps straight to the matching entries instead of scanning the whole table.
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

SET enable_seqscan = off;    -- small demo table; force the plan to show the index
EXPLAIN
SELECT appointment_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;
RESET enable_seqscan;

-- ===================== (g) Scheduled job =================================
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE          -- rerun replaces the date's row
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);    -- rerun: still one row
SELECT * FROM clinic_summary;                        -- booked 0, attended 1, cancelled 1

-- daily at 01:00 for the previous day
SELECT cron.schedule('refresh_clinic_summary_daily', '0 1 * * *',
                     $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);
SELECT jobid, jobname, schedule, command FROM cron.job;
