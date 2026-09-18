-- One-time setup for the public PM Agents CI/CD + eval demo.
-- Run as ACCOUNTADMIN (or a role that can create databases, roles, and users).
--
-- Creates:
--   PM_AGENTS_DEMO.APP            demo database + schema
--   PM_AGENTS_CI                  least-privilege CI / eval role
--   SIGNUPS / TOUCHPOINTS / USER_ACTIVITY   synthetic growth tables
--   EVAL_QUESTIONS                eval input table
--   GROWTH_AGENT_EVAL             registered Cortex Agent dataset
--   EVAL_CONFIG_STAGE             stage for evaluation YAML
--
-- After this script:
--   1. Register a public key on PM_AGENTS_CI_USER (see README).
--   2. Store SNOWFLAKE_ACCOUNT / SNOWFLAKE_USER / SNOWFLAKE_PRIVATE_KEY as GitHub secrets.
--   3. Push to main (or run the workflow) to deploy the semantic view + first agent version.

USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS PM_AGENTS_DEMO;
CREATE SCHEMA IF NOT EXISTS PM_AGENTS_DEMO.APP;
CREATE WAREHOUSE IF NOT EXISTS COMPUTE_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;

CREATE ROLE IF NOT EXISTS PM_AGENTS_CI;

GRANT USAGE ON DATABASE PM_AGENTS_DEMO TO ROLE PM_AGENTS_CI;
GRANT USAGE, CREATE TABLE, CREATE VIEW, CREATE SEMANTIC VIEW, CREATE AGENT,
      CREATE STAGE, CREATE FILE FORMAT, CREATE TASK, CREATE DATASET, MONITOR
  ON SCHEMA PM_AGENTS_DEMO.APP TO ROLE PM_AGENTS_CI;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE PM_AGENTS_CI;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE PM_AGENTS_CI;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE PM_AGENTS_CI;

CREATE USER IF NOT EXISTS PM_AGENTS_CI_USER
  DEFAULT_ROLE = PM_AGENTS_CI
  DEFAULT_WAREHOUSE = COMPUTE_WH
  TYPE = SERVICE;

GRANT ROLE PM_AGENTS_CI TO USER PM_AGENTS_CI_USER;
GRANT ROLE PM_AGENTS_CI TO ROLE ACCOUNTADMIN;

USE ROLE PM_AGENTS_CI;
USE DATABASE PM_AGENTS_DEMO;
USE SCHEMA APP;
USE WAREHOUSE COMPUTE_WH;

CREATE OR REPLACE TABLE SIGNUPS (
  SIGNUP_ID VARCHAR(36),
  USER_EMAIL VARCHAR(255),
  SIGNUP_DATE DATE,
  SIGNUP_CHANNEL VARCHAR(50),
  COUNTRY VARCHAR(100),
  DEVICE_TYPE VARCHAR(20),
  PLAN_TYPE VARCHAR(20),
  CONVERTED_TO_PAID BOOLEAN,
  MRR_AMOUNT NUMBER(10, 2),
  REFERRAL_SOURCE VARCHAR(100)
);

