-- ICT371 Question 8: Transport Fleet Maintenance (PostgreSQL + pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ===================== (a) Database ======================================
DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

CREATE TABLE vehicles (
    vehicle_id             INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registration           VARCHAR(15) NOT NULL UNIQUE,
    current_odometer       INT         NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer  INT         NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id     INT  NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INT  NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INT  NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INT  NOT NULL,
    flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

-- ===================== (b) Function ======================================
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_km INT;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN v_km >= 5000;               -- exactly 5,000 km counts as due
END;
$$;

-- ===================== (d) Trigger (installed before trips are loaded) ===
CREATE OR REPLACE FUNCTION trg_trip_odometer_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INT;
BEGIN
    -- lock the vehicle row so two trips cannot start from the same odometer value
    SELECT current_odometer INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer IS DISTINCT FROM v_current THEN
        RAISE EXCEPTION 'Start odometer % does not match vehicle current odometer %',
                        NEW.start_odometer, v_current;
    END IF;

    IF NEW.end_odometer IS NULL OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end odometer % must exceed start odometer %',
                        NEW.end_odometer, NEW.start_odometer;
    END IF;

    UPDATE vehicles                    -- exactly once per inserted trip
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_trip_odometer_fn();

-- ===================== (c) Procedure =====================================
-- It only validates and inserts; the trigger moves the odometer.
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date and odometer readings must not be NULL';
    END IF;

    IF p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer (%) must be greater than start odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- ===================== (a) Seed data =====================================
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('BAE 1001', 12000, 10000),    -- 2,000 km since service: not due
    ('BAF 2002', 20500, 15000),    -- 5,500 km: due
    ('BAG 3003',  8000,  3000);    -- exactly 5,000 km: due (boundary)

-- six trips through the procedure; each starts at the vehicle's current odometer
CALL pr_record_trip(1, '2026-11-20', 12000, 12300);
CALL pr_record_trip(1, '2026-11-22', 12300, 12800);
CALL pr_record_trip(2, '2026-11-20', 20500, 20900);
CALL pr_record_trip(2, '2026-11-23', 20900, 21400);
CALL pr_record_trip(3, '2026-11-21',  8000,  8200);
CALL pr_record_trip(3, '2026-11-23',  8200,  8600);

SELECT * FROM trips ORDER BY trip_id;
SELECT * FROM vehicles ORDER BY vehicle_id;      -- odometers: 12800, 21400, 8600

-- Function tests
SELECT vehicle_id, fn_service_due(vehicle_id) AS due FROM vehicles ORDER BY 1;   -- f, t, t
DO $$ BEGIN PERFORM fn_service_due(99);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Procedure / trigger rejection tests
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12800, 12700);      -- end <= start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12000, 12500);      -- start not current
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(99, CURRENT_DATE, 0, 10);            -- unknown vehicle
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
            VALUES (1, CURRENT_DATE, 12800, 12800);                  -- direct SQL, bad mileage
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT vehicle_id, current_odometer FROM vehicles ORDER BY 1;        -- unchanged
SELECT COUNT(*) AS trip_rows FROM trips;                             -- still 6

-- ===================== (e) View ==========================================
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due ORDER BY registration;

-- ===================== (f) Index =========================================
-- Equality on vehicle_id, then range on trip_on: the index finds one vehicle's
-- trips and reads them in date order without touching other vehicles' rows.
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);
ANALYZE trips;

SET enable_seqscan = off;    -- small demo table; force the plan to show the index
EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 2
  AND trip_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;

-- ===================== (g) Scheduled job =================================
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    -- insert a new alert or update an existing one for every due vehicle
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service;     -- keeps the original flagged_on

    -- remove alerts for vehicles that are no longer due (serviced)
    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (
        SELECT 1
        FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
          AND v.current_odometer - v.last_service_odometer >= 5000
    );
END;
$$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;            -- vehicles 2 and 3

-- vehicle 2 is serviced -> its alert disappears on the next run; reruns never duplicate
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;
CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;            -- only vehicle 3

-- every Monday at 06:00
SELECT cron.schedule('refresh_service_alerts_weekly', '0 6 * * 1',
                     $$CALL pr_refresh_service_alerts()$$);
SELECT jobid, jobname, schedule, command FROM cron.job;
