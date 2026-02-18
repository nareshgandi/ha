# PostgreSQL Vacuum Agent — Complete Blueprint

## Mental Model, Diagnostic Queries, Interaction Design & Implementation Guide

---

## Table of Contents

1. [Agent Architecture & Mental Model](#1-agent-architecture--mental-model)
2. [Problem Taxonomy — The Vacuum Universe](#2-problem-taxonomy--the-vacuum-universe)
3. [Diagnostic Query Library](#3-diagnostic-query-library)
4. [Decision Engine — Detection & Triage Logic](#4-decision-engine--detection--triage-logic)
5. [Remediation Playbooks](#5-remediation-playbooks)
6. [Interactive Chatbot Design](#6-interactive-chatbot-design)
7. [Autonomous Mode — Continuous Monitoring](#7-autonomous-mode--continuous-monitoring)
8. [Agent State Machine](#8-agent-state-machine)
9. [Safety & Guardrails](#9-safety--guardrails)
10. [Implementation Reference](#10-implementation-reference)

---

## 1. Agent Architecture & Mental Model

### 1.1 Core Philosophy

The agent operates on a **Detect → Diagnose → Decide → Act → Verify** loop (D³AV). Every vacuum-related problem in PostgreSQL is a symptom of one of three root causes:

```
┌─────────────────────────────────────────────────────┐
│              ROOT CAUSE TRIANGLE                     │
│                                                      │
│                   DEAD TUPLES                        │
│                   (not reclaimed)                     │
│                      ▲                               │
│                     / \                              │
│                    /   \                             │
│                   /     \                            │
│    FROZEN TXNS ◄─────────► CATALOG/SYSTEM           │
│    (wraparound)            (overhead)                │
│                                                      │
│  Every vacuum problem maps to one or more vertices   │
└─────────────────────────────────────────────────────┘
```

### 1.2 Agent Modes

| Mode | Trigger | Behaviour |
|------|---------|-----------|
| **Autonomous** | Cron / scheduler / background daemon | Runs full diagnostic suite on schedule, generates alerts, optionally auto-remediates |
| **Interactive** | User initiates chat | Conversational; asks clarifying questions, explains findings in plain language, suggests or executes actions with approval |
| **Hybrid** | Autonomous detects critical issue | Switches to interactive to get human approval before aggressive action |

### 1.3 Layered Detection Model

```
Layer 0 — Heartbeat    : Is vacuum running at all? Autovacuum enabled?
Layer 1 — Stats         : Are stats current? Is the stats collector healthy?
Layer 2 — Table Bloat   : Dead tuple ratio, table size vs live data ratio
Layer 3 — Index Bloat   : Index size vs table size, duplicate index detection
Layer 4 — TOAST Bloat   : Oversized TOAST tables, orphaned TOAST tuples
Layer 5 — Catalog Bloat : pg_attribute, pg_depend, pg_class bloating
Layer 6 — Wraparound    : Transaction age approaching danger zone
Layer 7 — Vacuum Perf   : Vacuum taking too long, I/O impact, lock contention
Layer 8 — Configuration : Misconfigured vacuum parameters
```

---

## 2. Problem Taxonomy — The Vacuum Universe

### 2.1 Complete Problem Map

```
VACUUM PROBLEMS
├── A. DEAD TUPLE ACCUMULATION
│   ├── A1. Autovacuum not running (disabled, crashed, starved)
│   ├── A2. Autovacuum too slow (can't keep up with write rate)
│   ├── A3. Long-running transactions holding back vacuum
│   ├── A4. Abandoned replication slots preventing cleanup
│   ├── A5. hot_standby_feedback blocking vacuum on primary
│   ├── A6. Prepared transactions (2PC) never committed/rolled back
│   │
├── B. TABLE BLOAT
│   ├── B1. High dead tuple ratio (> threshold)
│   ├── B2. Table physical size >> live data (bloat ratio)
│   ├── B3. Fillfactor misconfiguration
│   ├── B4. Update-heavy wide tables (HOT updates failing)
│   │
├── C. INDEX BLOAT
│   ├── C1. Index size disproportionate to table
│   ├── C2. B-tree index page splits / fragmentation
│   ├── C3. Unused indexes consuming vacuum time
│   ├── C4. Duplicate / overlapping indexes
│   ├── C5. Expression/partial index bloat
│   │
├── D. TOAST BLOAT
│   ├── D1. TOAST table bloat (large column updates)
│   ├── D2. Orphaned TOAST tuples (main row deleted, TOAST remains)
│   ├── D3. TOAST compression inefficiency
│   ├── D4. TOAST chunk size issues
│   │
├── E. CATALOG TABLE BLOAT
│   ├── E1. pg_attribute bloat (many ALTERs / temp tables)
│   ├── E2. pg_class bloat (frequent CREATE/DROP)
│   ├── E3. pg_depend / pg_shdepend bloat
│   ├── E4. pg_statistic bloat
│   ├── E5. pg_toast for catalog tables
│   │
├── F. TRANSACTION ID WRAPAROUND
│   ├── F1. Tables approaching wraparound (age > 200M)
│   ├── F2. Anti-wraparound vacuum blocked / failing
│   ├── F3. Emergency autovacuum triggered (age > autovacuum_freeze_max_age)
│   ├── F4. Database-wide oldest xmin not advancing
│   ├── F5. MultiXact wraparound (separate from XID)
│   │
├── G. VACUUM PERFORMANCE
│   ├── G1. Vacuum I/O throttling too aggressive (cost_delay)
│   ├── G2. Vacuum running out of maintenance_work_mem
│   ├── G3. Index vacuum passes taking too long
│   ├── G4. Vacuum holding locks blocking DDL/queries
│   ├── G5. Autovacuum workers all busy
│   │
├── H. STATS & VISIBILITY
│   ├── H1. pg_stat_user_tables stats stale or zeroed
│   ├── H2. Visibility map corruption
│   ├── H3. Free space map (FSM) inaccurate
│   ├── H4. Relation stats not updated after bulk load
│   ├── H5. pg_stat_activity showing vacuum blocked
│   │
└── I. CONFIGURATION ISSUES
    ├── I1. autovacuum_vacuum_threshold too high for small tables
    ├── I2. autovacuum_vacuum_scale_factor too high for large tables
    ├── I3. vacuum_cost_delay too aggressive
    ├── I4. autovacuum_max_workers too low
    ├── I5. Per-table overrides missing for hot tables
    ├── I6. maintenance_work_mem too low for large tables
    └── I7. vacuum_freeze_min_age / vacuum_freeze_table_age misconfigured
```

---

## 3. Diagnostic Query Library

### 3.0 Health Check Overview — Single Query Dashboard

```sql
-- MASTER HEALTH CHECK: Run this first in every diagnostic session
WITH vacuum_health AS (
    SELECT
        current_setting('autovacuum') AS autovacuum_enabled,
        current_setting('autovacuum_max_workers')::int AS max_workers,
        (SELECT count(*) FROM pg_stat_activity
         WHERE backend_type = 'autovacuum worker') AS active_workers,
        (SELECT count(*) FROM pg_stat_user_tables
         WHERE n_dead_tup > 10000
           AND n_dead_tup > 0.1 * n_live_tup) AS tables_with_high_dead_tuples,
        (SELECT count(*) FROM pg_class c
         JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname NOT IN ('pg_catalog','information_schema')
           AND c.relkind = 'r'
           AND age(c.relfrozenxid) > 150000000) AS tables_near_wraparound,
        (SELECT max(age(c.relfrozenxid))
         FROM pg_class c
         JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relkind = 'r') AS max_xid_age,
        (SELECT count(*) FROM pg_stat_user_tables
         WHERE last_autovacuum IS NULL
           AND n_dead_tup > 1000) AS tables_never_vacuumed,
        age(now(), (SELECT min(xact_start) FROM pg_stat_activity
         WHERE state != 'idle' AND xact_start IS NOT NULL)) AS oldest_active_xact
)
SELECT * FROM vacuum_health;
```

### 3.1 Autovacuum Status & Activity

```sql
-- Q01: Current autovacuum workers and what they're doing
SELECT
    pid,
    datname,
    query,
    state,
    wait_event_type,
    wait_event,
    now() - xact_start AS duration,
    now() - query_start AS query_duration
FROM pg_stat_activity
WHERE backend_type = 'autovacuum worker'
ORDER BY xact_start;

-- Q02: Autovacuum configuration snapshot
SELECT
    name, setting, unit, short_desc
FROM pg_settings
WHERE name LIKE '%autovacuum%'
   OR name LIKE '%vacuum%'
   OR name IN ('maintenance_work_mem','track_counts')
ORDER BY name;

-- Q03: Tables that SHOULD be vacuumed but haven't been
-- Uses the actual autovacuum threshold formula:
-- vacuum_threshold + vacuum_scale_factor * n_live_tup
SELECT
    schemaname, relname,
    n_live_tup,
    n_dead_tup,
    n_dead_tup::float / NULLIF(n_live_tup, 0) AS dead_ratio,
    last_autovacuum,
    last_vacuum,
    -- Effective threshold calculation
    COALESCE(
        (SELECT option_value::int FROM pg_options_to_table(c.reloptions)
         WHERE option_name = 'autovacuum_vacuum_threshold'),
        current_setting('autovacuum_vacuum_threshold')::int
    ) +
    COALESCE(
        (SELECT option_value::float FROM pg_options_to_table(c.reloptions)
         WHERE option_name = 'autovacuum_vacuum_scale_factor'),
        current_setting('autovacuum_vacuum_scale_factor')::float
    ) * n_live_tup AS effective_threshold
FROM pg_stat_user_tables s
JOIN pg_class c ON c.relname = s.relname
    AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = s.schemaname)
WHERE n_dead_tup > (
    COALESCE(
        (SELECT option_value::int FROM pg_options_to_table(c.reloptions)
         WHERE option_name = 'autovacuum_vacuum_threshold'),
        current_setting('autovacuum_vacuum_threshold')::int
    ) +
    COALESCE(
        (SELECT option_value::float FROM pg_options_to_table(c.reloptions)
         WHERE option_name = 'autovacuum_vacuum_scale_factor'),
        current_setting('autovacuum_vacuum_scale_factor')::float
    ) * n_live_tup
)
ORDER BY n_dead_tup DESC;
```

### 3.2 Table Bloat Detection

```sql
-- Q04: Table bloat estimation using statistical approach
-- This is the pgstattuple-free version; accurate within ~10%
WITH constants AS (
    SELECT
        current_setting('block_size')::numeric AS bs,
        23 AS hdr,   -- heap tuple header
        4  AS ma     -- MAXALIGN
),
bloat_data AS (
    SELECT
        schemaname, tablename,
        (datawidth + (hdr + ma - (CASE WHEN hdr % ma = 0 THEN ma ELSE hdr % ma END)))::numeric
            AS datahdr,
        bs,
        reltuples::numeric AS est_rows,
        relpages::numeric AS est_pages,
        pg_relation_size(schemaname || '.' || tablename)::numeric AS table_bytes
    FROM (
        SELECT
            s.schemaname,
            s.tablename,
            SUM((1 - null_frac) * avg_width) AS datawidth,
            c.reltuples,
            c.relpages
        FROM pg_stats s
        JOIN pg_class c ON c.relname = s.tablename
        JOIN pg_namespace n ON n.oid = c.relnamespace
            AND n.nspname = s.schemaname
        WHERE s.schemaname NOT IN ('pg_catalog', 'information_schema')
        GROUP BY s.schemaname, s.tablename, c.reltuples, c.relpages
    ) sub
    CROSS JOIN constants
)
SELECT
    schemaname,
    tablename,
    pg_size_pretty(table_bytes) AS actual_size,
    pg_size_pretty((est_rows * datahdr)::bigint) AS estimated_data_size,
    CASE WHEN table_bytes > 0
        THEN round(100.0 * (table_bytes - est_rows * datahdr) / table_bytes, 1)
        ELSE 0
    END AS bloat_pct,
    pg_size_pretty((table_bytes - (est_rows * datahdr)::bigint)::bigint) AS wasted_bytes
FROM bloat_data
WHERE table_bytes > 10 * 1024 * 1024  -- Only tables > 10MB
ORDER BY (table_bytes - est_rows * datahdr) DESC
LIMIT 25;

-- Q05: Precise bloat using pgstattuple (requires extension; slow on large tables)
-- CREATE EXTENSION IF NOT EXISTS pgstattuple;
-- SELECT
--     schemaname, relname,
--     (pgstattuple(schemaname || '.' || relname)).*
-- FROM pg_stat_user_tables
-- WHERE pg_relation_size(schemaname || '.' || relname) > 10 * 1024 * 1024
-- ORDER BY pg_relation_size(schemaname || '.' || relname) DESC
-- LIMIT 10;
```

### 3.3 Index Bloat Detection

```sql
-- Q06: Index bloat estimation
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    pg_size_pretty(pg_relation_size(indrelid)) AS table_size,
    round(100.0 * pg_relation_size(indexrelid) /
        NULLIF(pg_relation_size(indrelid), 0), 1) AS index_to_table_pct,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes
JOIN pg_index ON pg_index.indexrelid = pg_stat_user_indexes.indexrelid
WHERE pg_relation_size(indexrelid) > 10 * 1024 * 1024  -- > 10 MB
ORDER BY pg_relation_size(indexrelid) DESC;

-- Q07: Unused indexes (candidates for removal to speed up vacuum)
SELECT
    schemaname, relname, indexrelname,
    pg_size_pretty(pg_relation_size(i.indexrelid)) AS index_size,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch,
    pg_stat_get_last_idx_scan_time(i.indexrelid) AS last_scan_time
FROM pg_stat_user_indexes i
JOIN pg_index pi ON pi.indexrelid = i.indexrelid
WHERE idx_scan = 0
  AND NOT pi.indisunique
  AND NOT pi.indisprimary
  AND pg_relation_size(i.indexrelid) > 1024 * 1024  -- > 1MB
ORDER BY pg_relation_size(i.indexrelid) DESC;

-- Q08: Duplicate / overlapping indexes
SELECT
    a.indrelid::regclass AS table_name,
    a.indexrelid::regclass AS index1,
    b.indexrelid::regclass AS index2,
    pg_size_pretty(pg_relation_size(a.indexrelid)) AS index1_size,
    pg_size_pretty(pg_relation_size(b.indexrelid)) AS index2_size,
    a.indkey AS cols1,
    b.indkey AS cols2
FROM pg_index a
JOIN pg_index b ON a.indrelid = b.indrelid
    AND a.indexrelid < b.indexrelid
WHERE (a.indkey::text = b.indkey::text)
   OR (a.indkey::text LIKE b.indkey::text || ' %')
   OR (b.indkey::text LIKE a.indkey::text || ' %');

-- Q09: Index bloat via pgstatindex (precise but slow)
-- CREATE EXTENSION IF NOT EXISTS pgstattuple;
-- SELECT
--     indexrelname,
--     pg_size_pretty(pg_relation_size(indexrelid)) AS size,
--     (pgstatindex(indexrelid::regclass)).*
-- FROM pg_stat_user_indexes
-- WHERE pg_relation_size(indexrelid) > 50 * 1024 * 1024
-- ORDER BY pg_relation_size(indexrelid) DESC
-- LIMIT 10;
```

### 3.4 TOAST Bloat & Orphaned TOAST

```sql
-- Q10: TOAST table sizes relative to main table
SELECT
    c.relname AS main_table,
    t.relname AS toast_table,
    pg_size_pretty(pg_relation_size(c.oid)) AS main_size,
    pg_size_pretty(pg_relation_size(t.oid)) AS toast_size,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    round(100.0 * pg_relation_size(t.oid) /
        NULLIF(pg_total_relation_size(c.oid), 0), 1) AS toast_pct,
    c.reltuples AS main_rows
FROM pg_class c
JOIN pg_class t ON t.oid = c.reltoastrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND pg_relation_size(t.oid) > 10 * 1024 * 1024
ORDER BY pg_relation_size(t.oid) DESC;

-- Q11: Potential orphaned TOAST detection
-- If main table has far fewer rows than TOAST chunks suggest
SELECT
    c.relname AS main_table,
    t.relname AS toast_table,
    c.reltuples AS main_est_rows,
    t.reltuples AS toast_est_chunks,
    round(t.reltuples / NULLIF(c.reltuples, 0), 1) AS chunks_per_row,
    pg_size_pretty(pg_relation_size(t.oid)) AS toast_size
FROM pg_class c
JOIN pg_class t ON t.oid = c.reltoastrelid
WHERE c.reltuples > 0
  AND t.reltuples / NULLIF(c.reltuples, 0) > 50  -- Suspicious: >50 chunks per row
ORDER BY pg_relation_size(t.oid) DESC;

-- Q12: TOAST table dead tuples
SELECT
    c.relname AS main_table,
    t.relname AS toast_table,
    s.n_dead_tup AS toast_dead_tuples,
    s.n_live_tup AS toast_live_tuples,
    s.last_vacuum AS toast_last_vacuum,
    s.last_autovacuum AS toast_last_autovacuum
FROM pg_class c
JOIN pg_class t ON t.oid = c.reltoastrelid
JOIN pg_stat_all_tables s ON s.relid = t.oid
WHERE s.n_dead_tup > 10000
ORDER BY s.n_dead_tup DESC;

-- Q13: Columns likely causing TOAST bloat
SELECT
    c.relname AS table_name,
    a.attname AS column_name,
    pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
    a.attstorage AS storage_type,
    -- x=extended, e=external, p=plain, m=main
    CASE a.attstorage
        WHEN 'x' THEN 'extended (compress+toast)'
        WHEN 'e' THEN 'external (toast, no compress)'
        WHEN 'p' THEN 'plain (inline only)'
        WHEN 'm' THEN 'main (compress, toast last resort)'
    END AS storage_desc,
    s.avg_width
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_stats s ON s.tablename = c.relname
    AND s.attname = a.attname AND s.schemaname = n.nspname
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND a.attnum > 0
  AND NOT a.attisdropped
  AND (a.atttypid IN (
      'text'::regtype, 'bytea'::regtype, 'jsonb'::regtype,
      'json'::regtype, 'xml'::regtype
  ) OR pg_catalog.format_type(a.atttypid, a.atttypmod) LIKE '%[]')
ORDER BY COALESCE(s.avg_width, 0) DESC;
```

### 3.5 Catalog Table Bloat

```sql
-- Q14: Catalog table sizes and bloat indicators
SELECT
    c.relname,
    c.reltuples::bigint AS estimated_rows,
    pg_size_pretty(pg_relation_size(c.oid)) AS size,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    age(c.relfrozenxid) AS xid_age,
    s.n_dead_tup,
    s.n_live_tup,
    s.last_vacuum,
    s.last_autovacuum,
    CASE WHEN s.n_live_tup > 0
        THEN round(100.0 * s.n_dead_tup / s.n_live_tup, 2)
        ELSE 0
    END AS dead_pct
FROM pg_class c
JOIN pg_stat_all_tables s ON s.relid = c.oid
WHERE c.relnamespace = 'pg_catalog'::regnamespace
  AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC
LIMIT 25;

-- Q15: pg_attribute bloat (common after many DDL operations)
SELECT
    pg_size_pretty(pg_relation_size('pg_attribute'::regclass)) AS pg_attribute_size,
    (SELECT count(*) FROM pg_attribute WHERE NOT attisdropped) AS live_columns,
    (SELECT count(*) FROM pg_attribute WHERE attisdropped) AS dropped_columns,
    (SELECT n_dead_tup FROM pg_stat_all_tables
     WHERE relname = 'pg_attribute') AS dead_tuples;

-- Q16: Catalog TOAST tables
SELECT
    c.relname AS catalog_table,
    t.relname AS toast_table,
    pg_size_pretty(pg_relation_size(t.oid)) AS toast_size,
    pg_size_pretty(pg_relation_size(c.oid)) AS catalog_size
FROM pg_class c
JOIN pg_class t ON t.oid = c.reltoastrelid
WHERE c.relnamespace = 'pg_catalog'::regnamespace
  AND pg_relation_size(t.oid) > 1024 * 1024  -- > 1MB
ORDER BY pg_relation_size(t.oid) DESC;
```

### 3.6 Transaction ID Wraparound

```sql
-- Q17: Tables approaching XID wraparound — THE CRITICAL QUERY
SELECT
    n.nspname AS schema,
    c.relname AS table_name,
    age(c.relfrozenxid) AS xid_age,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    current_setting('autovacuum_freeze_max_age')::bigint AS freeze_max_age,
    round(100.0 * age(c.relfrozenxid) /
        current_setting('autovacuum_freeze_max_age')::bigint, 1) AS pct_towards_wraparound,
    CASE
        WHEN age(c.relfrozenxid) > 1200000000 THEN 'CRITICAL — IMMINENT WRAPAROUND'
        WHEN age(c.relfrozenxid) > 500000000  THEN 'DANGER — NEEDS IMMEDIATE VACUUM'
        WHEN age(c.relfrozenxid) > 200000000  THEN 'WARNING — MONITOR CLOSELY'
        WHEN age(c.relfrozenxid) > 100000000  THEN 'ELEVATED — AUTOVACUUM SHOULD HANDLE'
        ELSE 'OK'
    END AS status
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 't')  -- tables and TOAST
ORDER BY age(c.relfrozenxid) DESC
LIMIT 30;

-- Q18: Database-level wraparound status
SELECT
    datname,
    age(datfrozenxid) AS db_xid_age,
    current_setting('autovacuum_freeze_max_age')::bigint AS freeze_max_age,
    round(100.0 * age(datfrozenxid) /
        2147483647, 2) AS pct_towards_hard_limit,
    CASE
        WHEN age(datfrozenxid) > 1200000000 THEN 'CRITICAL'
        WHEN age(datfrozenxid) > 500000000  THEN 'DANGER'
        WHEN age(datfrozenxid) > 200000000  THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM pg_database
ORDER BY age(datfrozenxid) DESC;

-- Q19: MultiXact wraparound status
SELECT
    n.nspname AS schema,
    c.relname,
    mxid_age(c.relminmxid) AS mxid_age,
    current_setting('autovacuum_multixact_freeze_max_age')::bigint AS mxid_freeze_max,
    round(100.0 * mxid_age(c.relminmxid) /
        current_setting('autovacuum_multixact_freeze_max_age')::bigint, 1)
        AS pct_towards_mxid_wraparound
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND mxid_age(c.relminmxid) > 100000000
ORDER BY mxid_age(c.relminmxid) DESC;
```

### 3.7 Vacuum Blockers

```sql
-- Q20: Long-running transactions blocking vacuum
SELECT
    pid,
    usename,
    datname,
    state,
    now() - xact_start AS xact_duration,
    now() - query_start AS query_duration,
    query,
    backend_xmin,
    backend_xid
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
  AND state != 'idle'
  AND now() - xact_start > interval '5 minutes'
ORDER BY xact_start;

-- Q21: Idle-in-transaction sessions (silent vacuum killers)
SELECT
    pid,
    usename,
    datname,
    state,
    now() - state_change AS idle_duration,
    now() - xact_start AS xact_duration,
    query AS last_query,
    backend_xmin
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY xact_start;

-- Q22: Replication slots blocking vacuum
SELECT
    slot_name,
    slot_type,
    active,
    xmin,
    catalog_xmin,
    age(xmin) AS xmin_age,
    age(catalog_xmin) AS catalog_xmin_age,
    restart_lsn,
    confirmed_flush_lsn,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
    ) AS wal_retained
FROM pg_replication_slots
ORDER BY age(COALESCE(xmin, catalog_xmin)) DESC;

-- Q23: Prepared transactions (2PC) blocking vacuum
SELECT
    gid,
    prepared,
    owner,
    database,
    transaction AS xid,
    age(transaction) AS xid_age,
    now() - prepared AS age
FROM pg_prepared_xacts
ORDER BY prepared;

-- Q24: Who is blocking the autovacuum worker?
SELECT
    blocked.pid AS blocked_pid,
    blocked.query AS blocked_query,
    blocking.pid AS blocking_pid,
    blocking.query AS blocking_query,
    blocking.state AS blocking_state,
    now() - blocking.query_start AS blocking_duration
FROM pg_stat_activity blocked
JOIN pg_locks bl ON bl.pid = blocked.pid
JOIN pg_locks bll ON bll.relation = bl.relation
    AND bll.pid != bl.pid
JOIN pg_stat_activity blocking ON blocking.pid = bll.pid
WHERE blocked.backend_type = 'autovacuum worker'
  AND NOT bl.granted;
```

### 3.8 Vacuum Performance & History

```sql
-- Q25: Vacuum progress (PostgreSQL 9.6+)
SELECT
    p.pid,
    a.query,
    p.relid::regclass AS table_name,
    p.phase,
    p.heap_blks_total,
    p.heap_blks_scanned,
    p.heap_blks_vacuumed,
    round(100.0 * p.heap_blks_vacuumed / NULLIF(p.heap_blks_total, 0), 1) AS pct_complete,
    p.index_vacuum_count,
    p.max_dead_tuples,
    p.num_dead_tuples
FROM pg_stat_progress_vacuum p
JOIN pg_stat_activity a ON a.pid = p.pid;

-- Q26: Last vacuum/analyze times per table
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    vacuum_count,
    autovacuum_count,
    analyze_count,
    autoanalyze_count
FROM pg_stat_user_tables
ORDER BY COALESCE(last_autovacuum, last_vacuum, '1970-01-01'::timestamp)
LIMIT 30;

-- Q27: Tables with most dead tuples (priority queue)
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
    pg_size_pretty(pg_total_relation_size(
        schemaname || '.' || relname)) AS total_size,
    last_autovacuum,
    last_vacuum,
    now() - COALESCE(last_autovacuum, last_vacuum) AS time_since_vacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 0
ORDER BY n_dead_tup DESC
LIMIT 30;
```

### 3.9 HOT Updates & Fillfactor

```sql
-- Q28: HOT update effectiveness
SELECT
    schemaname,
    relname,
    n_tup_upd,
    n_tup_hot_upd,
    CASE WHEN n_tup_upd > 0
        THEN round(100.0 * n_tup_hot_upd / n_tup_upd, 1)
        ELSE 0
    END AS hot_update_pct,
    -- Low HOT % + high updates = bloat factory
    CASE
        WHEN n_tup_upd > 10000
             AND n_tup_hot_upd::float / NULLIF(n_tup_upd, 0) < 0.5
        THEN 'NEEDS ATTENTION — low HOT ratio with high updates'
        ELSE 'OK'
    END AS status
FROM pg_stat_user_tables
WHERE n_tup_upd > 1000
ORDER BY n_tup_upd DESC;

-- Q29: Current fillfactor settings
SELECT
    c.relname,
    COALESCE(
        (SELECT option_value FROM pg_options_to_table(c.reloptions)
         WHERE option_name = 'fillfactor'),
        '100'
    ) AS fillfactor,
    s.n_tup_upd,
    s.n_tup_hot_upd
FROM pg_class c
JOIN pg_stat_user_tables s ON s.relname = c.relname
JOIN pg_namespace n ON n.oid = c.relnamespace
    AND n.nspname = s.schemaname
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND s.n_tup_upd > 1000
ORDER BY s.n_tup_upd DESC;
```

### 3.10 Visibility Map & Free Space Map

```sql
-- Q30: Visibility map coverage (needs pg_visibility extension)
-- CREATE EXTENSION IF NOT EXISTS pg_visibility;
-- SELECT
--     relname,
--     pg_size_pretty(pg_relation_size(oid)) AS size,
--     all_visible AS vm_pages,
--     relpages AS total_pages,
--     round(100.0 * all_visible / NULLIF(relpages, 0), 1) AS vm_coverage_pct
-- FROM (
--     SELECT c.oid, c.relname, c.relpages,
--         (pg_visibility_map_summary(c.oid)).all_visible
--     FROM pg_class c
--     JOIN pg_namespace n ON n.oid = c.relnamespace
--     WHERE c.relkind = 'r'
--       AND n.nspname NOT IN ('pg_catalog','information_schema')
--       AND c.relpages > 100
-- ) sub
-- ORDER BY vm_coverage_pct ASC
-- LIMIT 20;

-- Q31: Free space estimation via pg_freespacemap
-- CREATE EXTENSION IF NOT EXISTS pg_freespacemap;
-- SELECT
--     avg(avail) AS avg_free_bytes_per_page,
--     count(*) AS total_pages,
--     pg_size_pretty(sum(avail)::bigint) AS total_free_space
-- FROM pg_freespace('your_table_name');
```

---

## 4. Decision Engine — Detection & Triage Logic

### 4.1 Severity Classification

```
SEVERITY LEVELS:
  P0 — CRITICAL  : Wraparound imminent (>1.2B), DB will shut down
  P1 — URGENT    : Wraparound approaching (>500M), vacuum blocked, replication slots >100GB behind
  P2 — HIGH      : Table bloat >50%, index bloat >70%, catalog bloat >1GB
  P3 — MEDIUM    : Dead tuple ratio >20%, unused indexes >10GB, TOAST anomalies
  P4 — LOW       : Config suboptimal, stats stale, minor bloat
  P5 — INFO      : Informational findings, optimization suggestions
```

### 4.2 Decision Tree (Pseudocode)

```python
class VacuumAgent:

    def run_diagnostic_cycle(self):
        """Main diagnostic loop — called on schedule or user request"""

        findings = []

        # LAYER 0: Is vacuum even possible?
        findings += self.check_autovacuum_enabled()
        findings += self.check_track_counts()

        # LAYER 1: Blockers (must check BEFORE suggesting vacuum)
        findings += self.check_long_running_xacts()
        findings += self.check_idle_in_transaction()
        findings += self.check_replication_slots()
        findings += self.check_prepared_xacts()
        findings += self.check_hot_standby_feedback()

        # LAYER 2: Wraparound (highest priority)
        findings += self.check_xid_wraparound()
        findings += self.check_multixact_wraparound()

        # LAYER 3: Table Bloat
        findings += self.check_dead_tuple_ratios()
        findings += self.check_table_bloat_estimation()

        # LAYER 4: Index Bloat
        findings += self.check_index_bloat()
        findings += self.check_unused_indexes()
        findings += self.check_duplicate_indexes()

        # LAYER 5: TOAST
        findings += self.check_toast_bloat()
        findings += self.check_orphaned_toast()

        # LAYER 6: Catalog
        findings += self.check_catalog_bloat()
        findings += self.check_catalog_toast()

        # LAYER 7: Performance
        findings += self.check_vacuum_progress()
        findings += self.check_vacuum_io_impact()
        findings += self.check_hot_update_ratio()

        # LAYER 8: Configuration
        findings += self.check_autovacuum_config()
        findings += self.check_per_table_overrides()

        # Sort by severity, deduplicate
        findings = self.prioritize(findings)

        return findings

    def check_xid_wraparound(self):
        """The most critical check"""
        results = self.execute(QUERY_17)  # XID age query
        findings = []

        for row in results:
            if row.xid_age > 1_200_000_000:
                findings.append(Finding(
                    severity='P0',
                    category='WRAPAROUND',
                    table=row.table_name,
                    message=f"CRITICAL: {row.table_name} XID age is {row.xid_age:,}. "
                            f"Database WILL shut down at 2B. Immediate action required.",
                    remediation='IMMEDIATE_FREEZE_VACUUM',
                    auto_safe=False  # Never auto-remediate P0
                ))
            elif row.xid_age > 500_000_000:
                findings.append(Finding(
                    severity='P1',
                    category='WRAPAROUND',
                    table=row.table_name,
                    message=f"DANGER: {row.table_name} approaching wraparound. "
                            f"XID age: {row.xid_age:,}",
                    remediation='AGGRESSIVE_VACUUM_FREEZE',
                    auto_safe=True  # Can auto-remediate with caution
                ))
            # ... more thresholds

        return findings

    def check_replication_slots(self):
        """Abandoned slots are silent vacuum killers"""
        results = self.execute(QUERY_22)
        findings = []

        for row in results:
            if not row.active and age(row.xmin) > 100_000_000:
                findings.append(Finding(
                    severity='P1',
                    category='BLOCKER',
                    message=f"Inactive replication slot '{row.slot_name}' is "
                            f"holding back vacuum. XID age: {age(row.xmin):,}. "
                            f"WAL retained: {row.wal_retained}",
                    remediation='DROP_INACTIVE_SLOT',
                    auto_safe=False  # NEVER auto-drop slots
                ))

        return findings
```

### 4.3 Threshold Configuration

```python
# Default thresholds — should be configurable per environment
THRESHOLDS = {
    # Wraparound
    "xid_age_critical":       1_200_000_000,
    "xid_age_danger":           500_000_000,
    "xid_age_warning":          200_000_000,
    "xid_age_elevated":         100_000_000,
    "mxid_age_warning":         200_000_000,

    # Table Bloat
    "dead_tuple_ratio_high":          0.20,  # 20%
    "dead_tuple_ratio_medium":        0.10,  # 10%
    "table_bloat_pct_critical":         50,  # 50% wasted
    "table_bloat_pct_warning":          30,

    # Index Bloat
    "index_to_table_ratio_warning":   2.0,  # Index 2x table size
    "index_unused_min_size_mb":        50,

    # TOAST
    "toast_to_total_ratio_warning":   0.60,  # TOAST > 60% of total
    "toast_chunks_per_row_warning":     50,

    # Catalog
    "catalog_table_size_warning_mb":  500,
    "catalog_dead_tuple_warning":   50000,

    # Vacuum Blockers
    "long_xact_warning_minutes":       30,
    "idle_in_xact_warning_minutes":    10,
    "slot_xmin_age_warning":  100_000_000,

    # Performance
    "hot_update_ratio_warning":       0.50,  # <50% HOT updates
    "vacuum_duration_warning_hours":     2,

    # Config
    "scale_factor_large_table_max":   0.01,  # For tables >10M rows
    "large_table_row_threshold": 10_000_000,
}
```

---

## 5. Remediation Playbooks

### 5.1 Remediation Action Catalog

```
REMEDIATION ACTIONS (ordered by risk):

SAFE (auto-executable):
  ├── ANALYZE table                     — Refresh planner statistics
  ├── VACUUM table                      — Standard vacuum
  ├── VACUUM (VERBOSE) table            — Vacuum with diagnostic output
  ├── ALTER TABLE SET (autovacuum_*)    — Tune per-table autovacuum

MODERATE (auto with caution):
  ├── VACUUM FREEZE table               — Aggressive freeze
  ├── VACUUM (INDEX_CLEANUP OFF)        — Skip index cleanup (emergency)
  ├── VACUUM (TRUNCATE OFF)             — Skip truncation
  ├── SET vacuum_cost_delay = 0         — Remove I/O throttle (temp)
  ├── SET maintenance_work_mem = '1GB'  — Increase vacuum memory (temp)

AGGRESSIVE (requires human approval):
  ├── VACUUM FULL table                 — Rewrites table (locks!)
  ├── REINDEX INDEX CONCURRENTLY        — Rebuild index online
  ├── pg_repack (extension)             — Online table rewrite
  ├── CLUSTER table USING index         — Rewrite + reorder
  ├── DROP INDEX                        — Remove unused index
  ├── pg_drop_replication_slot()        — Drop inactive slot
  ├── pg_terminate_backend(pid)         — Kill blocking session

NUCLEAR (P0 only, DBA must execute):
  ├── VACUUM FREEZE on all tables       — Full cluster freeze
  ├── Stop application writes           — Allow vacuum to catch up
  ├── Single-user mode vacuum           — Last resort
  └── pg_resetwal                       — Absolute last resort (data risk)
```

### 5.2 Playbook: High Table Bloat

```python
def remediate_table_bloat(table, bloat_pct, dead_tuples, table_size_gb):
    """
    Decision logic for table bloat remediation
    """
    steps = []

    # Step 1: Always check for blockers first
    steps.append("CHECK blockers (long xacts, slots, prepared xacts)")

    if bloat_pct < 30:
        # Minor bloat — standard vacuum
        steps.append(f"VACUUM (VERBOSE) {table};")
        steps.append(f"ANALYZE {table};")

    elif bloat_pct < 50:
        # Moderate bloat — aggressive vacuum + config tune
        steps.append(f"SET maintenance_work_mem = '1GB';")
        steps.append(f"VACUUM (VERBOSE) {table};")
        steps.append(f"ANALYZE {table};")
        steps.append(f"""ALTER TABLE {table} SET (
            autovacuum_vacuum_scale_factor = 0.01,
            autovacuum_vacuum_threshold = 1000,
            autovacuum_vacuum_cost_delay = 2
        );""")

    elif table_size_gb < 50:
        # High bloat, manageable size — pg_repack preferred
        steps.append(f"-- OPTION A (preferred, online): pg_repack")
        steps.append(f"pg_repack --no-order --table {table} -d dbname")
        steps.append(f"-- OPTION B (downtime ok): VACUUM FULL")
        steps.append(f"VACUUM FULL {table};  -- WARNING: ACCESS EXCLUSIVE LOCK")

    else:
        # High bloat, huge table — staged approach
        steps.append("-- Staged approach for very large tables:")
        steps.append("-- 1. Reduce new bloat first")
        steps.append(f"""ALTER TABLE {table} SET (
            autovacuum_vacuum_scale_factor = 0.001,
            autovacuum_vacuum_threshold = 500,
            autovacuum_vacuum_cost_delay = 0
        );""")
        steps.append("-- 2. Manual aggressive vacuum")
        steps.append(f"SET maintenance_work_mem = '2GB';")
        steps.append(f"SET vacuum_cost_delay = 0;")
        steps.append(f"VACUUM (VERBOSE) {table};")
        steps.append("-- 3. If still >50% bloat, schedule pg_repack during maintenance")
        steps.append(f"pg_repack --no-order --table {table} -d dbname")

    return steps
```

### 5.3 Playbook: XID Wraparound Emergency

```python
def remediate_wraparound(table, xid_age, severity):
    """
    Wraparound is the ONE problem that can take down the entire database.
    Treat with extreme urgency.
    """
    steps = []

    if severity == 'P0':  # > 1.2B
        steps.append("🚨 EMERGENCY PROTOCOL 🚨")
        steps.append("")
        steps.append("1. IMMEDIATELY check for and remove blockers:")
        steps.append("   -- Kill idle-in-transaction sessions older than 1 min")
        steps.append("   SELECT pg_terminate_backend(pid)")
        steps.append("   FROM pg_stat_activity")
        steps.append("   WHERE state = 'idle in transaction'")
        steps.append("     AND now() - state_change > interval '1 minute';")
        steps.append("")
        steps.append("   -- Check for inactive replication slots")
        steps.append("   SELECT slot_name, active FROM pg_replication_slots")
        steps.append("   WHERE NOT active;")
        steps.append("   -- DROP INACTIVE SLOTS IMMEDIATELY (after confirming)")
        steps.append("")
        steps.append("2. Run emergency vacuum freeze:")
        steps.append(f"   SET vacuum_cost_delay = 0;")
        steps.append(f"   SET maintenance_work_mem = '2GB';")
        steps.append(f"   VACUUM (FREEZE, VERBOSE) {table};")
        steps.append("")
        steps.append("3. Monitor progress:")
        steps.append("   SELECT * FROM pg_stat_progress_vacuum;")
        steps.append("")
        steps.append("4. If vacuum cannot complete (killed, errors):")
        steps.append("   -- Consider stopping all application writes")
        steps.append("   -- As absolute last resort: single-user mode")
        steps.append(f"   -- postgres --single -D $PGDATA dbname")
        steps.append(f"   -- VACUUM FREEZE {table};")

    elif severity == 'P1':  # > 500M
        steps.append("⚠️  URGENT: Schedule vacuum freeze immediately")
        steps.append(f"SET vacuum_cost_delay = 0;")
        steps.append(f"SET maintenance_work_mem = '1GB';")
        steps.append(f"VACUUM (FREEZE, VERBOSE) {table};")
        steps.append(f"""
ALTER TABLE {table} SET (
    autovacuum_freeze_max_age = 100000000,
    autovacuum_vacuum_cost_delay = 0,
    autovacuum_freeze_min_age = 10000000
);""")

    return steps
```

---

## 6. Interactive Chatbot Design

### 6.1 Conversation Flow Architecture

```
USER INPUT
    │
    ▼
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│   INTENT    │────►│   CONTEXT    │────►│   ACTION    │
│  CLASSIFIER │     │  GATHERER    │     │   ENGINE    │
└─────────────┘     └──────────────┘     └─────────────┘
    │                       │                    │
    │  "my table is slow"   │  "which table?"    │  Run diagnostics
    │  "vacuum stuck"       │  "what version?"   │  Generate SQL
    │  "db running out"     │  "how big?"        │  Explain findings
    │                       │                    │
    ▼                       ▼                    ▼
┌─────────────────────────────────────────────────────┐
│              RESPONSE GENERATOR                      │
│  • Plain language explanation                        │
│  • Severity badge                                    │
│  • Actionable SQL                                    │
│  • Safety warnings                                   │
│  • Follow-up suggestions                             │
└─────────────────────────────────────────────────────┘
```

### 6.2 Intent Map

```python
INTENT_MAP = {
    # General health
    "health_check": [
        "is my database healthy",
        "vacuum health check",
        "run diagnostics",
        "check everything",
        "overview"
    ],

    # Specific problems
    "table_bloat": [
        "table is bloated",
        "table too big",
        "disk space growing",
        "dead tuples",
        "table size increasing"
    ],
    "index_bloat": [
        "index bloated",
        "index too big",
        "slow index scan",
        "reindex"
    ],
    "toast_issue": [
        "toast table",
        "large column",
        "jsonb bloat",
        "text column growing"
    ],
    "wraparound": [
        "wraparound",
        "transaction id",
        "xid age",
        "freeze",
        "relfrozenxid",
        "emergency autovacuum",
        "database shutting down"
    ],
    "vacuum_stuck": [
        "vacuum not running",
        "vacuum stuck",
        "autovacuum blocked",
        "vacuum slow",
        "vacuum taking too long"
    ],
    "vacuum_blocked": [
        "long running transaction",
        "idle in transaction",
        "replication slot",
        "what's blocking vacuum"
    ],
    "catalog_issue": [
        "pg_catalog",
        "pg_attribute big",
        "system tables",
        "catalog bloat"
    ],
    "config_review": [
        "vacuum settings",
        "autovacuum configuration",
        "tune autovacuum",
        "per table settings"
    ],

    # Actions
    "run_vacuum": [
        "run vacuum",
        "vacuum this table",
        "fix it"
    ],
    "explain": [
        "what does this mean",
        "explain",
        "why",
        "help me understand"
    ]
}
```

### 6.3 Sample Conversations

#### Conversation 1: Health Check

```
USER: Hey, can you check if my database has any vacuum problems?

AGENT: Sure! I'll run a full vacuum health check. Let me gather some info first.

       📊 Connecting to your database...

       Here's what I found:

       ┌──────────────────────────────────────────────────┐
       │ 🔴 1 CRITICAL issue                              │
       │ 🟡 3 WARNING issues                              │
       │ 🟢 Database is otherwise healthy                  │
       └──────────────────────────────────────────────────┘

       🔴 CRITICAL — XID Wraparound Risk
       Table `orders` has XID age of 680,000,000 (32% towards
       hard limit). Autovacuum is trying but being blocked by an
       idle-in-transaction session (PID 4521, idle for 6 hours).

       🟡 WARNING — Table Bloat
       • `user_sessions` — 42% bloat (8.2 GB wasted)
       • `audit_log` — 38% bloat (12.1 GB wasted)

       🟡 WARNING — Unused Indexes
       3 indexes totaling 4.7 GB have zero scans in the last
       30 days. These slow down every vacuum cycle.

       Want me to:
       1. Fix the wraparound issue first (recommended)?
       2. Show me the details on all findings?
       3. Generate a remediation plan for everything?

USER: Fix the wraparound first, that sounds scary.

AGENT: You're right to prioritize this. Here's my plan:

       Step 1: The idle-in-transaction session (PID 4521) has been
       open for 6 hours running this query:
       `SELECT * FROM orders WHERE status = 'pending'`

       This is from user `app_readonly`. It looks like an
       abandoned connection from your application.

       ⚠️  I need your permission to terminate this session.
       This will roll back any uncommitted work in that session.

       Should I proceed? [Yes / No / Show me more]

USER: Yes, kill it.

AGENT: ✅ Session PID 4521 terminated.

       Now running emergency vacuum freeze on `orders`...

       ⏳ Progress:
       Phase: scanning heap
       Progress: 23% (scanning 1.2M of 5.1M pages)
       Estimated time remaining: ~18 minutes

       I'll keep monitoring. In the meantime, I'm also setting up
       per-table autovacuum tuning for `orders` to prevent this
       from happening again:

       ALTER TABLE orders SET (
           autovacuum_freeze_max_age = 100000000,
           autovacuum_vacuum_cost_delay = 2,
           autovacuum_vacuum_scale_factor = 0.01
       );

       I'll update you when the vacuum completes. Want me to
       tackle the table bloat issues while we wait?
```

#### Conversation 2: Investigating Disk Usage

```
USER: My disk usage is growing really fast. Is it vacuum related?

AGENT: Could be! Let me check what's eating your disk.

       🔍 Analyzing...

       Here's what I found — your total database is 847 GB:

       📦 Top Space Consumers:
       ┌──────────────────┬─────────┬──────────┬────────┐
       │ Table            │ Total   │ Bloat    │ Toast  │
       ├──────────────────┼─────────┼──────────┼────────┤
       │ events           │ 312 GB  │ 156 GB   │ 89 GB  │
       │ audit_log        │ 198 GB  │ 82 GB    │ 4 GB   │
       │ user_sessions    │ 67 GB   │ 31 GB    │ —      │
       │ notifications    │ 43 GB   │ 8 GB     │ 22 GB  │
       └──────────────────┴─────────┴──────────┴────────┘

       The `events` table is your biggest problem:
       • 50% of the table is dead space (bloat)
       • It has a `payload` JSONB column averaging 4.2 KB — this
         is being TOASTed and the TOAST table has 89 GB
       • Autovacuum runs on it but can't keep up — you're doing
         ~50K updates/minute but vacuum only reclaims ~20K/minute

       Root cause: The autovacuum cost_delay is set to the
       default (2ms). For a table this active, vacuum is being
       throttled too aggressively.

       My recommendation:
       1. Tune autovacuum for this specific table (no downtime)
       2. Run a manual aggressive vacuum right now
       3. Consider pg_repack during next maintenance window to
          reclaim the existing 156 GB

       Which would you like to start with?
```

#### Conversation 3: Non-Technical User

```
USER: Our app is getting slower every day and I don't really know
      PostgreSQL that well. Someone said vacuum might be the issue?

AGENT: No worries, I'll explain everything in plain terms!

       Think of your database like a filing cabinet. When you
       delete or update records, PostgreSQL doesn't immediately
       throw away the old papers — it marks them as "trash" but
       leaves them in the drawer. VACUUM is like the cleaning
       crew that comes through and actually removes the trash.

       Let me check if your cleaning crew is falling behind...

       🔍 Checking...

       Yes, that's exactly your problem! Here's what's happening:

       📋 The Short Version:
       Your database has accumulated about 45 GB of "trash"
       (dead data) that hasn't been cleaned up. This makes
       everything slower because the database has to step over
       all that trash to find the real data.

       🔧 The Good News:
       This is very fixable. I can run a cleanup operation that
       will start working immediately. Your app should get
       noticeably faster within about 30 minutes.

       The cleanup won't affect your running application — it
       works in the background.

       Shall I start the cleanup? I'll also set up better
       automatic cleaning so this doesn't happen again.

USER: Yes please!

AGENT: ✅ Starting cleanup now. Here's what I'm doing:

       1. ✅ Starting vacuum on `orders` (biggest problem)
       2. ⏳ Queued: `users`, `products`, `sessions`
       3. ✅ Adjusted automatic cleaning schedule to be more
          frequent for your busiest tables

       I'll give you a progress update every few minutes.
       The whole process should take about 45 minutes.

       💡 Tip: The most common cause of this problem is
       long-running database connections that never close.
       You might want to check if your application has a
       connection pool configured with a maximum lifetime.
       Want me to check for that too?
```

### 6.4 Response Templates

```python
TEMPLATES = {
    "finding_critical": """
🔴 **CRITICAL: {title}**

**What's happening:** {explanation}

**Risk:** {risk_description}

**Immediate action needed:**
```sql
{remediation_sql}
```

⚠️  {safety_warning}
""",

    "finding_warning": """
🟡 **WARNING: {title}**

{explanation}

**Impact:** {impact}

**Recommended fix:**
```sql
{remediation_sql}
```
""",

    "finding_info": """
ℹ️  **{title}**

{explanation}

**Suggestion:** {suggestion}
""",

    "progress_update": """
⏳ **Vacuum Progress on `{table}`**

Phase: {phase}
Progress: {pct_complete}% ({pages_done:,} / {pages_total:,} pages)
Dead tuples found: {dead_tuples:,}
Index passes: {index_passes}
Estimated time remaining: ~{eta}
""",

    "completion": """
✅ **Vacuum complete on `{table}`**

• Dead tuples removed: {dead_removed:,}
• Space reclaimed: {space_reclaimed}
• Duration: {duration}
• XID age after: {new_xid_age:,}

{follow_up_suggestion}
"""
}
```

---

## 7. Autonomous Mode — Continuous Monitoring

### 7.1 Monitoring Schedule

```python
MONITORING_SCHEDULE = {
    # Check interval, what to check, alert if changed
    "every_1_minute": [
        "vacuum_progress",          # Track running vacuums
        "autovacuum_worker_count",  # Workers busy?
    ],
    "every_5_minutes": [
        "long_running_xacts",       # Transactions blocking vacuum
        "idle_in_transaction",      # Silent killers
        "autovacuum_blocked",       # Is autovacuum waiting on locks?
    ],
    "every_15_minutes": [
        "dead_tuple_growth_rate",   # Is bloat accumulating?
        "xid_age_delta",            # Is wraparound approaching?
        "replication_slot_health",  # Slots holding back vacuum?
    ],
    "every_1_hour": [
        "table_bloat_estimation",   # Full bloat check
        "index_bloat_check",        # Index sizes
        "toast_anomaly_check",      # TOAST table health
        "catalog_bloat_check",      # System table health
    ],
    "every_6_hours": [
        "full_health_assessment",   # Complete diagnostic suite
        "config_drift_check",       # Have settings changed?
        "trend_analysis",           # Getting better or worse?
    ],
    "daily": [
        "wraparound_forecast",      # Days until danger zone
        "bloat_trend_report",       # Historical bloat tracking
        "unused_index_report",      # Indexes slowing vacuum
        "maintenance_recommendations", # Weekly tuning suggestions
    ]
}
```

### 7.2 Alert Escalation

```python
ESCALATION_MATRIX = {
    "P0": {
        "channels": ["pagerduty", "slack_critical", "email_oncall", "sms"],
        "auto_remediate": False,
        "require_ack": True,
        "repeat_interval": "5 minutes until acknowledged",
        "message_prefix": "🚨 EMERGENCY"
    },
    "P1": {
        "channels": ["slack_urgent", "email_team"],
        "auto_remediate": True,  # With guardrails
        "require_ack": True,
        "repeat_interval": "15 minutes",
        "message_prefix": "⚠️  URGENT"
    },
    "P2": {
        "channels": ["slack_alerts"],
        "auto_remediate": True,
        "require_ack": False,
        "repeat_interval": "1 hour",
        "message_prefix": "🟡 Warning"
    },
    "P3": {
        "channels": ["slack_info"],
        "auto_remediate": True,
        "require_ack": False,
        "repeat_interval": "6 hours",
        "message_prefix": "ℹ️  Info"
    }
}
```

### 7.3 Trend Analysis Queries

```sql
-- Q32: Dead tuple growth rate (requires pg_stat_user_tables snapshots)
-- Store snapshots in a tracking table:
CREATE TABLE IF NOT EXISTS vacuum_agent.stat_snapshots (
    snapshot_time    timestamptz DEFAULT now(),
    schemaname       text,
    relname          text,
    n_live_tup       bigint,
    n_dead_tup       bigint,
    n_tup_ins        bigint,
    n_tup_upd        bigint,
    n_tup_del        bigint,
    n_tup_hot_upd    bigint,
    last_vacuum      timestamptz,
    last_autovacuum  timestamptz,
    xid_age          bigint
);

-- Snapshot collection query (run every 15 min)
INSERT INTO vacuum_agent.stat_snapshots
SELECT
    now(),
    schemaname, relname,
    n_live_tup, n_dead_tup,
    n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
    last_vacuum, last_autovacuum,
    age(c.relfrozenxid)
FROM pg_stat_user_tables s
JOIN pg_class c ON c.relname = s.relname
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = s.schemaname;

-- Q33: Dead tuple growth rate over last hour
SELECT
    relname,
    max(n_dead_tup) - min(n_dead_tup) AS dead_tuple_growth,
    (max(n_dead_tup) - min(n_dead_tup))::float /
        EXTRACT(EPOCH FROM max(snapshot_time) - min(snapshot_time)) * 60
        AS dead_tuples_per_minute,
    max(n_dead_tup) AS current_dead
FROM vacuum_agent.stat_snapshots
WHERE snapshot_time > now() - interval '1 hour'
GROUP BY relname
HAVING max(n_dead_tup) - min(n_dead_tup) > 1000
ORDER BY dead_tuple_growth DESC;

-- Q34: XID age velocity (days until danger zone)
SELECT
    relname,
    max(xid_age) AS current_age,
    (max(xid_age) - min(xid_age))::float /
        NULLIF(EXTRACT(EPOCH FROM max(snapshot_time) - min(snapshot_time)), 0)
        * 86400 AS xid_growth_per_day,
    CASE
        WHEN (max(xid_age) - min(xid_age)) > 0
        THEN ((500000000 - max(xid_age))::float /
              ((max(xid_age) - min(xid_age))::float /
               NULLIF(EXTRACT(EPOCH FROM max(snapshot_time) - min(snapshot_time)), 0)
               * 86400))
        ELSE NULL
    END AS days_until_danger
FROM vacuum_agent.stat_snapshots
WHERE snapshot_time > now() - interval '24 hours'
GROUP BY relname
HAVING max(xid_age) > 100000000
ORDER BY max(xid_age) DESC;
```

---

## 8. Agent State Machine

### 8.1 States

```
┌─────────┐     ┌──────────┐     ┌───────────┐     ┌──────────┐
│  IDLE   │────►│ SCANNING │────►│ ANALYZING │────►│ DECIDING │
└─────────┘     └──────────┘     └───────────┘     └──────────┘
     ▲                                                    │
     │                                              ┌─────┴─────┐
     │                                              ▼           ▼
     │                                        ┌──────────┐ ┌──────────┐
     │                                        │ AUTO-FIX │ │ ASK-USER │
     │                                        └────┬─────┘ └────┬─────┘
     │                                             │             │
     │                                             ▼             ▼
     │                                        ┌──────────┐ ┌──────────┐
     │                                        │ EXECUTING│ │ WAITING  │
     │                                        └────┬─────┘ └────┬─────┘
     │                                             │             │
     │                                             ▼             ▼
     │                                        ┌──────────────────────┐
     └────────────────────────────────────────│      VERIFYING       │
                                              └──────────────────────┘
```

### 8.2 State Definitions

```python
class AgentState(Enum):
    IDLE       = "idle"        # Waiting for trigger or schedule
    SCANNING   = "scanning"    # Running diagnostic queries
    ANALYZING  = "analyzing"   # Processing results, classifying
    DECIDING   = "deciding"    # Determining remediation
    AUTO_FIX   = "auto_fix"    # Executing safe auto-remediation
    ASK_USER   = "ask_user"    # Waiting for human approval
    WAITING    = "waiting"     # User hasn't responded yet
    EXECUTING  = "executing"   # Running remediation action
    VERIFYING  = "verifying"   # Confirming fix was effective

class Finding:
    severity: str          # P0-P5
    category: str          # WRAPAROUND, BLOAT, INDEX, TOAST, etc.
    table: Optional[str]
    message: str           # Human-readable description
    technical_detail: str  # SQL output, numbers
    remediation: str       # Remediation playbook key
    auto_safe: bool        # Can be auto-remediated?
    sql: List[str]         # Remediation SQL statements
    risk: str              # What could go wrong
    verification_query: str # SQL to verify fix worked

class AgentContext:
    mode: str              # 'autonomous' | 'interactive'
    pg_version: int        # PostgreSQL major version
    is_primary: bool       # Primary or replica
    has_replicas: bool     # Replication topology
    extensions: List[str]  # Available extensions
    db_size_gb: float      # Total database size
    findings: List[Finding]
    history: List[dict]    # Conversation/action history
    thresholds: dict       # Configurable thresholds
```

---

## 9. Safety & Guardrails

### 9.1 Never Auto-Execute

```python
NEVER_AUTO_EXECUTE = [
    "VACUUM FULL",            # Takes ACCESS EXCLUSIVE lock
    "DROP INDEX",             # Irreversible
    "DROP TABLE",             # Irreversible
    "pg_drop_replication_slot",  # Could break replication
    "pg_terminate_backend",   # Could kill application sessions
    "TRUNCATE",               # Data loss
    "REINDEX",                # Non-concurrent takes lock
    "CLUSTER",                # Takes ACCESS EXCLUSIVE lock
    "ALTER SYSTEM",           # Changes cluster config
    "pg_resetwal",            # Data corruption risk
]
```

### 9.2 Pre-Flight Checks

```python
def pre_flight_check(action, table, context):
    """Run before any remediation action"""
    checks = []

    # Check 1: Is this a production system?
    if context.is_production:
        checks.append(("production_guard",
            "This is a production system. Extra caution applied."))

    # Check 2: Is the table currently being written to heavily?
    if get_tps(table) > 1000:
        checks.append(("high_tps_warning",
            f"Table {table} has >1000 TPS. Vacuum may be slower."))

    # Check 3: Is there enough disk space for the operation?
    if action in ("VACUUM FULL", "REINDEX", "pg_repack"):
        free_space = get_free_disk_space()
        table_size = get_table_size(table)
        if free_space < table_size * 1.2:
            return PreFlightResult(
                safe=False,
                reason=f"Insufficient disk space. Need {table_size * 1.2:.0f} GB "
                       f"but only {free_space:.0f} GB free."
            )

    # Check 4: Is replication healthy?
    if context.has_replicas and action in ("VACUUM FULL", "VACUUM FREEZE"):
        lag = get_max_replica_lag()
        if lag > timedelta(minutes=30):
            checks.append(("replication_lag",
                f"Replica lag is {lag}. Aggressive vacuum may increase it."))

    # Check 5: Is there a maintenance window?
    if action in NEVER_AUTO_EXECUTE:
        if not in_maintenance_window():
            return PreFlightResult(
                safe=False,
                reason="This action requires a maintenance window."
            )

    return PreFlightResult(safe=True, warnings=checks)
```

### 9.3 Rollback Awareness

```python
ROLLBACK_CAPABILITY = {
    "VACUUM":                "Safe — no rollback needed, no data change",
    "VACUUM FREEZE":         "Safe — no rollback needed, no data change",
    "ANALYZE":               "Safe — only updates statistics",
    "ALTER TABLE SET":       "Reversible — can reset to defaults",
    "VACUUM FULL":           "Cannot rollback — but data is preserved, just reorganized",
    "REINDEX CONCURRENTLY":  "Safe — old index kept until new one ready",
    "REINDEX":               "Cannot rollback — index rebuilt in place",
    "pg_repack":             "Safe — uses shadow table, atomic swap",
    "DROP INDEX":            "IRREVERSIBLE — must recreate manually",
    "pg_terminate_backend":  "IRREVERSIBLE — session terminated",
    "DROP SLOT":             "IRREVERSIBLE — slot and WAL retention gone",
}
```

---

## 10. Implementation Reference

### 10.1 Tech Stack Suggestions

```
┌─────────────────────────────────────────────────────┐
│                   VACUUM AGENT                       │
├─────────────────────────────────────────────────────┤
│                                                      │
│  CORE ENGINE            │  INTERFACE                 │
│  • Python 3.11+         │  • FastAPI (REST API)      │
│  • psycopg3 (async)     │  • WebSocket (live chat)   │
│  • SQLAlchemy (ORM)     │  • Slack Bot SDK           │
│  • APScheduler (cron)   │  • CLI (Click/Typer)       │
│                         │  • Streamlit (dashboard)   │
│  LLM LAYER              │                            │
│  • Claude API           │  STORAGE                   │
│  • LangChain/LangGraph  │  • PostgreSQL (meta DB)    │
│  • Function calling     │  • Redis (state/cache)     │
│                         │                            │
│  MONITORING             │  ALERTING                  │
│  • Prometheus metrics   │  • PagerDuty               │
│  • Grafana dashboards   │  • Slack webhooks          │
│  • Custom stat tables   │  • Email (SES/SMTP)        │
│                         │                            │
└─────────────────────────────────────────────────────┘
```

### 10.2 Database Schema for Agent State

```sql
-- Schema for the agent's own metadata
CREATE SCHEMA IF NOT EXISTS vacuum_agent;

-- Tracked databases
CREATE TABLE vacuum_agent.monitored_databases (
    id              serial PRIMARY KEY,
    name            text NOT NULL,
    connection_string text NOT NULL,  -- encrypted
    is_primary      boolean DEFAULT true,
    pg_version      int,
    environment     text DEFAULT 'production',
    enabled         boolean DEFAULT true,
    created_at      timestamptz DEFAULT now()
);

-- Diagnostic findings history
CREATE TABLE vacuum_agent.findings (
    id              bigserial PRIMARY KEY,
    database_id     int REFERENCES vacuum_agent.monitored_databases(id),
    found_at        timestamptz DEFAULT now(),
    severity        text NOT NULL,  -- P0-P5
    category        text NOT NULL,  -- WRAPAROUND, BLOAT, etc.
    table_name      text,
    message         text NOT NULL,
    technical_detail jsonb,
    remediation     text,
    auto_safe       boolean,
    status          text DEFAULT 'open',  -- open, acknowledged, resolved, false_positive
    resolved_at     timestamptz,
    resolved_by     text  -- 'agent' or username
);

-- Actions taken
CREATE TABLE vacuum_agent.actions (
    id              bigserial PRIMARY KEY,
    finding_id      bigint REFERENCES vacuum_agent.findings(id),
    database_id     int REFERENCES vacuum_agent.monitored_databases(id),
    action_type     text NOT NULL,  -- VACUUM, VACUUM_FREEZE, ALTER_TABLE, etc.
    sql_executed    text,
    started_at      timestamptz DEFAULT now(),
    completed_at    timestamptz,
    success         boolean,
    result          jsonb,
    approved_by     text,  -- 'auto' or username
    pre_state       jsonb, -- snapshot before action
    post_state      jsonb  -- snapshot after action
);

-- Stat snapshots for trend analysis (see Section 7.3)
-- (vacuum_agent.stat_snapshots defined above)

-- Conversation history (for interactive mode)
CREATE TABLE vacuum_agent.conversations (
    id              bigserial PRIMARY KEY,
    session_id      uuid NOT NULL,
    timestamp       timestamptz DEFAULT now(),
    role            text NOT NULL,  -- 'user' or 'agent'
    message         text NOT NULL,
    context         jsonb,  -- agent state at time of message
    findings_ref    bigint[]  -- related finding IDs
);

-- Thresholds (configurable per database)
CREATE TABLE vacuum_agent.thresholds (
    id              serial PRIMARY KEY,
    database_id     int REFERENCES vacuum_agent.monitored_databases(id),
    threshold_key   text NOT NULL,
    threshold_value numeric NOT NULL,
    updated_at      timestamptz DEFAULT now(),
    updated_by      text,
    UNIQUE (database_id, threshold_key)
);

-- Create indexes
CREATE INDEX idx_findings_severity ON vacuum_agent.findings(severity, status);
CREATE INDEX idx_findings_database ON vacuum_agent.findings(database_id, found_at);
CREATE INDEX idx_actions_finding ON vacuum_agent.actions(finding_id);
CREATE INDEX idx_snapshots_time ON vacuum_agent.stat_snapshots(snapshot_time);
CREATE INDEX idx_snapshots_table ON vacuum_agent.stat_snapshots(relname, snapshot_time);
```

### 10.3 LLM Integration — Function Calling Schema

```python
# Define tools/functions the LLM agent can call

AGENT_TOOLS = [
    {
        "name": "run_diagnostic",
        "description": "Run a specific diagnostic check against the database",
        "parameters": {
            "type": "object",
            "properties": {
                "check_type": {
                    "type": "string",
                    "enum": [
                        "health_overview",
                        "wraparound_check",
                        "table_bloat",
                        "index_bloat",
                        "toast_health",
                        "catalog_health",
                        "vacuum_blockers",
                        "vacuum_progress",
                        "autovacuum_config",
                        "dead_tuple_ranking",
                        "hot_update_efficiency",
                        "replication_slots",
                        "long_running_xacts",
                        "full_diagnostic"
                    ]
                },
                "table_name": {
                    "type": "string",
                    "description": "Optional: specific table to check"
                }
            },
            "required": ["check_type"]
        }
    },
    {
        "name": "execute_remediation",
        "description": "Execute a remediation action (safe actions only in auto mode)",
        "parameters": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": [
                        "vacuum",
                        "vacuum_verbose",
                        "vacuum_freeze",
                        "vacuum_full",
                        "analyze",
                        "reindex_concurrently",
                        "set_table_autovacuum",
                        "set_session_param",
                        "terminate_backend",
                        "drop_replication_slot",
                        "pg_repack"
                    ]
                },
                "table_name": {"type": "string"},
                "parameters": {
                    "type": "object",
                    "description": "Action-specific parameters"
                },
                "reason": {
                    "type": "string",
                    "description": "Why this action is being taken"
                }
            },
            "required": ["action", "reason"]
        }
    },
    {
        "name": "get_table_info",
        "description": "Get detailed info about a specific table",
        "parameters": {
            "type": "object",
            "properties": {
                "table_name": {"type": "string"},
                "include": {
                    "type": "array",
                    "items": {
                        "type": "string",
                        "enum": [
                            "size", "bloat", "indexes", "toast",
                            "stats", "config", "columns", "constraints"
                        ]
                    }
                }
            },
            "required": ["table_name"]
        }
    },
    {
        "name": "explain_to_user",
        "description": "Generate a plain-language explanation of a finding",
        "parameters": {
            "type": "object",
            "properties": {
                "finding_id": {"type": "integer"},
                "detail_level": {
                    "type": "string",
                    "enum": ["beginner", "intermediate", "expert"]
                }
            },
            "required": ["finding_id"]
        }
    },
    {
        "name": "get_trend",
        "description": "Get historical trend data for a metric",
        "parameters": {
            "type": "object",
            "properties": {
                "metric": {
                    "type": "string",
                    "enum": [
                        "dead_tuples", "xid_age", "table_size",
                        "bloat_pct", "vacuum_frequency"
                    ]
                },
                "table_name": {"type": "string"},
                "period": {
                    "type": "string",
                    "enum": ["1h", "6h", "24h", "7d", "30d"]
                }
            },
            "required": ["metric", "period"]
        }
    }
]
```

### 10.4 System Prompt for LLM Agent

```
You are a PostgreSQL Vacuum Expert Agent. Your role is to detect, diagnose,
and help resolve all vacuum-related problems in PostgreSQL databases.

PERSONALITY:
- You are calm, precise, and reassuring — especially during emergencies
- You explain complex concepts using simple analogies when talking to
  non-technical users
- You always state the severity and risk clearly
- You never execute destructive actions without explicit approval
- You provide SQL that can be copy-pasted directly

DIAGNOSTIC PROTOCOL:
1. Always check for BLOCKERS before suggesting vacuum actions
2. Always prioritize WRAPAROUND over bloat — wraparound kills databases
3. Validate findings before alarming users — check if stats are current
4. Consider the full picture — bloat might be a symptom of a blocked vacuum

COMMUNICATION RULES:
- Lead with severity: 🔴 Critical, 🟡 Warning, 🟢 OK, ℹ️ Info
- Give the "so what" before the technical details
- Always offer next steps — never leave the user wondering what to do
- If you're not sure, say so and suggest what to check
- For non-technical users, use analogies (filing cabinet, cleaning crew)
- For DBAs, be direct and technical — they appreciate efficiency

SAFETY RULES:
- NEVER auto-execute VACUUM FULL, DROP, TRUNCATE, or pg_terminate_backend
- ALWAYS run pre-flight checks before remediation
- ALWAYS verify remediation was effective after execution
- If disk space < 20% free, warn before any vacuum operation
- If the system is a primary with replicas, consider replication impact
- Log every action taken for audit trail

KNOWLEDGE:
- You have deep knowledge of PostgreSQL internals (buffer manager,
  visibility map, free space map, MVCC, WAL)
- You understand autovacuum launcher/worker architecture
- You know the difference between lazy vacuum, eager vacuum,
  anti-wraparound vacuum, and VACUUM FULL
- You understand TOAST internals and chunk storage
- You can read and explain pg_stat_* views
- You know pg_repack, pgstattuple, pg_visibility extensions
```

### 10.5 Quick Reference — All Queries by Category

| # | Query | Category | Use Case |
|---|-------|----------|----------|
| Q00 | Master Health Check | Overview | First query in every session |
| Q01 | Autovacuum Workers | Status | What's running now |
| Q02 | Vacuum Config | Config | Current settings |
| Q03 | Tables Needing Vacuum | Status | Overdue tables |
| Q04 | Table Bloat (stats) | Bloat | Estimate without extension |
| Q05 | Table Bloat (pgstattuple) | Bloat | Precise measurement |
| Q06 | Index Size Analysis | Index | Index vs table ratio |
| Q07 | Unused Indexes | Index | Vacuum speed improvement |
| Q08 | Duplicate Indexes | Index | Wasted space/effort |
| Q09 | Index Bloat (pgstatindex) | Index | Precise measurement |
| Q10 | TOAST Table Sizes | TOAST | TOAST proportion |
| Q11 | Orphaned TOAST | TOAST | Suspicious chunk counts |
| Q12 | TOAST Dead Tuples | TOAST | TOAST vacuum status |
| Q13 | TOAST-prone Columns | TOAST | Column analysis |
| Q14 | Catalog Table Sizes | Catalog | System table health |
| Q15 | pg_attribute Bloat | Catalog | DDL aftermath |
| Q16 | Catalog TOAST | Catalog | Catalog TOAST tables |
| Q17 | XID Wraparound | Wraparound | **CRITICAL** — table level |
| Q18 | DB Wraparound | Wraparound | Database level |
| Q19 | MultiXact Age | Wraparound | MXID wraparound |
| Q20 | Long Transactions | Blockers | Vacuum blockers |
| Q21 | Idle in Transaction | Blockers | Silent killers |
| Q22 | Replication Slots | Blockers | Slot health |
| Q23 | Prepared Xacts | Blockers | 2PC cleanup |
| Q24 | Autovacuum Lock Waits | Blockers | Who blocks autovacuum |
| Q25 | Vacuum Progress | Performance | Live progress |
| Q26 | Vacuum History | Performance | Last vacuum times |
| Q27 | Dead Tuple Ranking | Performance | Priority queue |
| Q28 | HOT Update Ratio | Performance | Update efficiency |
| Q29 | Fillfactor Settings | Performance | HOT enablement |
| Q30 | Visibility Map | Internals | VM coverage |
| Q31 | Free Space Map | Internals | FSM accuracy |
| Q32 | Stat Snapshot Insert | Trending | Collect snapshots |
| Q33 | Dead Tuple Growth | Trending | Bloat velocity |
| Q34 | XID Age Velocity | Trending | Wraparound forecast |

---

## Appendix A: PostgreSQL Version Compatibility

| Feature | PG 12 | PG 13 | PG 14 | PG 15 | PG 16 | PG 17 |
|---------|-------|-------|-------|-------|-------|-------|
| pg_stat_progress_vacuum | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| VACUUM (PARALLEL) | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ |
| INDEX_CLEANUP option | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ |
| PROCESS_MAIN option | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| PROCESS_TOAST option | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| BUFFER_USAGE_LIMIT | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ |
| SKIP_DATABASE_STATS | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ |
| pg_stat_get_last_idx_scan_time | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ |
| VACUUM (ONLY_DATABASE_STATS) | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ |
| Failsafe autovacuum (age>1.6B) | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ |

## Appendix B: Key pg_settings for Vacuum

```
autovacuum = on                        # Enable autovacuum
autovacuum_max_workers = 3             # Max concurrent workers
autovacuum_naptime = 1min              # Delay between runs

autovacuum_vacuum_threshold = 50       # Min dead tuples before vacuum
autovacuum_vacuum_scale_factor = 0.2   # Fraction of table size
autovacuum_vacuum_insert_threshold = 1000  # (PG13+) inserts trigger
autovacuum_vacuum_insert_scale_factor = 0.2

autovacuum_analyze_threshold = 50
autovacuum_analyze_scale_factor = 0.1

autovacuum_freeze_max_age = 200000000  # Force anti-wraparound vacuum
autovacuum_multixact_freeze_max_age = 400000000

vacuum_cost_delay = 2ms                # I/O throttle delay
vacuum_cost_limit = 200                # Cost units before sleeping
autovacuum_vacuum_cost_delay = 2ms     # Autovacuum specific
autovacuum_vacuum_cost_limit = -1      # -1 = use vacuum_cost_limit

vacuum_freeze_min_age = 50000000       # Min age to freeze
vacuum_freeze_table_age = 150000000    # Age to trigger whole-table scan
vacuum_multixact_freeze_min_age = 5000000
vacuum_multixact_freeze_table_age = 150000000

maintenance_work_mem = 64MB            # Memory for vacuum (increase!)
autovacuum_work_mem = -1               # -1 = use maintenance_work_mem

log_autovacuum_min_duration = 0        # Log all autovacuum runs (ms)
```

---

*Document Version: 1.0*
*Covers PostgreSQL 12–17*
*Last Updated: February 2026*