INSERT INTO SIGNUPS VALUES
  ('s-001', 'ava@example.com',   DATE '2025-01-08', 'organic_search',  'United States', 'desktop', 'professional', TRUE,  49.00, NULL),
  ('s-002', 'ben@example.com',   DATE '2025-01-12', 'paid_search',     'United States', 'mobile',  'starter',      TRUE,  19.00, NULL),
  ('s-003', 'cara@example.com',  DATE '2025-01-18', 'social_media',    'Canada',        'desktop', 'free',         FALSE,  0.00, NULL),
  ('s-004', 'diego@example.com', DATE '2025-01-22', 'referral',        'United Kingdom','desktop', 'enterprise',   TRUE, 199.00, 'partner-acme'),
  ('s-005', 'emma@example.com',  DATE '2025-01-28', 'direct',          'United States', 'tablet',  'starter',      TRUE,  19.00, NULL),
  ('s-006', 'finn@example.com',  DATE '2025-02-03', 'paid_search',     'Germany',       'desktop', 'professional', TRUE,  49.00, NULL),
  ('s-007', 'gia@example.com',   DATE '2025-02-09', 'organic_search',  'United States', 'mobile',  'free',         FALSE,  0.00, NULL),
  ('s-008', 'hugo@example.com',  DATE '2025-02-14', 'email_marketing', 'Canada',        'desktop', 'starter',      TRUE,  19.00, NULL),
  ('s-009', 'ivy@example.com',   DATE '2025-02-20', 'social_media',    'United States', 'mobile',  'professional', TRUE,  49.00, NULL),
  ('s-010', 'jake@example.com',  DATE '2025-02-25', 'paid_search',     'Australia',     'desktop', 'free',         FALSE,  0.00, NULL),
  ('s-011', 'kira@example.com',  DATE '2025-03-04', 'organic_search',  'United States', 'desktop', 'enterprise',   TRUE, 199.00, NULL),
  ('s-012', 'leo@example.com',   DATE '2025-03-11', 'referral',        'France',        'mobile',  'starter',      TRUE,  19.00, 'partner-acme'),
  ('s-013', 'mia@example.com',   DATE '2025-03-16', 'direct',          'United States', 'desktop', 'professional', TRUE,  49.00, NULL),
  ('s-014', 'noah@example.com',  DATE '2025-03-21', 'paid_search',     'United Kingdom','tablet',  'free',         FALSE,  0.00, NULL),
  ('s-015', 'olga@example.com',  DATE '2025-03-27', 'email_marketing', 'Germany',       'desktop', 'starter',      TRUE,  19.00, NULL),
  -- Apr 2025: 4 signups (slight uptick)
  ('s-016', 'paul@example.com',  DATE '2025-04-03', 'organic_search',  'United States', 'desktop', 'professional', TRUE,  49.00, NULL),
  ('s-017', 'quinn@example.com', DATE '2025-04-11', 'paid_search',     'Canada',        'mobile',  'starter',      TRUE,  19.00, NULL),
  ('s-018', 'rosa@example.com',  DATE '2025-04-18', 'social_media',    'Germany',       'desktop', 'free',         FALSE,  0.00, NULL),
  ('s-019', 'sam@example.com',   DATE '2025-04-25', 'organic_search',  'United States', 'tablet',  'enterprise',   TRUE, 199.00, NULL),
  -- May 2025: 3 signups (dip)
  ('s-020', 'tara@example.com',  DATE '2025-05-07', 'paid_search',     'United Kingdom','desktop', 'professional', TRUE,  49.00, NULL),
  ('s-021', 'ursa@example.com',  DATE '2025-05-15', 'direct',          'Australia',     'mobile',  'free',         FALSE,  0.00, NULL),
  ('s-022', 'vera@example.com',  DATE '2025-05-22', 'email_marketing', 'United States', 'desktop', 'starter',      TRUE,  19.00, NULL),
  -- Jun 2025: 9 signups (strong growth)
  ('s-023', 'will@example.com',  DATE '2025-06-02', 'organic_search',  'United States', 'desktop', 'professional', TRUE,  49.00, NULL),
  ('s-024', 'xena@example.com',  DATE '2025-06-05', 'paid_search',     'Canada',        'mobile',  'enterprise',   TRUE, 199.00, NULL),
  ('s-025', 'yuki@example.com',  DATE '2025-06-09', 'social_media',    'Japan',         'desktop', 'starter',      TRUE,  19.00, NULL),
  ('s-026', 'zara@example.com',  DATE '2025-06-12', 'referral',        'United States', 'mobile',  'free',         FALSE,  0.00, 'partner-acme'),
  ('s-027', 'adam@example.com',  DATE '2025-06-16', 'organic_search',  'Germany',       'desktop', 'professional', TRUE,  49.00, NULL),
  ('s-028', 'beth@example.com',  DATE '2025-06-20', 'paid_search',     'United States', 'tablet',  'starter',      TRUE,  19.00, NULL),
  ('s-029', 'carl@example.com',  DATE '2025-06-24', 'social_media',    'France',        'mobile',  'free',         FALSE,  0.00, NULL),
  ('s-030', 'dana@example.com',  DATE '2025-06-27', 'email_marketing', 'United Kingdom','desktop', 'enterprise',   TRUE, 199.00, NULL),
  ('s-031', 'evan@example.com',  DATE '2025-06-30', 'direct',          'Australia',     'mobile',  'professional', TRUE,  49.00, NULL),
  -- Jul 2025: 6 signups
  ('s-032', 'faye@example.com',  DATE '2025-07-04', 'organic_search',  'United States', 'desktop', 'starter',      TRUE,  19.00, NULL),
  ('s-033', 'gene@example.com',  DATE '2025-07-10', 'paid_search',     'Canada',        'mobile',  'professional', TRUE,  49.00, NULL),
  ('s-034', 'hana@example.com',  DATE '2025-07-15', 'referral',        'Japan',         'desktop', 'free',         FALSE,  0.00, 'partner-beta'),
  ('s-035', 'ivan@example.com',  DATE '2025-07-19', 'social_media',    'Germany',       'tablet',  'starter',      TRUE,  19.00, NULL),
  ('s-036', 'jana@example.com',  DATE '2025-07-24', 'organic_search',  'United States', 'desktop', 'enterprise',   TRUE, 199.00, NULL),
  ('s-037', 'karl@example.com',  DATE '2025-07-29', 'direct',          'United Kingdom','mobile',  'professional', TRUE,  49.00, NULL),
  -- Aug 2025: 12 signups (new high)
  ('s-038', 'lena@example.com',  DATE '2025-08-02', 'paid_search',     'United States', 'desktop', 'starter',      TRUE,  19.00, NULL),
  ('s-039', 'mike@example.com',  DATE '2025-08-05', 'organic_search',  'Canada',        'mobile',  'professional', TRUE,  49.00, NULL),
  ('s-040', 'nora@example.com',  DATE '2025-08-07', 'social_media',    'France',        'desktop', 'free',         FALSE,  0.00, NULL),
  ('s-041', 'otto@example.com',  DATE '2025-08-09', 'paid_search',     'Australia',     'mobile',  'enterprise',   TRUE, 199.00, NULL),
  ('s-042', 'pia@example.com',   DATE '2025-08-12', 'email_marketing', 'Germany',       'desktop', 'starter',      TRUE,  19.00, NULL),
  ('s-043', 'remy@example.com',  DATE '2025-08-14', 'organic_search',  'United States', 'tablet',  'professional', TRUE,  49.00, NULL),
  ('s-044', 'suki@example.com',  DATE '2025-08-17', 'referral',        'Japan',         'mobile',  'free',         FALSE,  0.00, 'partner-acme'),
  ('s-045', 'theo@example.com',  DATE '2025-08-20', 'direct',          'United States', 'desktop', 'enterprise',   TRUE, 199.00, NULL),
  ('s-046', 'uma@example.com',   DATE '2025-08-22', 'paid_search',     'United Kingdom','mobile',  'starter',      TRUE,  19.00, NULL),
  ('s-047', 'vince@example.com', DATE '2025-08-25', 'organic_search',  'Canada',        'desktop', 'professional', TRUE,  49.00, NULL),
  ('s-048', 'wade@example.com',  DATE '2025-08-27', 'social_media',    'United States', 'mobile',  'free',         FALSE,  0.00, NULL),
  ('s-049', 'xiao@example.com',  DATE '2025-08-30', 'paid_search',     'Germany',       'desktop', 'enterprise',   TRUE, 199.00, NULL);

