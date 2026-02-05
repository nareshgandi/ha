# Cloud SQL for PostgreSQL — Alerting & Automation Guide

Set up production-grade monitoring for one Cloud SQL PostgreSQL instance, then automate it so every future instance gets the same treatment — zero manual work.

---

## Table of Contents

- [Strategy Overview](#strategy-overview)
- [Part A: One-Time Setup (Covers All Instances)](#part-a-one-time-setup-covers-all-instances)
  - [1. Notification Channels](#1-notification-channels)
  - [2. Project-Wide Alert Policies (Metric-Based)](#2-project-wide-alert-policies-metric-based)
  - [3. Log-Based Metrics & Alerts](#3-log-based-metrics--alerts)
- [Part B: Per-Instance Setup (Current Instance)](#part-b-per-instance-setup-current-instance)
  - [4. Enable Database Flags](#4-enable-database-flags)
- [Part C: Automate for New Instances](#part-c-automate-for-new-instances)
  - [5. Option 1 — Terraform Module (Recommended)](#5-option-1--terraform-module-recommended)
  - [6. Option 2 — Eventarc + Cloud Function](#6-option-2--eventarc--cloud-function)
  - [7. Option 3 — Org Policy + Instance Template](#7-option-3--org-policy--instance-template)
- [Diagnostic Queries](#diagnostic-queries)
- [Quick Reference Table](#quick-reference-table)

---

## Strategy Overview

There are two separate problems:

| What | Scope | Needs Per-Instance Work? |
|------|-------|--------------------------|
| **Alert policies** (CPU, memory, disk, instance state, TXID age, replication lag) | Project-wide — one policy covers all current AND future instances automatically | No |
| **Log-based alerts** (checkpoints, autovacuum, deadlocks) | Project-wide — but only fires if the instance has the right **database flags** enabled | Partially |
| **Database flags** (`log_checkpoints`, `log_autovacuum_min_duration`, etc.) | Per-instance — must be set on each instance individually | Yes |

**The key insight:** Cloud Monitoring alert policies use `resource.type = "cloudsql_database"` without instance-specific filters, so they automatically apply to every Cloud SQL instance in the project. The only thing you need to automate per-instance is the **database flags**.

```
┌──────────────────────────────────────────────────────────────────────┐
│                        SETUP ONCE (Part A)                          │
│                                                                      │
│   Notification Channels ──► Alert Policies (project-wide)            │
│                              ├── Instance state != RUNNING           │
│                              ├── CPU > 80%                           │
│                              ├── Memory > 85%                        │
│                              ├── Disk > 85%                          │
│                              ├── TXID age > 500M / 1B / 1.5B        │
│                              └── Replication lag > 30s               │
│                                                                      │
│   Log-Based Metrics ──► Log-Based Alert Policies (project-wide)      │
│                          ├── Checkpoints too frequent                 │
│                          ├── Autovacuum canceled                      │
│                          ├── Anti-wraparound vacuum                   │
│                          └── Deadlocks detected                      │
├──────────────────────────────────────────────────────────────────────┤
│                    PER-INSTANCE (Part B + C)                          │
│                                                                      │
│   Database Flags ──► Enables log entries that feed log-based alerts   │
│     log_checkpoints=on                                               │
│     log_autovacuum_min_duration=60000                                │
│     log_lock_waits=on                                                │
│     log_connections=on                                               │
│     ...                                                              │
│                                                                      │
│   Automated via:                                                     │
│     Option 1: Terraform module (all instances defined in code)       │
│     Option 2: Eventarc -> Cloud Function (auto-patch new instances)  │
│     Option 3: Terraform instance template with flags built-in        │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Part A: One-Time Setup (Covers All Instances)

These steps are done once per project. Every Cloud SQL instance (existing and future) is covered automatically.

### 1. Notification Channels

#### Terraform

```hcl
resource "google_monitoring_notification_channel" "email" {
  display_name = "DBA Team Email"
  type         = "email"
  labels = {
    email_address = "dba-alerts@yourcompany.com"
  }
}

resource "google_monitoring_notification_channel" "slack" {
  display_name = "DBA Slack Channel"
  type         = "slack"
  labels = {
    channel_name = "#dba-alerts"
  }
  sensitive_labels {
    auth_token = var.slack_auth_token
  }
}

resource "google_monitoring_notification_channel" "pagerduty" {
  display_name = "DBA PagerDuty"
  type         = "pagerduty"
  labels = {
    service_key = var.pagerduty_service_key
  }
}
```

#### gcloud CLI

```bash
# Create email channel
CHANNEL_ID=$(gcloud beta monitoring channels create \
  --display-name="DBA Email" \
  --type=email \
  --channel-labels=email_address=dba-alerts@yourcompany.com \
  --format="value(name)")

echo "Channel: $CHANNEL_ID"

# List all channels (for reference)
gcloud beta monitoring channels list \
  --format="table(name, displayName, type)"
```

---

### 2. Project-Wide Alert Policies (Metric-Based)

> **No instance filter = covers all instances automatically.**
> When a new Cloud SQL instance is created, these policies start monitoring it immediately.

#### 2a. Instance Down / Not Running

```hcl
resource "google_monitoring_alert_policy" "instance_down" {
  display_name = "CloudSQL PG - Instance Not Running"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "Instance state is not RUNNING"
    condition_threshold {
      filter = <<-EOT
        resource.type = "cloudsql_database"
        AND metric.type = "cloudsql.googleapis.com/database/instance_state"
      EOT
      comparison      = "COMPARISON_NE"
      threshold_value = 0
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
      trigger { count = 1 }
    }
  }

  notification_channels = var.notification_channel_ids

  documentation {
    content   = <<-EOD
      ## Instance Not Running

      **Instance:** $${resource.label.database_id}

      ### Immediate Actions
      1. Check instance status: `gcloud sql instances describe INSTANCE_NAME`
      2. Review operations log: Console > Cloud SQL > Instance > Operations
      3. Check for maintenance events
      4. If FAILED, check audit logs for root cause
    EOD
    mime_type = "text/markdown"
  }
}
```

#### 2b. CPU Utilization > 80%

```hcl
resource "google_monitoring_alert_policy" "cpu_high" {
  display_name = "CloudSQL PG - CPU > 80%"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "CPU utilization high"
    condition_threshold {
      filter          = <<-EOT
        resource.type = "cloudsql_database"
        AND metric.type = "cloudsql.googleapis.com/database/cpu/utilization"
      EOT
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = var.notification_channel_ids

  documentation {
    content   = <<-EOD
      ## High CPU on $${resource.label.database_id}

      ### Check
      1. Active queries: `SELECT pid, now()-query_start AS duration, query FROM pg_stat_activity WHERE state='active' ORDER BY duration DESC;`
      2. Autovacuum running? `SELECT * FROM pg_stat_progress_vacuum;`
      3. Consider scaling up vCPUs or optimizing queries
    EOD
    mime_type = "text/markdown"
  }
}
```

#### 2c. Memory Utilization > 85%

```hcl
resource "google_monitoring_alert_policy" "memory_high" {
  display_name = "CloudSQL PG - Memory > 85%"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Memory utilization high"
    condition_threshold {
      filter          = <<-EOT
        resource.type = "cloudsql_database"
        AND metric.type = "cloudsql.googleapis.com/database/memory/utilization"
      EOT
      comparison      = "COMPARISON_GT"
      threshold_value = 0.85
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = var.notification_channel_ids
}
```

#### 2d. Disk Utilization > 85%

```hcl
resource "google_monitoring_alert_policy" "disk_high" {
  display_name = "CloudSQL PG - Disk > 85%"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "Disk utilization high"
    condition_threshold {
      filter          = <<-EOT
        resource.type = "cloudsql_database"
        AND metric.type = "cloudsql.googleapis.com/database/disk/utilization"
      EOT
      comparison      = "COMPARISON_GT"
      threshold_value = 0.85
      duration        = "60s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = var.notification_channel_ids

  documentation {
    content   = "Disk above 85% on $${resource.label.database_id}. Enable automatic storage increase or provision more disk immediately. Running out of disk will crash the instance."
    mime_type = "text/markdown"
  }
}
```

#### 2e. Transaction ID Wraparound (Tiered)

```hcl
# WARNING — 500 million
resource "google_monitoring_alert_policy" "txid_warning" {
  display_name = "CloudSQL PG - TXID Age > 500M (WARNING)"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Transaction ID age exceeds 500M"
    condition_threshold {
      filter = <<-EOT
        resource.type = "cloudsql_database"
        AND metric.type = "cloudsql.googleapis.com/database/postgresql/vacuum/oldest_transaction_age"
      EOT
      comparison      = "COMPARISON_GT"
      threshold_value = 500000000
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = var.notification_channel_ids

  documentation {
    content   = <<-EOD
      ## TXID Age Warning on $${resource.label.database_id}

      Transaction ID age > 500M. Autovacuum may be falling behind.

      ### Actions
      1. Check for blocked autovacuum: `SELECT * FROM pg_stat_progress_vacuum;`
      2. Check for long-running transactions blocking vacuum:
         `SELECT pid, now()-xact_start AS age, query FROM pg_stat_activity WHERE xact_start IS NOT NULL ORDER BY xact_start LIMIT 10;`
      3. Find tables closest to wraparound:
         `SELECT relname, age(relfrozenxid) FROM pg_class WHERE relkind='r' ORDER BY age(relfrozenxid) DESC LIMIT 20;`
    EOD
    mime_type = "text/markdown"
  }
}

# CRITICAL — 1 billion
resource "google_monitoring_alert_policy" "txid_critical" {
  display_name = "CloudSQL PG - TXID Age > 1B (CRITICAL)"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "Transaction ID age exceeds 1B"
    condition_threshold {
      filter = <<-EOT
        resource.type = "cloudsql_database"
        AND metric.type = "cloudsql.googleapis.com/database/postgresql/vacuum/oldest_transaction_age"
      EOT
      comparison      = "COMPARISON_GT"
      threshold_value = 1000000000
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = var.notification_channel_ids

  documentation {
    content   = "**CRITICAL:** TXID age > 1B on $${resource.label.database_id}. Kill idle-in-transaction sessions. Run VACUUM FREEZE manually on oldest tables. PostgreSQL shuts down at ~2B."
    mime_type = "text/markdown"
  }
}

# EMERGENCY — 1.5 billion
resource "google_monitoring_alert_policy" "txid_emergency" {
  display_name = "CloudSQL PG - TXID Age > 1.5B (EMERGENCY)"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "Transaction ID age exceeds 1.5B - IMMINENT WRAPAROUND"
    condition_threshold {
      filter = <<-EOT
        resource.type = "cloudsql_database"
        AND metric.type = "cloudsql.googleapis.com/database/postgresql/vacuum/oldest_transaction_age"
      EOT
      comparison      = "COMPARISON_GT"
      threshold_value = 1500000000
      duration        = "0s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = var.notification_channel_ids

  documentation {
    content   = "**EMERGENCY:** TXID wraparound imminent on $${resource.label.database_id}. Database will force-shutdown at ~2B. ALL HANDS ON DECK."
    mime_type = "text/markdown"
  }
}
```

#### 2f. Replication Lag > 30s

```hcl
resource "google_monitoring_alert_policy" "replication_lag" {
  display_name = "CloudSQL PG - Replication Lag > 30s"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Replica lag exceeds 30 seconds"
    condition_threshold {
      filter          = <<-EOT
        resource.type = "cloudsql_database"
        AND metric.type = "cloudsql.googleapis.com/database/replication/replica_lag"
      EOT
      comparison      = "COMPARISON_GT"
      threshold_value = 30
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = var.notification_channel_ids
}
```

#### 2g. Connections Near Limit

```hcl
resource "google_monitoring_alert_policy" "connections_high" {
  display_name = "CloudSQL PG - Connections > 80% of max"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Active connections approaching limit"
    condition_threshold {
      filter          = <<-EOT
        resource.type = "cloudsql_database"
        AND metric.type = "cloudsql.googleapis.com/database/network/connections"
      EOT
      comparison      = "COMPARISON_GT"
      threshold_value = 400  # Adjust: 80% of your max_connections
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = var.notification_channel_ids
}
```

---

### 3. Log-Based Metrics & Alerts

These are also project-wide. They fire for any Cloud SQL instance that emits matching log entries. But the instance must have the right database flags enabled (Part B) for the log entries to appear.

#### 3a. Checkpoints Too Frequent

```hcl
resource "google_logging_metric" "checkpoint_too_frequent" {
  name    = "cloudsql/checkpoint_too_frequent"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloudsql_database"
    textPayload=~"checkpoints are occurring too frequently"
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "checkpoint_warning" {
  display_name = "CloudSQL PG - Checkpoints Too Frequent"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Frequent checkpoint warning in logs"
    condition_threshold {
      filter = <<-EOT
        resource.type = "cloudsql_database"
        AND metric.type = "logging.googleapis.com/user/cloudsql/checkpoint_too_frequent"
      EOT
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
      trigger { count = 1 }
    }
  }

  notification_channels = var.notification_channel_ids

  documentation {
    content   = <<-EOD
      ## Checkpoints Too Frequent on $${resource.label.database_id}

      This degrades I/O performance significantly.

      ### Actions
      1. Increase `max_wal_size` (try 4-20 GB based on write volume)
      2. Increase `checkpoint_timeout` (try 10-15 min)
      3. Check `pg_stat_bgwriter` for checkpoint_req vs checkpoint_timed ratio
    EOD
    mime_type = "text/markdown"
  }
}
```

#### 3b. Autovacuum Canceled

```hcl
resource "google_logging_metric" "autovacuum_canceled" {
  name    = "cloudsql/autovacuum_canceled"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloudsql_database"
    textPayload=~"canceling autovacuum task"
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "autovacuum_canceled" {
  display_name = "CloudSQL PG - Autovacuum Canceled"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Autovacuum tasks being canceled"
    condition_threshold {
      filter = <<-EOT
        resource.type = "cloudsql_database"
        AND metric.type = "logging.googleapis.com/user/cloudsql/autovacuum_canceled"
      EOT
      comparison      = "COMPARISON_GT"
      threshold_value = 2
      duration        = "0s"
      aggregations {
        alignment_period   = "3600s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = var.notification_channel_ids

  documentation {
    content   = <<-EOD
      Autovacuum canceled on $${resource.label.database_id} (likely lock conflicts).

      Dead tuples accumulating > bloat > degraded performance.

      ### Actions
      1. `SELECT relname, n_dead_tup, last_autovacuum FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 20;`
      2. Check for long-running transactions holding locks
      3. Run manual VACUUM during low-traffic window
    EOD
    mime_type = "text/markdown"
  }
}
```

#### 3c. Anti-Wraparound Vacuum Triggered

```hcl
resource "google_logging_metric" "wraparound_vacuum" {
  name    = "cloudsql/wraparound_vacuum"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloudsql_database"
    textPayload=~"to prevent wraparound"
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "wraparound_vacuum" {
  display_name = "CloudSQL PG - Anti-Wraparound Vacuum Running"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Emergency wraparound vacuum detected"
    condition_threshold {
      filter = <<-EOT
        resource.type = "cloudsql_database"
        AND metric.type = "logging.googleapis.com/user/cloudsql/wraparound_vacuum"
      EOT
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = var.notification_channel_ids
}
```

#### 3d. Deadlocks Detected

```hcl
resource "google_logging_metric" "deadlock" {
  name    = "cloudsql/deadlock_detected"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloudsql_database"
    textPayload=~"deadlock detected"
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "deadlock" {
  display_name = "CloudSQL PG - Deadlock Detected"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Deadlock detected in logs"
    condition_threshold {
      filter = <<-EOT
        resource.type = "cloudsql_database"
        AND metric.type = "logging.googleapis.com/user/cloudsql/deadlock_detected"
      EOT
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = var.notification_channel_ids
}
```

---

## Part B: Per-Instance Setup (Current Instance)

### 4. Enable Database Flags

This is the only per-instance step. Without these flags, log-based alerts won't fire because PostgreSQL won't emit the relevant log entries.

#### gcloud CLI (for your existing instance)

```bash
INSTANCE_NAME="your-current-instance"

gcloud sql instances patch $INSTANCE_NAME \
  --database-flags \
log_checkpoints=on,\
log_autovacuum_min_duration=60000,\
log_lock_waits=on,\
log_connections=on,\
log_disconnections=on,\
log_min_duration_statement=5000,\
log_temp_files=0,\
log_statement=ddl
```

> **Warning:** This command **replaces** all existing flags. If you already have flags set, include them in the command.

#### To preserve existing flags safely

```bash
# Step 1: Get current flags
gcloud sql instances describe $INSTANCE_NAME \
  --format="value(settings.databaseFlags)"

# Step 2: Merge with new flags in the patch command
```

#### Flag reference

| Flag | Value | Why |
|------|-------|-----|
| `log_checkpoints` | `on` | Enables checkpoint timing/buffer stats in logs -> feeds checkpoint alerts |
| `log_autovacuum_min_duration` | `60000` | Logs autovacuum runs > 60s -> feeds autovacuum alerts |
| `log_lock_waits` | `on` | Logs lock waits > `deadlock_timeout` -> visibility into contention |
| `log_connections` | `on` | Logs each new connection -> connection pattern visibility |
| `log_disconnections` | `on` | Logs disconnections with session duration |
| `log_min_duration_statement` | `5000` | Logs slow queries > 5 seconds |
| `log_temp_files` | `0` | Logs all temp file usage (disk spill indicator) |
| `log_statement` | `ddl` | Logs DDL statements (schema changes) |

> **Note:** Most logging flags take effect dynamically without restart.

---

## Part C: Automate for New Instances

### 5. Option 1 — Terraform Module (Recommended)

If all instances are managed through Terraform, bake the flags into a reusable module that every instance uses.

#### modules/cloudsql-pg/main.tf

```hcl
resource "google_sql_database_instance" "instance" {
  name                = var.instance_name
  database_version    = var.database_version
  region              = var.region
  deletion_protection = var.deletion_protection

  settings {
    tier              = var.tier
    availability_type = var.availability_type
    disk_autoresize   = true
    disk_type         = "PD_SSD"

    # ─── MONITORING FLAGS (always included) ────────────
    database_flags {
      name  = "log_checkpoints"
      value = "on"
    }
    database_flags {
      name  = "log_autovacuum_min_duration"
      value = "60000"
    }
    database_flags {
      name  = "log_lock_waits"
      value = "on"
    }
    database_flags {
      name  = "log_connections"
      value = "on"
    }
    database_flags {
      name  = "log_disconnections"
      value = "on"
    }
    database_flags {
      name  = "log_min_duration_statement"
      value = "5000"
    }
    database_flags {
      name  = "log_temp_files"
      value = "0"
    }
    database_flags {
      name  = "log_statement"
      value = "ddl"
    }

    # ─── ADDITIONAL FLAGS (passed by caller) ───────────
    dynamic "database_flags" {
      for_each = var.additional_database_flags
      content {
        name  = database_flags.value.name
        value = database_flags.value.value
      }
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "03:00"
    }

    maintenance_window {
      day          = 7  # Sunday
      hour         = 4
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      query_plans_per_minute  = 5
      query_string_length     = 4096
      record_application_tags = true
      record_client_address   = true
    }
  }
}
```

#### modules/cloudsql-pg/variables.tf

```hcl
variable "instance_name" { type = string }

variable "database_version" {
  type    = string
  default = "POSTGRES_16"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "tier" {
  type    = string
  default = "db-custom-2-7680"
}

variable "availability_type" {
  type    = string
  default = "REGIONAL"  # HA
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "additional_database_flags" {
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}
```

#### Usage — every new instance

```hcl
module "orders_db" {
  source        = "./modules/cloudsql-pg"
  instance_name = "orders-db-prod"
  tier          = "db-custom-4-15360"
  region        = "us-central1"

  additional_database_flags = [
    { name = "max_connections", value = "200" },
  ]
}

module "analytics_db" {
  source        = "./modules/cloudsql-pg"
  instance_name = "analytics-db-prod"
  tier          = "db-custom-8-30720"
  region        = "us-central1"
}
# monitoring flags are automatically included in both
```

**Why this is the best option:** Every instance is born with the right flags. No drift. No catch-up scripts. Alert policies (Part A) already cover them project-wide.

---

### 6. Option 2 — Eventarc + Cloud Function (Auto-Patch)

For instances created **outside of Terraform** (Console, gcloud, other teams), use an event-driven approach that automatically patches database flags on any new Cloud SQL instance.

#### Architecture

```
Cloud Audit Log                    Cloud Function
(cloudsql.instances.create) ──►    (patches database flags)
        |                                  |
    Eventarc Trigger               gcloud sql instances patch
```

#### Cloud Function: `auto_configure_cloudsql/main.py`

```python
import functions_framework
import subprocess
import json
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Standard monitoring flags for all PostgreSQL instances
MONITORING_FLAGS = {
    "log_checkpoints": "on",
    "log_autovacuum_min_duration": "60000",
    "log_lock_waits": "on",
    "log_connections": "on",
    "log_disconnections": "on",
    "log_min_duration_statement": "5000",
    "log_temp_files": "0",
    "log_statement": "ddl",
}


@functions_framework.cloud_event
def auto_configure_cloudsql(cloud_event):
    """Triggered by Cloud SQL instance creation via Eventarc."""
    payload = cloud_event.data
    proto_payload = payload.get("protoPayload", {})
    method_name = proto_payload.get("methodName", "")

    # Only act on instance creation
    if "cloudsql.instances.create" not in method_name:
        logger.info(f"Ignoring method: {method_name}")
        return

    # Extract instance details
    resource_name = proto_payload.get("resourceName", "")
    request = proto_payload.get("request", {})

    # Format: projects/PROJECT/instances/INSTANCE
    parts = resource_name.split("/")
    if len(parts) < 4:
        logger.error(f"Cannot parse resource name: {resource_name}")
        return

    project_id = parts[1]
    instance_name = parts[3]

    # Check if it is a PostgreSQL instance
    db_version = request.get("body", {}).get("databaseVersion", "")
    if not db_version.startswith("POSTGRES"):
        logger.info(f"Skipping non-PostgreSQL instance: {instance_name} ({db_version})")
        return

    logger.info(f"Configuring monitoring flags on new instance: {instance_name}")

    # Build flags string
    flags_str = ",".join(f"{k}={v}" for k, v in MONITORING_FLAGS.items())

    # Get existing flags first (to merge, not overwrite)
    try:
        result = subprocess.run(
            [
                "gcloud", "sql", "instances", "describe", instance_name,
                "--project", project_id,
                "--format=json(settings.databaseFlags)",
            ],
            capture_output=True, text=True, check=True, timeout=30,
        )
        existing = json.loads(result.stdout)
        existing_flags = existing.get("settings", {}).get("databaseFlags", [])

        # Merge: keep existing flags, add/override monitoring flags
        merged = {f["name"]: f["value"] for f in existing_flags}
        merged.update(MONITORING_FLAGS)
        flags_str = ",".join(f"{k}={v}" for k, v in merged.items())

    except Exception as e:
        logger.warning(f"Could not read existing flags: {e}. Using monitoring flags only.")

    # Patch the instance
    try:
        subprocess.run(
            [
                "gcloud", "sql", "instances", "patch", instance_name,
                "--project", project_id,
                f"--database-flags={flags_str}",
                "--quiet",
            ],
            capture_output=True, text=True, check=True, timeout=120,
        )
        logger.info(f"Successfully configured monitoring flags on {instance_name}")
    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to patch {instance_name}: {e.stderr}")
        raise
```

#### `requirements.txt`

```
functions-framework==3.*
```

#### Deploy

```bash
# Create service account
gcloud iam service-accounts create cloudsql-auto-config \
  --display-name="CloudSQL Auto-Config"

SA_EMAIL="cloudsql-auto-config@${PROJECT_ID}.iam.gserviceaccount.com"

# Grant permissions
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/cloudsql.editor"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/eventarc.eventReceiver"

# Deploy the Cloud Function
gcloud functions deploy auto-configure-cloudsql \
  --gen2 \
  --runtime=python312 \
  --region=us-central1 \
  --source=./auto_configure_cloudsql \
  --entry-point=auto_configure_cloudsql \
  --trigger-event-filters="type=google.cloud.audit.log.v1.written" \
  --trigger-event-filters="serviceName=sqladmin.googleapis.com" \
  --trigger-event-filters="methodName=cloudsql.instances.create" \
  --service-account=$SA_EMAIL \
  --timeout=180
```

---

### 7. Option 3 — Terraform for_each with Centralized Config

If you manage multiple instances from a single Terraform config:

```hcl
locals {
  instances = {
    "orders-prod" = {
      tier   = "db-custom-4-15360"
      region = "us-central1"
      ha     = true
    }
    "analytics-prod" = {
      tier   = "db-custom-8-30720"
      region = "us-central1"
      ha     = true
    }
    "staging" = {
      tier   = "db-custom-2-7680"
      region = "us-central1"
      ha     = false
    }
  }

  # Applied to ALL instances — single source of truth
  monitoring_flags = [
    { name = "log_checkpoints",            value = "on"    },
    { name = "log_autovacuum_min_duration", value = "60000" },
    { name = "log_lock_waits",             value = "on"    },
    { name = "log_connections",            value = "on"    },
    { name = "log_disconnections",         value = "on"    },
    { name = "log_min_duration_statement", value = "5000"  },
    { name = "log_temp_files",             value = "0"     },
    { name = "log_statement",              value = "ddl"   },
  ]
}

resource "google_sql_database_instance" "pg" {
  for_each = local.instances

  name                = each.key
  database_version    = "POSTGRES_16"
  region              = each.value.region
  deletion_protection = true

  settings {
    tier              = each.value.tier
    availability_type = each.value.ha ? "REGIONAL" : "ZONAL"
    disk_autoresize   = true

    dynamic "database_flags" {
      for_each = local.monitoring_flags
      content {
        name  = database_flags.value.name
        value = database_flags.value.value
      }
    }
  }
}
```

Adding a new instance = adding one entry to `local.instances`. Flags are always included.

---

## Diagnostic Queries

Run these when alerts fire:

```sql
-- === AUTOVACUUM PROGRESS ===
SELECT relid::regclass AS table_name, pid, phase,
       heap_blks_total, heap_blks_scanned, heap_blks_vacuumed,
       index_vacuum_count, max_dead_tuples, num_dead_tuples
FROM pg_stat_progress_vacuum;

-- === TABLES CLOSEST TO TXID WRAPAROUND ===
SELECT schemaname, relname,
       age(relfrozenxid) AS xid_age,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
       n_dead_tup, last_autovacuum, last_vacuum
FROM pg_stat_user_tables s
JOIN pg_class c ON c.relname = s.relname
WHERE c.relkind = 'r'
ORDER BY age(relfrozenxid) DESC
LIMIT 20;

-- === LONG-RUNNING TRANSACTIONS (BLOCKING VACUUM) ===
SELECT pid, now() - xact_start AS duration,
       state, wait_event_type, wait_event, query
FROM pg_stat_activity
WHERE state != 'idle' AND xact_start IS NOT NULL
ORDER BY xact_start
LIMIT 20;

-- === CHECKPOINT STATS ===
SELECT checkpoints_timed, checkpoints_req,
       checkpoint_write_time, checkpoint_sync_time,
       buffers_checkpoint, buffers_backend,
       ROUND(100.0 * checkpoints_req /
         NULLIF(checkpoints_timed + checkpoints_req, 0), 1) AS pct_requested
FROM pg_stat_bgwriter;

-- === DEAD TUPLE ACCUMULATION ===
SELECT schemaname, relname, n_live_tup, n_dead_tup,
       ROUND(n_dead_tup::numeric / NULLIF(n_live_tup, 0) * 100, 2) AS dead_pct,
       last_autovacuum, autovacuum_count
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC LIMIT 20;

-- === ACTIVE VACUUM PROCESSES ===
SELECT pid, datname, usename, query, state,
       now() - query_start AS duration
FROM pg_stat_activity
WHERE query ILIKE '%vacuum%'
ORDER BY query_start;
```

---

## Quick Reference Table

| Alert | Type | Scope | Threshold | Severity |
|-------|------|-------|-----------|----------|
| Instance down | Metric | Auto (all instances) | != RUNNING for 5 min | CRITICAL |
| CPU > 80% | Metric | Auto (all instances) | > 0.8 for 5 min | WARNING |
| Memory > 85% | Metric | Auto (all instances) | > 0.85 for 5 min | WARNING |
| Disk > 85% | Metric | Auto (all instances) | > 0.85 for 1 min | CRITICAL |
| TXID age warn | Metric | Auto (all instances) | > 500M | WARNING |
| TXID age critical | Metric | Auto (all instances) | > 1B | CRITICAL |
| TXID age emergency | Metric | Auto (all instances) | > 1.5B | CRITICAL |
| Replication lag | Metric | Auto (all instances) | > 30s for 5 min | WARNING |
| Connections high | Metric | Auto (all instances) | > 80% of max | WARNING |
| Checkpoints frequent | Log-based | Auto *(needs flags)* | count > 0 | WARNING |
| Autovacuum canceled | Log-based | Auto *(needs flags)* | > 2/hour | WARNING |
| Wraparound vacuum | Log-based | Auto *(needs flags)* | count > 0 | WARNING |
| Deadlocks | Log-based | Auto *(needs flags)* | count > 0 | WARNING |

**"Auto (all instances)"** = project-wide alert, no per-instance config needed.
**"Auto *(needs flags)*"** = project-wide alert, but instance must have database flags enabled.

---

## Checklist

- [ ] Create notification channels (email, Slack, PagerDuty)
- [ ] Deploy project-wide metric-based alert policies (Section 2)
- [ ] Create log-based metrics and alert policies (Section 3)
- [ ] Enable database flags on current instance (Section 4)
- [ ] Choose automation strategy for new instances (Section 5/6/7)
  - [ ] **Terraform module** — if all infra is in Terraform
  - [ ] **Eventarc + Cloud Function** — if instances are created ad-hoc
  - [ ] **Both** — for defense-in-depth
- [ ] Test: create a test instance and verify alerts fire
- [ ] Document runbooks for each alert type

---

## References

- [Cloud SQL Metrics Reference](https://cloud.google.com/sql/docs/postgres/admin-api/metrics)
- [Monitor Cloud SQL Instances](https://cloud.google.com/sql/docs/postgres/monitor-instance)
- [Cloud SQL Observability](https://cloud.google.com/sql/docs/postgres/observability)
- [Optimize VACUUM Operations](https://cloud.google.com/solutions/optimizing-monitoring-troubleshooting-vacuum-operations-postgresql)
- [Custom Log-Based Metrics for PostgreSQL](https://cloud.google.com/blog/products/databases/creating-custom-log-based-metrics-for-postgresql-and-alloydb/)
- [Create Alerting Policies with Terraform](https://cloud.google.com/monitoring/alerts/terraform)
- [Terraform google_monitoring_alert_policy](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/monitoring_alert_policy)
- [Cloud SQL Database Flags](https://cloud.google.com/sql/docs/postgres/flags)
- [Eventarc Triggers for Cloud Functions](https://docs.cloud.google.com/eventarc/standard/docs/functions/create-triggers)
