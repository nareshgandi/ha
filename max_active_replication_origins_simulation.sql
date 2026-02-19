-- ============================================================================
-- SIMULATION: max_active_replication_origins in PostgreSQL
-- ============================================================================
-- This parameter limits how many replication origins can be active at once.
-- Default: 10 | Requires restart to change
-- ============================================================================

-- ============================================================================
-- PART 1: Check Current Setting
-- ============================================================================

SHOW max_active_replication_origins;

-- Check if it requires restart
SELECT name, setting, unit, context, short_desc
FROM pg_settings
WHERE name = 'max_active_replication_origins';

-- Context = 'postmaster' means it requires a PostgreSQL restart to change.

-- ============================================================================
-- PART 2: View Existing Replication Origins
-- ============================================================================

-- All registered origins (name + OID)
SELECT * FROM pg_replication_origin;

-- Active origin status (shows replay progress)
SELECT roident, external_id, remote_lsn, local_lsn
FROM pg_replication_origin_status;

-- ============================================================================
-- PART 3: Manually Create Replication Origins (Simulate Subscriptions)
-- ============================================================================
-- Each logical subscription auto-creates one, but we can create them manually
-- to simulate hitting the limit.

-- Create origins to simulate multiple publishers replicating to this subscriber
SELECT pg_replication_origin_create('origin_publisher_1');
SELECT pg_replication_origin_create('origin_publisher_2');
SELECT pg_replication_origin_create('origin_publisher_3');
SELECT pg_replication_origin_create('origin_publisher_4');
SELECT pg_replication_origin_create('origin_publisher_5');

-- Verify they were created
SELECT * FROM pg_replication_origin;

-- ============================================================================
-- PART 4: Simulate Advancing Replay Progress
-- ============================================================================
-- In real logical replication, the subscriber advances the origin LSN as it
-- applies changes. We can simulate this with pg_replication_origin_advance().

-- Advance origin_publisher_1 to a specific LSN (simulating replay progress)
SELECT pg_replication_origin_advance('origin_publisher_1', '0/1500000');
SELECT pg_replication_origin_advance('origin_publisher_2', '0/2A00000');
SELECT pg_replication_origin_advance('origin_publisher_3', '0/3F00000');

-- Now check the status - you'll see the LSN progress tracked
SELECT roident, external_id, remote_lsn, local_lsn
FROM pg_replication_origin_status;

-- ============================================================================
-- PART 5: Simulate Hitting the Limit
-- ============================================================================
-- If max_active_replication_origins = 10 (default), creating more than 10
-- origins that are actively being used will fail.
--
-- To test this:
--   1. SET max_active_replication_origins = 3 in postgresql.conf
--   2. Restart PostgreSQL
--   3. Try creating/activating more than 3 origins
--
-- The error you'd see:
--   ERROR: could not find free replication origin OID
--   OR
--   ERROR: all replication origin slots are in use
--   HINT: Increase max_active_replication_origins if necessary.

-- ============================================================================
-- PART 6: Real-World Scenario - Logical Subscriptions Consuming Origins
-- ============================================================================
-- When you do CREATE SUBSCRIPTION, PostgreSQL automatically:
--   1. Creates a replication origin named 'pg_<subscription_oid>'
--   2. Starts tracking replay progress against that origin
--
-- Example (conceptual - requires actual publisher setup):
--
--   CREATE SUBSCRIPTION sub_orders
--     CONNECTION 'host=publisher1 dbname=prod'
--     PUBLICATION pub_orders;
--     -- This creates 1 replication origin automatically
--
--   CREATE SUBSCRIPTION sub_inventory
--     CONNECTION 'host=publisher2 dbname=prod'
--     PUBLICATION pub_inventory;
--     -- This creates another replication origin
--
-- Each subscription = 1 origin slot consumed

-- ============================================================================
-- PART 7: Monitoring Query for Production
-- ============================================================================

-- How many origin slots are in use vs available?
SELECT
    current_setting('max_active_replication_origins')::int AS max_origins,
    count(*) AS origins_in_use,
    current_setting('max_active_replication_origins')::int - count(*) AS slots_remaining
FROM pg_replication_origin;

-- Detailed view with subscription mapping (if using built-in logical replication)
SELECT
    ro.roident,
    ro.roname AS origin_name,
    ros.remote_lsn,
    ros.local_lsn,
    s.subname AS subscription_name,
    s.subconninfo AS publisher_connection
FROM pg_replication_origin ro
LEFT JOIN pg_replication_origin_status ros ON ro.roident = ros.roident
LEFT JOIN pg_subscription s ON ro.roname = 'pg_' || s.oid::text;

-- ============================================================================
-- CLEANUP: Remove Manually Created Origins
-- ============================================================================

SELECT pg_replication_origin_drop('origin_publisher_1');
SELECT pg_replication_origin_drop('origin_publisher_2');
SELECT pg_replication_origin_drop('origin_publisher_3');
SELECT pg_replication_origin_drop('origin_publisher_4');
SELECT pg_replication_origin_drop('origin_publisher_5');

-- Verify cleanup
SELECT * FROM pg_replication_origin;

-- ============================================================================
-- QUICK REFERENCE
-- ============================================================================
--
-- Parameter:  max_active_replication_origins
-- Default:    10
-- Min:        0 (disables replication origin tracking)
-- Context:    postmaster (requires restart)
-- Introduced: PostgreSQL 16
--
-- Rule of thumb: Set it to (number_of_subscriptions + buffer)
--   Example: 15 subscriptions → set to 20
--
-- Related catalog tables:
--   pg_replication_origin          → registered origins
--   pg_replication_origin_status   → replay progress (LSN tracking)
--
-- Related functions:
--   pg_replication_origin_create(name)     → register new origin
--   pg_replication_origin_drop(name)       → remove origin
--   pg_replication_origin_advance(name, lsn) → set replay position
--   pg_replication_origin_session_setup(name) → bind origin to session
--   pg_replication_origin_progress(name, flush) → get current LSN
-- ============================================================================