CREATE OR REPLACE TABLE TOUCHPOINTS (
  TOUCHPOINT_ID VARCHAR(36),
  USER_EMAIL VARCHAR(255),
  TOUCHPOINT_DATE DATE,
  CHANNEL VARCHAR(50),
  CAMPAIGN_NAME VARCHAR(100),
  CONTENT_TYPE VARCHAR(50),
  AD_SPEND NUMBER(10, 2),
  CLICKS NUMBER(10, 0),
  IMPRESSIONS NUMBER(12, 0)
);

INSERT INTO TOUCHPOINTS VALUES
  ('t-001', 'ava@example.com',   DATE '2025-01-06', 'organic_search',  'brand_q1',     'blog',     0.00,   12,  400),
  ('t-002', 'ben@example.com',   DATE '2025-01-11', 'paid_search',     'search_jan',   'search', 120.00,   18,  900),
  ('t-003', 'cara@example.com',  DATE '2025-01-17', 'social_media',    'social_jan',   'video',   80.00,    9,  700),
  ('t-004', 'diego@example.com', DATE '2025-01-20', 'referral',        'partner_q1',   'email',    0.00,    3,   50),
  ('t-005', 'emma@example.com',  DATE '2025-01-27', 'direct',          'none',         'none',     0.00,    1,   10),
  ('t-006', 'finn@example.com',  DATE '2025-02-01', 'paid_search',     'search_feb',   'search', 150.00,   21, 1100),
  ('t-007', 'gia@example.com',   DATE '2025-02-08', 'organic_search',  'brand_q1',     'blog',     0.00,    8,  350),
  ('t-008', 'hugo@example.com',  DATE '2025-02-12', 'email_marketing', 'nurture_feb',  'email',   40.00,   14,  600),
  ('t-009', 'ivy@example.com',   DATE '2025-02-18', 'social_media',    'social_feb',   'image',   95.00,   16,  850),
  ('t-010', 'jake@example.com',  DATE '2025-02-24', 'paid_search',     'search_feb',   'search', 110.00,   11,  800),
  ('t-011', 'kira@example.com',  DATE '2025-03-02', 'organic_search',  'brand_q1',     'blog',     0.00,   10,  420),
  ('t-012', 'leo@example.com',   DATE '2025-03-09', 'referral',        'partner_q1',   'email',    0.00,    4,   60),
  ('t-013', 'mia@example.com',   DATE '2025-03-15', 'direct',          'none',         'none',     0.00,    1,   12),
  ('t-014', 'noah@example.com',  DATE '2025-03-20', 'paid_search',     'search_mar',   'search', 130.00,   13,  950),
  ('t-015', 'olga@example.com',  DATE '2025-03-26', 'email_marketing', 'nurture_mar',  'email',   35.00,   10,  500);

