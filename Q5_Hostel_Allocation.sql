-- ICT371 Question 5: Hostel Room Allocation (PostgreSQL + pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ===================== (a) Database ======================================
DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

CREATE TABLE students (
    student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INT         NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id    INT         NOT NULL REFERENCES students(student_id),
    room_id       INT         NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE        NOT NULL,
    released_on   DATE        NULL,
    status        VARCHAR(10) NOT NULL,
    CONSTRAINT ck_alloc_status CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT ck_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
        OR (status = 'ENDED' AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

-- Safety net: at most one ACTIVE allocation per student, even under concurrency.
CREATE UNIQUE INDEX uq_one_active_per_student ON allocations (student_id) WHERE status = 'ACTIVE';

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INT  NOT NULL REFERENCES rooms(room_id),
    occupied_beds INT  NOT NULL,
    free_beds     INT  NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

-- ===================== (b) Function ======================================
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INT;
    v_active   INT;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active              -- ENDED rows are ignored
    FROM allocations
    WHERE room_id = p_room_id AND status = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$;

-- ===================== (d) Trigger =======================================
CREATE OR REPLACE FUNCTION trg_allocation_rules_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INT;
    v_occupied INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        -- lock the room row so two sessions cannot take the last bed together
        SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
        END IF;

        SELECT COUNT(*) INTO v_occupied
        FROM allocations
        WHERE room_id = NEW.room_id
          AND status = 'ACTIVE'
          AND allocation_id IS DISTINCT FROM NEW.allocation_id;   -- exclude the row being updated

        IF v_occupied >= v_capacity THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
        END IF;

        IF EXISTS (
            SELECT 1 FROM allocations
            WHERE student_id = NEW.student_id
              AND status = 'ACTIVE'
              AND allocation_id IS DISTINCT FROM NEW.allocation_id
        ) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_allocation_rules_fn();

-- ===================== (c) Procedure =====================================
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date must not be NULL';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;   -- lock room
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- ===================== (a) Seed data =====================================
INSERT INTO students (student_number, full_name) VALUES
    ('H2026001', 'Chipo Mulenga'),
    ('H2026002', 'Tawanda Moyo'),
    ('H2026003', 'Nomsa Dube'),
    ('H2026004', 'Kelvin Zimba'),
    ('H2026005', 'Esther Kunda');

INSERT INTO rooms (room_number, capacity) VALUES
    ('R101', 2),     -- will be full
    ('R102', 3),     -- will be partly occupied
    ('R103', 2);     -- will have no ACTIVE allocation (only history)

CALL pr_allocate_room(1, 1, '2026-09-01');
CALL pr_allocate_room(2, 1, '2026-09-01');     -- R101 now full
CALL pr_allocate_room(3, 2, '2026-09-02');     -- R102 partly occupied

-- history: an ENDED allocation does not occupy a bed
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 3, '2026-01-10', '2026-06-30', 'ENDED');

SELECT * FROM allocations ORDER BY allocation_id;

-- Function tests
SELECT room_id, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY 1;   -- 0, 2, 2
DO $$ BEGIN PERFORM fn_free_beds(99);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Procedure tests
DO $$ BEGIN CALL pr_allocate_room(5, 1, CURRENT_DATE);        -- full room
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(1, 3, CURRENT_DATE);        -- student 1 already ACTIVE
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(99, 3, CURRENT_DATE);       -- unknown student
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
CALL pr_allocate_room(4, 3, CURRENT_DATE);                    -- OK: ENDED history does not block

-- Trigger tests (direct SQL)
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status)
            VALUES (5, 1, CURRENT_DATE, 'ACTIVE');            -- room full
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status)
            VALUES (3, 3, CURRENT_DATE, 'ACTIVE');            -- student 3 already ACTIVE
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
-- Updating a row in a full room must not count itself:
UPDATE allocations SET allocated_on = allocated_on WHERE allocation_id = 1;   -- succeeds

-- ===================== (e) View ==========================================
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id AND a.status = 'ACTIVE'   -- filter in ON keeps empty rooms
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_id;

-- ===================== (f) Index =========================================
-- Partial index on room_id covering only ACTIVE rows: capacity checks, the free-bed
-- function, the trigger and the occupancy view all count ACTIVE rows per room, and
-- ENDED history (which grows forever) is kept out of the index.
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;

SET enable_seqscan = off;    -- small demo table; force the plan to show the index
EXPLAIN
SELECT allocation_id, student_id
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';
RESET enable_seqscan;

-- ===================== (g) Scheduled job =================================
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE,
           r.room_id,
           COUNT(a.allocation_id),
           r.capacity - COUNT(a.allocation_id)
    FROM rooms r
    LEFT JOIN allocations a
           ON a.room_id = r.room_id AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE      -- one row per date and room
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();                            -- rerun: values replaced, no duplicates
SELECT * FROM occupancy_snapshot ORDER BY room_id;

-- daily at 23:55
SELECT cron.schedule('refresh_occupancy_daily', '55 23 * * *',
                     $$CALL pr_refresh_occupancy()$$);
SELECT jobid, jobname, schedule, command FROM cron.job;
