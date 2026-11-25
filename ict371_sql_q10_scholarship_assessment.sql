-- ============================================================================
-- ICT371 Advanced Database
-- Question 10: Scholarship Application Assessment (50 marks)
-- PostgreSQL Implementation
-- ============================================================================

BEGIN;

DROP VIEW IF EXISTS v_approved_applicants CASCADE;
DROP TABLE IF EXISTS decision_audit CASCADE;
DROP TABLE IF EXISTS applications CASCADE;
DROP TABLE IF EXISTS students CASCADE;

-- ----------------------------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ----------------------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12, 2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5, 2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE NOT NULL,
    status             VARCHAR(15) NOT NULL DEFAULT 'PENDING'
                       CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(15) NOT NULL,
    new_status     VARCHAR(15) NOT NULL,
    changed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------------------------
-- (b) Function: fn_scholarship_eligible(p_age, p_income, p_mark) [6 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INTEGER,
    p_income NUMERIC(12, 2),
    p_mark   NUMERIC(5, 2)
) RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Eligibility inputs (age, income, mark) cannot be NULL.';
    END IF;

    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Invalid age (%): must be positive.', p_age;
    END IF;

    IF p_income < 0 THEN
        RAISE EXCEPTION 'Invalid monthly income (%): cannot be negative.', p_income;
    END IF;

    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Invalid average mark (%): must be between 0 and 100.', p_mark;
    END IF;

    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000.00)
       AND (p_mark >= 70.00);
END;
$$;

-- ----------------------------------------------------------------------------
-- (c) Procedure: pr_assess_application(p_application_id) [8 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age        INTEGER;
    v_income     NUMERIC(12, 2);
    v_mark       NUMERIC(5, 2);
    v_status     VARCHAR(15);
    v_new_status VARCHAR(15);
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
      INTO v_age, v_income, v_mark, v_status
      FROM applications
     WHERE application_id = p_application_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed with status %.',
            p_application_id, v_status;
    END IF;

    IF fn_scholarship_eligible(v_age, v_income, v_mark) THEN
        v_new_status := 'APPROVED';
    ELSE
        v_new_status := 'REJECTED';
    END IF;

    UPDATE applications
       SET status = v_new_status
     WHERE application_id = p_application_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- (d) Trigger: AFTER UPDATE row trigger on applications [8 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_applications_status_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, NOW());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_status_audit
AFTER UPDATE ON applications
FOR EACH ROW
EXECUTE FUNCTION trg_fn_applications_status_audit();

-- ----------------------------------------------------------------------------
-- (a cont.) Seed 3+ students and 6 PENDING applications (qualifying, failing, boundary)
-- ----------------------------------------------------------------------------
INSERT INTO students (student_number, full_name) VALUES
    ('202403001', 'Mwila Chilufya'),
    ('202403002', 'Taonga Banda'),
    ('202403003', 'Chisomo Phiri'),
    ('202403004', 'Kasonde Mulenga');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 20, 1800.00, 82.50, CURRENT_DATE - 6, 'PENDING'), -- Qualifying -> APPROVED
    (2, 18, 3000.00, 70.00, CURRENT_DATE - 5, 'PENDING'), -- Exact lower/upper boundary -> APPROVED
    (3, 25, 2950.00, 74.00, CURRENT_DATE - 4, 'PENDING'), -- Upper age boundary (25) -> APPROVED
    (4, 17, 1500.00, 88.00, CURRENT_DATE - 3, 'PENDING'), -- Age 17 (below 18) -> REJECTED
    (1, 22, 3000.01, 79.00, CURRENT_DATE - 2, 'PENDING'), -- Income K3,000.01 (> 3000) -> REJECTED
    (2, 21, 2200.00, 69.99, CURRENT_DATE - 1, 'PENDING'); -- Mark 69.99 (< 70) -> REJECTED

-- ----------------------------------------------------------------------------
-- (g) Scheduled job: pr_assess_pending() & pg_cron [6 marks]
-- (Defined before running so we can assess all 6 PENDING seed applications)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id
          FROM applications
         WHERE status = 'PENDING'
         ORDER BY submitted_on ASC, application_id ASC
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

-- Assess all PENDING applications and verify rerun is a safe no-op
CALL pr_assess_pending();
CALL pr_assess_pending();

-- ----------------------------------------------------------------------------
-- (e) View: v_approved_applicants [5 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED'
ORDER BY a.average_mark DESC, s.student_number ASC;

SELECT * FROM v_approved_applicants;

-- ----------------------------------------------------------------------------
-- (f) Index & EXPLAIN [5 marks]
-- Justification: A composite B-tree index on (status, submitted_on) filters
-- directly to a given application status (such as 'PENDING' or 'APPROVED')
-- and performs an ordered range scan over submitted_on dates.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_applications_status_submitted_on
    ON applications (status, submitted_on);

EXPLAIN
SELECT application_id, student_id, age_at_application, average_mark, submitted_on, status
  FROM applications
 WHERE status = 'APPROVED'
   AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

COMMIT;

-- Schedule every Monday at 08:00
SELECT cron.schedule(
    'scholarship_weekly_pending_assessment',
    '0 8 * * 1',
    $$CALL pr_assess_pending();$$
);