CREATE OR REPLACE TABLE USER_ACTIVITY (
  ACTIVITY_ID VARCHAR(36),
  SIGNUP_ID VARCHAR(36),
  ACTIVITY_DATE DATE,
  FEATURE_USED VARCHAR(50),
  IS_ACTIVE_DAY BOOLEAN,
  ACTIONS_COUNT NUMBER(10, 0),
  SESSION_DURATION_MINUTES NUMBER(10, 1)
);

INSERT INTO USER_ACTIVITY VALUES
  ('a-001', 's-001', DATE '2025-01-09', 'dashboard', TRUE,  8, 14.0),
  ('a-002', 's-001', DATE '2025-01-16', 'reports',   TRUE,  5,  9.5),
  ('a-003', 's-002', DATE '2025-01-13', 'dashboard', TRUE,  4,  6.0),
  ('a-004', 's-004', DATE '2025-01-23', 'admin',     TRUE, 12, 22.0),
  ('a-005', 's-005', DATE '2025-01-30', 'dashboard', TRUE,  3,  5.0),
  ('a-006', 's-006', DATE '2025-02-04', 'reports',   TRUE,  7, 11.0),
  ('a-007', 's-008', DATE '2025-02-15', 'dashboard', TRUE,  6,  8.0),
  ('a-008', 's-009', DATE '2025-02-21', 'exports',   TRUE,  9, 13.5),
  ('a-009', 's-011', DATE '2025-03-05', 'admin',     TRUE, 15, 28.0),
  ('a-010', 's-012', DATE '2025-03-12', 'dashboard', TRUE,  4,  7.0),
  ('a-011', 's-013', DATE '2025-03-17', 'reports',   TRUE,  8, 12.0),
  ('a-012', 's-015', DATE '2025-03-28', 'dashboard', TRUE,  5,  6.5);

GRANT SELECT ON ALL TABLES IN SCHEMA PM_AGENTS_DEMO.APP TO ROLE PM_AGENTS_CI;

CREATE OR REPLACE TABLE EVAL_QUESTIONS (
  INPUT_QUERY VARCHAR,
  EXPECTED_OUTPUT VARIANT
);

INSERT INTO EVAL_QUESTIONS
SELECT column1, PARSE_JSON(column2)
FROM VALUES
  (
    'How many users signed up in January 2025?',
    '{
      "ground_truth_output": "Exactly 5 users signed up in January 2025 (2025-01-01 through 2025-01-31). The response should state the count 5 and scope it to January 2025. Do not report a different month.",
      "ground_truth_invocations": [
        {
          "tool_name": "growth_data",
          "tool_input": "Count signups in January 2025",
          "tool_output": "SQL over SIGNUPS filtered to signup_date in January 2025 that returns 5."
        }
      ]
    }'
  ),
  (
    'How many users signed up in February 2025?',
    '{
      "ground_truth_output": "Exactly 5 users signed up in February 2025. The response should state the count 5 for that month.",
      "ground_truth_invocations": [
        {
          "tool_name": "growth_data",
          "tool_input": "Count signups in February 2025",
          "tool_output": "SQL over SIGNUPS filtered to February 2025 that returns 5."
        }
      ]
    }'
  ),
  (
    'How many users signed up in March 2025?',
    '{
      "ground_truth_output": "Exactly 5 users signed up in March 2025. The response should state the count 5 for that month.",
      "ground_truth_invocations": [
        {
          "tool_name": "growth_data",
          "tool_input": "Count signups in March 2025",
          "tool_output": "SQL over SIGNUPS filtered to March 2025 that returns 5."
        }
      ]
    }'
  ),
  (
    'How many signups converted to a paid plan in Q1 2025?',
    '{
      "ground_truth_output": "11 of 15 signups in Q1 2025 converted to a paid plan. The response should include the conversion count 11 (and may mention 15 total signups). Dates must stay inside 2025-01-01 to 2025-03-31.",
      "ground_truth_invocations": [
        {
          "tool_name": "growth_data",
          "tool_input": "Count paid conversions in Q1 2025",
          "tool_output": "SQL over SIGNUPS with converted_to_paid = TRUE for Q1 2025 that returns 11."
        }
      ]
    }'
  ),
  (
    'What was the conversion rate in Q1 2025?',
    '{
      "ground_truth_output": "The Q1 2025 conversion rate is 73.3% (11 paid conversions out of 15 signups). Rounding to one decimal place is required. Do not invent a different rate.",
      "ground_truth_invocations": [
        {
          "tool_name": "growth_data",
          "tool_input": "Conversion rate for Q1 2025",
          "tool_output": "SQL that computes 11/15 * 100 and returns 73.3."
        }
      ]
    }'
  ),
  (
    'Which signup channel produced the most signups in Q1 2025?',
    '{
      "ground_truth_output": "paid_search produced the most signups in Q1 2025 with 4 signups. organic_search is second with 3. The winner must be paid_search.",
      "ground_truth_invocations": [
        {
          "tool_name": "growth_data",
          "tool_input": "Signups by channel in Q1 2025",
          "tool_output": "SQL grouping SIGNUPS by signup_channel for Q1 2025; paid_search = 4."
        }
      ]
    }'
  ),
  (
    'What was total ad spend in February 2025?',
    '{
      "ground_truth_output": "Total ad spend in February 2025 was 395.00 (150 + 0 + 40 + 95 + 110). The response should report 395 or 395.00 and stay scoped to February 2025.",
      "ground_truth_invocations": [
        {
          "tool_name": "growth_data",
          "tool_input": "Sum ad spend in February 2025",
          "tool_output": "SQL summing TOUCHPOINTS.ad_spend for February 2025 that returns 395."
        }
      ]
    }'
  ),
  (
    'What was total monthly recurring revenue from converted users in January 2025?',
    '{
      "ground_truth_output": "January 2025 converted MRR totals 286.00 (49 + 19 + 199 + 19). The response should report 286 or 286.00 and include only converted users who signed up in January 2025.",
      "ground_truth_invocations": [
        {
          "tool_name": "growth_data",
          "tool_input": "Sum MRR for converted January 2025 signups",
          "tool_output": "SQL summing SIGNUPS.mrr_amount where converted_to_paid is true and signup_date is in January 2025, returning 286."
        }
      ]
    }'
  ),
  (
    'How many enterprise plan signups were there in Q1 2025?',
    '{
      "ground_truth_output": "There were exactly 2 enterprise plan signups in Q1 2025.",
      "ground_truth_invocations": [
        {
          "tool_name": "growth_data",
          "tool_input": "Count enterprise signups in Q1 2025",
          "tool_output": "SQL filtering SIGNUPS.plan_type = enterprise for Q1 2025 that returns 2."
        }
      ]
    }'
  ),
  (
    'What was the weather like in New York on March 1, 2025?',
    '{
      "ground_truth_output": "The agent should refuse. Weather is outside the growth analytics assistant. It must not invent a forecast or temperatures.",
      "ground_truth_invocations": []
    }'
  );

-- Recreate the registered dataset from this table. Drop first so reruns of setup.sql are safe.
DROP DATASET IF EXISTS PM_AGENTS_DEMO.APP.GROWTH_AGENT_EVAL;

CALL SYSTEM$CREATE_EVALUATION_DATASET(
  'Cortex Agent',
  'PM_AGENTS_DEMO.APP.EVAL_QUESTIONS',
  'PM_AGENTS_DEMO.APP.GROWTH_AGENT_EVAL',
  OBJECT_CONSTRUCT('query_text', 'INPUT_QUERY', 'expected_tools', 'EXPECTED_OUTPUT')
);

CREATE FILE FORMAT IF NOT EXISTS PM_AGENTS_DEMO.APP.YAML_FILE_FORMAT
  TYPE = 'CSV'
  FIELD_DELIMITER = NONE
  RECORD_DELIMITER = '\n'
  SKIP_HEADER = 0
  FIELD_OPTIONALLY_ENCLOSED_BY = NONE
  ESCAPE_UNENCLOSED_FIELD = NONE;

CREATE STAGE IF NOT EXISTS PM_AGENTS_DEMO.APP.EVAL_CONFIG_STAGE
  FILE_FORMAT = PM_AGENTS_DEMO.APP.YAML_FILE_FORMAT;

GRANT READ, WRITE ON STAGE PM_AGENTS_DEMO.APP.EVAL_CONFIG_STAGE TO ROLE PM_AGENTS_CI;
GRANT SELECT ON ALL TABLES IN SCHEMA PM_AGENTS_DEMO.APP TO ROLE PM_AGENTS_CI;
GRANT ALL ON FUTURE TABLES IN SCHEMA PM_AGENTS_DEMO.APP TO ROLE PM_AGENTS_CI;
GRANT SELECT, MONITOR ON ALL SEMANTIC VIEWS IN SCHEMA PM_AGENTS_DEMO.APP TO ROLE PM_AGENTS_CI;
GRANT OWNERSHIP ON ALL SEMANTIC VIEWS IN SCHEMA PM_AGENTS_DEMO.APP TO ROLE PM_AGENTS_CI COPY CURRENT GRANTS;
GRANT ALL ON FUTURE SEMANTIC VIEWS IN SCHEMA PM_AGENTS_DEMO.APP TO ROLE PM_AGENTS_CI;
GRANT ALL ON FUTURE AGENTS IN SCHEMA PM_AGENTS_DEMO.APP TO ROLE PM_AGENTS_CI;

GRANT ALL ON FUTURE DATASETS IN SCHEMA PM_AGENTS_DEMO.APP TO ROLE PM_AGENTS_CI;
-- Transfer ownership of GROWTH_AGENT_EVAL to PM_AGENTS_CI so the grant is
-- stable and not reset by EXECUTE_AI_EVALUATION internal operations.
GRANT OWNERSHIP ON DATASET PM_AGENTS_DEMO.APP.GROWTH_AGENT_EVAL TO ROLE PM_AGENTS_CI COPY CURRENT GRANTS;

-- OWNER'S RIGHTS stored procedure that runs as ACCOUNTADMIN and drops the SV
-- eval results dataset before each CI run. Direct DROP by PM_AGENTS_CI leaves
-- internal state that blocks GET_ANALYST_AI_EVALUATION_DATA reads; only an
-- ACCOUNTADMIN-initiated drop clears it completely.
CREATE OR REPLACE PROCEDURE PM_AGENTS_DEMO.APP.SP_RESET_EVAL_DATASETS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  -- Drop SV eval results dataset so EXECUTE_AI_EVALUATION recreates it clean.
  DROP DATASET IF EXISTS PM_AGENTS_DEMO.APP.GROWTH_ANALYTICS_SV_SYSTEM_EVAL;
  RETURN 'Eval datasets reset complete';
END;
$$;

GRANT USAGE ON PROCEDURE PM_AGENTS_DEMO.APP.SP_RESET_EVAL_DATASETS()
  TO ROLE PM_AGENTS_CI;

-- Stage and privileges for the Streamlit-in-Snowflake dashboard app.
CREATE STAGE IF NOT EXISTS PM_AGENTS_DEMO.APP.STREAMLIT_STAGE
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

GRANT READ, WRITE ON STAGE PM_AGENTS_DEMO.APP.STREAMLIT_STAGE TO ROLE PM_AGENTS_CI;
GRANT CREATE STREAMLIT ON SCHEMA PM_AGENTS_DEMO.APP TO ROLE PM_AGENTS_CI;
GRANT ALL ON FUTURE STREAMLITS IN SCHEMA PM_AGENTS_DEMO.APP TO ROLE PM_AGENTS_CI;

SELECT 'Setup complete. Register an RSA public key on PM_AGENTS_CI_USER, then run the GitHub Action.' AS STATUS;
