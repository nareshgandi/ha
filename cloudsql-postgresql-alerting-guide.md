# Cloud SQL for PostgreSQL — Alerting & Automation Guide

A production-ready reference for setting up monitoring alerts on Google Cloud SQL for PostgreSQL covering instance availability, checkpoint activity, autovacuum health, and supporting infrastructure metrics.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Architecture Overview](#architecture-overview)
- [1. Instance Down / State Monitoring](#1-instance-down--state-monitoring)
- [2. Checkpoint Monitoring](#2-checkpoint-monitoring)
- [3. Autovacuum Activity Monitoring](#3-autovacuum-activity-monitoring)
- [4. Supporting Infrastructure Alerts](#4-supporting-infrastructure-alerts)
- [5. Notification Channels Setup](#5-notification-channels-setup)
- [6. Complete Terraform Module](#6-complete-terraform-module)
- [7. gcloud CLI Quick Setup](#7-gcloud-cli-quick-setup)
- [8. Database Flags to Enable](#8-database-flags-to-enable)
- [9. Useful Diagnostic Queries](#9-useful-diagnostic-queries)
- [10. Log-Based Metric Filters Reference](#10-log-based-metric-filters-reference)
- [Quick Reference Table](#quick-reference-table)

---

## Prerequisites

- Google Cloud project with Cloud SQL for PostgreSQL instance(s)
- Cloud Monitoring API enabled
- Cloud Logging API enabled
- IAM role: `roles/monitoring.editor` (for creating alert policies)
- IAM role: `roles/logging.admin` (for creating log-based metrics)
- Terraform >= 1.3 (if using IaC approach)
- `gcloud` CLI authenticated and configured

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                   Cloud SQL Instance                        │
│                                                             │
│  postgres.log ──► Cloud Logging ──► Log-Based Metrics       │
│                                          │                  │
│  Built-in Metrics ──► Cloud Monitoring ◄─┘                  │
│                            │                                │
│                     Alert Policies                          │
│                       │    │    │                            │
│                   Email  Slack PagerDuty                     │
└─────────────────────────────────────────────────────────────┘
```

Two types of alerts are used:

- **Metric-based alerts**: Use built-in `cloudsql.googleapis.com/*` metrics (instance state, CPU, memory, disk, replication lag, transaction age).
- **Log-based alerts**: Parse `postgres.log` entries via Cloud Logging for PostgreSQL-specific events (checkpoint warnings, autovacuum activity, lock timeouts, errors).

---

## 1. Instance Down / State Monitoring

### Metric

```
cloudsql.googleapis.com/database/instance_state
```

This metric reports the instance state as a numeric value. `RUNNING = 0`, `FAILED`, `PENDING_CREATE`, `SUSPENDED`, etc. are non-zero.

### Console Setup

1. Go to **Cloud Monitoring → Alerting → Create Policy**
2. Click **Add Condition**
3. Select metric: **Cloud SQL Database → Instance State**
4. Configure:
   - **Filter**: `resource.type = "cloudsql_database"`
   - **Condition type**: Metric absence OR threshold
   - **Condition**: Alert when value ≠ RUNNING for 5 minutes
5. Add notification channels
6. Name the policy: `Cloud SQL Instance Not Running`

### Terraform

```hcl
resource "google_monitoring_alert_policy" "cloudsql_instance_down" {
  display_name = "Cloud SQL - Instance Not Running"
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

      trigger {
        count = 1
      }
    }
  }

  notification_channels = var.notification_channel_ids

  documentation {
    content   = "Cloud SQL instance is not in RUNNING state. Check the instance status in the Cloud Console and review operations logs."
    mime_type = "text/markdown"
  }

  alert_strategy {
    auto_close = "1800s"
  }
}
```

### Uptime Check (External Connectivity)

For instances exposed via Private Service Connect or authorized networks, add an uptime check:

```hcl
resource "google_monitoring_uptime_check_config" "cloudsql_tcp" {
  display_name = "Cloud SQL TCP Check"
  timeout      = "10s"
  period       = "60s"

  tcp_check {
    port = 5432
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.cloudsql_private_ip
    }
  }
}
```

---

## 2. Checkpoint Monitoring

Cloud SQL does **not** expose a built-in checkpoint count metric. You must use **log-based alerting**.

### Step 1 — Enable Database Flags

```bash
gcloud sql instances patch INSTANCE_NAME \
  --database-flags log_checkpoints=on
```

This makes PostgreSQL log every checkpoint with timing, buffer stats, and WAL details.

### Step 2 — Create Log-Based Metrics

**Metric 1: Checkpoints occurring too frequently (WARNING)**

Go to **Logs Explorer** → Enter this filter:

```
resource.type="cloudsql_database"
resource.labels.database_id="PROJECT_ID:INSTANCE_NAME"
textPayload=~"checkpoints are occurring too frequently"
```

Click **Create Metric**:

| Field       | Value                                |
|-------------|--------------------------------------|
| Name        | `cloudsql/checkpoint_too_frequent`   |
| Type        | Counter                              |
| Filter      | (as above)                           |
| Labels      | `database_id` from resource labels   |

**Metric 2: General checkpoint completion tracking**

```
resource.type="cloudsql_database"
textPayload=~"checkpoint complete"
```

Create as counter metric: `cloudsql/checkpoint_complete`

### Step 3 — Create Alert Policy

#### Console

1. **Monitoring → Alerting → Create Policy**
2. Select metric: `logging/user/cloudsql/checkpoint_too_frequent`
3. Condition: **Any time series violates** → Threshold > 0 in a 5-minute window
4. Notification: Email + Slack

#### Terraform

```hcl
# Log-based metric
resource "google_logging_metric" "checkpoint_too_frequent" {
  name   = "cloudsql/checkpoint_too_frequent"
  filter = <<-EOT
    resource.type="cloudsql_database"
    textPayload=~"checkpoints are occurring too frequently"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# Alert on the log-based metric
resource "google_monitoring_alert_policy" "checkpoint_warning" {
  display_name = "Cloud SQL - Checkpoints Too Frequent"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Frequent checkpoint warning detected"
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

      trigger {
        count = 1
      }
    }
  }

  notification_channels = var.notification_channel_ids

  documentation {
    content   = <<-EOD
      **Checkpoints are occurring too frequently.**

      This degrades I/O performance. Actions:
      1. Increase `max_wal_size` (default 1.5GB for Enterprise, 5GB for Enterprise Plus)
      2. Increase `checkpoint_timeout` (default 5 min)
      3. Review write-heavy workloads
      4. Query `pg_stat_bgwriter` for checkpoint stats
    EOD
    mime_type = "text/markdown"
  }
}
```

### Checkpoint Tuning Reference

| Flag                 | Default (Enterprise) | Default (Enterprise Plus) | Recommendation         |
|----------------------|----------------------|---------------------------|------------------------|
| `max_wal_size`       | 1.5 GB               | 5 GB                      | 4–20 GB based on load  |
| `checkpoint_timeout` | 5 min                | 5 min                     | 10–15 min              |
| `checkpoint_completion_target` | 0.9       | 0.9                       | 0.9 (keep default)     |

---

## 3. Autovacuum Activity Monitoring

### 3.1 Transaction ID Wraparound Prevention (CRITICAL)

This is the most important autovacuum-related alert. If transaction ID age reaches ~2 billion, PostgreSQL shuts down to prevent data corruption.

**Metric:**

```
cloudsql.googleapis.com/database/postgresql/vacuum/oldest_transaction_age
```

**Terraform — Tiered Alerts:**

```hcl
# WARNING at 500 million
resource "google_monitoring_alert_policy" "txid_age_warning" {
  display_name = "Cloud SQL - TXID Age Warning (500M)"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Transaction ID age > 500M"
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
      Transaction ID age has exceeded 500 million. Autovacuum may be struggling.

      **Immediate actions:**
      1. Check for long-running transactions: `SELECT * FROM pg_stat_activity WHERE state != 'idle' ORDER BY xact_start;`
      2. Check autovacuum progress: `SELECT * FROM pg_stat_progress_vacuum;`
      3. Look for tables approaching wraparound: `SELECT relname, age(relfrozenxid) FROM pg_class WHERE relkind = 'r' ORDER BY age(relfrozenxid) DESC LIMIT 20;`
    EOD
    mime_type = "text/markdown"
  }
}

# CRITICAL at 1 billion
resource "google_monitoring_alert_policy" "txid_age_critical" {
  display_name = "Cloud SQL - TXID Age CRITICAL (1B)"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "Transaction ID age > 1B"
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
    content   = <<-EOD
      **CRITICAL: Transaction ID age has exceeded 1 BILLION.**

      PostgreSQL will force-shutdown at ~2 billion to prevent data corruption.

      **Immediate actions:**
      1. Kill any long-running idle-in-transaction sessions
      2. Manually run VACUUM FREEZE on the oldest tables
      3. Consider increasing `autovacuum_max_workers`
      4. Increase `maintenance_work_mem` and `autovacuum_work_mem`
    EOD
    mime_type = "text/markdown"
  }
}

# EMERGENCY at 1.5 billion
resource "google_monitoring_alert_policy" "txid_age_emergency" {
  display_name = "Cloud SQL - TXID Age EMERGENCY (1.5B)"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "Transaction ID age > 1.5B"
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
    content   = "**EMERGENCY: TXID wraparound imminent. Database will shut down at ~2B. All hands on deck.**"
    mime_type = "text/markdown"
  }
}
```

### 3.2 Long-Running Autovacuum (Log-Based)

**Step 1 — Enable the flag:**

```bash
# Log autovacuum runs that take longer than 60 seconds
gcloud sql instances patch INSTANCE_NAME \
  --database-flags log_autovacuum_min_duration=60000

# To log ALL autovacuum runs (verbose, use in non-prod):
# --database-flags log_autovacuum_min_duration=0
```

**Step 2 — Create log-based metric:**

```
resource.type="cloudsql_database"
textPayload=~"automatic vacuum of table"
```

Create as counter metric: `cloudsql/autovacuum_completed`

**Terraform:**

```hcl
resource "google_logging_metric" "autovacuum_long_running" {
  name   = "cloudsql/autovacuum_completed"
  filter = <<-EOT
    resource.type="cloudsql_database"
    textPayload=~"automatic vacuum of table"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}
```

### 3.3 Autovacuum Canceled (IMPORTANT)

When autovacuum is canceled due to lock conflicts, it means dead tuples are accumulating and bloat is growing.

```
resource.type="cloudsql_database"
textPayload=~"canceling autovacuum task"
```

**Terraform:**

```hcl
resource "google_logging_metric" "autovacuum_canceled" {
  name   = "cloudsql/autovacuum_canceled"
  filter = <<-EOT
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
  display_name = "Cloud SQL - Autovacuum Canceled"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Autovacuum task was canceled"
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
      Autovacuum tasks are being canceled (likely due to lock conflicts).

      **Impact:** Dead tuples accumulate → table/index bloat → degraded performance.

      **Actions:**
      1. Identify tables with high dead tuple counts: `SELECT relname, n_dead_tup, last_autovacuum FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 20;`
      2. Check for long-running transactions holding locks
      3. Consider running manual VACUUM during low-traffic window
    EOD
    mime_type = "text/markdown"
  }
}
```

### 3.4 Autovacuum Anti-Wraparound Running

This fires when PostgreSQL forces an aggressive anti-wraparound vacuum, which can cause significant performance impact.

```
resource.type="cloudsql_database"
textPayload=~"to prevent wraparound"
```

---

## 4. Supporting Infrastructure Alerts

### CPU Utilization

```hcl
resource "google_monitoring_alert_policy" "cloudsql_cpu" {
  display_name = "Cloud SQL - CPU > 80%"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "CPU utilization high"
    condition_threshold {
      filter          = "resource.type=\"cloudsql_database\" AND metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\""
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
}
```

### Memory Utilization

```hcl
resource "google_monitoring_alert_policy" "cloudsql_memory" {
  display_name = "Cloud SQL - Memory > 85%"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Memory utilization high"
    condition_threshold {
      filter          = "resource.type=\"cloudsql_database\" AND metric.type=\"cloudsql.googleapis.com/database/memory/utilization\""
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

### Disk Utilization

```hcl
resource "google_monitoring_alert_policy" "cloudsql_disk" {
  display_name = "Cloud SQL - Disk > 85%"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "Disk utilization high"
    condition_threshold {
      filter          = "resource.type=\"cloudsql_database\" AND metric.type=\"cloudsql.googleapis.com/database/disk/utilization\""
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
    content   = "Disk usage is above 85%. Enable automatic storage increase or provision more disk. Running out of disk will cause the instance to crash."
    mime_type = "text/markdown"
  }
}
```

### Replication Lag (If Replicas Exist)

```hcl
resource "google_monitoring_alert_policy" "cloudsql_replication_lag" {
  display_name = "Cloud SQL - Replication Lag > 30s"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Replica lag exceeds 30 seconds"
    condition_threshold {
      filter          = "resource.type=\"cloudsql_database\" AND metric.type=\"cloudsql.googleapis.com/database/replication/replica_lag\""
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

### Connections Near Limit

```hcl
resource "google_monitoring_alert_policy" "cloudsql_connections" {
  display_name = "Cloud SQL - Connections > 80% of max"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Active connections high"
    condition_threshold {
      filter          = "resource.type=\"cloudsql_database\" AND metric.type=\"cloudsql.googleapis.com/database/network/connections\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.max_connections * 0.8
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

## 5. Notification Channels Setup

### Terraform

```hcl
# Email
resource "google_monitoring_notification_channel" "email" {
  display_name = "DBA Team Email"
  type         = "email"
  labels = {
    email_address = "dba-alerts@yourcompany.com"
  }
}

# Slack
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

# PagerDuty
resource "google_monitoring_notification_channel" "pagerduty" {
  display_name = "DBA PagerDuty"
  type         = "pagerduty"
  labels = {
    service_key = var.pagerduty_service_key
  }
}

# SMS (via Pub/Sub + Cloud Functions if needed)
# Or use the built-in SMS channel type
resource "google_monitoring_notification_channel" "sms" {
  display_name = "DBA On-Call SMS"
  type         = "sms"
  labels = {
    number = var.oncall_phone_number
  }
}
```

### gcloud CLI

```bash
# Email
gcloud beta monitoring channels create \
  --display-name="DBA Email" \
  --type=email \
  --channel-labels=email_address=dba@yourcompany.com

# List existing channels (to get IDs for alert policies)
gcloud beta monitoring channels list --format="table(name, displayName, type)"
```

---

## 6. Complete Terraform Module

### variables.tf

```hcl
variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "notification_channel_ids" {
  description = "List of notification channel IDs"
  type        = list(string)
}

variable "max_connections" {
  description = "max_connections setting of the instance"
  type        = number
  default     = 100
}

variable "instance_name" {
  description = "Cloud SQL instance name"
  type        = string
}
```

### main.tf

```hcl
terraform {
  required_version = ">= 1.3"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

# ─── LOG-BASED METRICS ──────────────────────────────────────

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

resource "google_logging_metric" "autovacuum_completed" {
  name    = "cloudsql/autovacuum_completed"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloudsql_database"
    textPayload=~"automatic vacuum of table"
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

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

# ─── METRIC-BASED ALERT POLICIES ────────────────────────────

# (Include all alert resources from sections 1–4 above here)
# Refer to individual sections for full resource definitions.
```

### Apply

```bash
terraform init
terraform plan -var="project_id=my-project" -var="instance_name=my-instance"
terraform apply
```

---

## 7. gcloud CLI Quick Setup

For teams that prefer imperative setup over Terraform:

```bash
PROJECT_ID="your-project-id"
INSTANCE_NAME="your-instance-name"

# ─── Step 1: Enable required database flags ───────────────
gcloud sql instances patch $INSTANCE_NAME \
  --database-flags \
    log_checkpoints=on,\
    log_autovacuum_min_duration=60000,\
    log_lock_waits=on,\
    log_min_duration_statement=5000,\
    log_connections=on,\
    log_disconnections=on

# ─── Step 2: Create notification channel ──────────────────
CHANNEL_ID=$(gcloud beta monitoring channels create \
  --display-name="DBA Email" \
  --type=email \
  --channel-labels=email_address=dba@yourcompany.com \
  --format="value(name)")

echo "Notification channel: $CHANNEL_ID"

# ─── Step 3: Create alert policies ───────────────────────

# 3a. Instance down
gcloud beta monitoring policies create \
  --display-name="Cloud SQL - Instance Not Running" \
  --condition-display-name="Instance state not running" \
  --condition-filter="resource.type=\"cloudsql_database\" AND metric.type=\"cloudsql.googleapis.com/database/instance_state\"" \
  --condition-threshold-comparison="COMPARISON_NE" \
  --condition-threshold-value=0 \
  --condition-threshold-duration="300s" \
  --condition-threshold-aggregations-aligner="ALIGN_MEAN" \
  --condition-threshold-aggregations-alignment-period="60s" \
  --notification-channels="$CHANNEL_ID" \
  --combiner="OR"

# 3b. CPU > 80%
gcloud beta monitoring policies create \
  --display-name="Cloud SQL - CPU > 80%" \
  --condition-display-name="High CPU" \
  --condition-filter="resource.type=\"cloudsql_database\" AND metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\"" \
  --condition-threshold-comparison="COMPARISON_GT" \
  --condition-threshold-value=0.8 \
  --condition-threshold-duration="300s" \
  --condition-threshold-aggregations-aligner="ALIGN_MEAN" \
  --condition-threshold-aggregations-alignment-period="60s" \
  --notification-channels="$CHANNEL_ID" \
  --combiner="OR"

# 3c. Disk > 85%
gcloud beta monitoring policies create \
  --display-name="Cloud SQL - Disk > 85%" \
  --condition-display-name="High Disk" \
  --condition-filter="resource.type=\"cloudsql_database\" AND metric.type=\"cloudsql.googleapis.com/database/disk/utilization\"" \
  --condition-threshold-comparison="COMPARISON_GT" \
  --condition-threshold-value=0.85 \
  --condition-threshold-duration="60s" \
  --condition-threshold-aggregations-aligner="ALIGN_MEAN" \
  --condition-threshold-aggregations-alignment-period="60s" \
  --notification-channels="$CHANNEL_ID" \
  --combiner="OR"

# 3d. TXID age > 500M
gcloud beta monitoring policies create \
  --display-name="Cloud SQL - TXID Age > 500M" \
  --condition-display-name="TXID age warning" \
  --condition-filter="resource.type=\"cloudsql_database\" AND metric.type=\"cloudsql.googleapis.com/database/postgresql/vacuum/oldest_transaction_age\"" \
  --condition-threshold-comparison="COMPARISON_GT" \
  --condition-threshold-value=500000000 \
  --condition-threshold-duration="300s" \
  --condition-threshold-aggregations-aligner="ALIGN_MAX" \
  --condition-threshold-aggregations-alignment-period="300s" \
  --notification-channels="$CHANNEL_ID" \
  --combiner="OR"
```

---

## 8. Database Flags to Enable

Set these flags on your Cloud SQL instance for comprehensive monitoring:

```bash
gcloud sql instances patch INSTANCE_NAME --database-flags \
  log_checkpoints=on,\
  log_autovacuum_min_duration=60000,\
  log_lock_waits=on,\
  log_min_duration_statement=5000,\
  log_connections=on,\
  log_disconnections=on,\
  log_temp_files=0,\
  log_statement=ddl
```

| Flag                            | Value     | Purpose                                       |
|---------------------------------|-----------|-----------------------------------------------|
| `log_checkpoints`               | `on`      | Log checkpoint timing and buffer stats         |
| `log_autovacuum_min_duration`   | `60000`   | Log autovacuum runs > 60 seconds               |
| `log_lock_waits`                | `on`      | Log lock waits exceeding `deadlock_timeout`    |
| `log_min_duration_statement`    | `5000`    | Log queries taking > 5 seconds                 |
| `log_connections`               | `on`      | Log each new connection                        |
| `log_disconnections`            | `on`      | Log session end with duration                  |
| `log_temp_files`                | `0`       | Log all temp file usage (disk spills)          |
| `log_statement`                 | `ddl`     | Log all DDL statements                         |

> **Note:** Restart is NOT required for most logging flags. They take effect dynamically.

---

## 9. Useful Diagnostic Queries

Run these on the Cloud SQL instance when alerts fire:

### Check Active Autovacuum Progress

```sql
SELECT relid::regclass AS table_name,
       pid,
       phase,
       heap_blks_total,
       heap_blks_scanned,
       heap_blks_vacuumed,
       index_vacuum_count,
       max_dead_tuples,
       num_dead_tuples
FROM pg_stat_progress_vacuum;
```

### Tables Closest to TXID Wraparound

```sql
SELECT schemaname,
       relname,
       age(relfrozenxid) AS xid_age,
       pg_size_pretty(pg_total_relation_size(oid)) AS total_size,
       n_dead_tup,
       last_autovacuum,
       last_vacuum
FROM pg_stat_user_tables
JOIN pg_class USING (relname)
WHERE relkind = 'r'
ORDER BY age(relfrozenxid) DESC
LIMIT 20;
```

### Check for Long-Running Transactions (Blocking Vacuum)

```sql
SELECT pid,
       now() - xact_start AS duration,
       state,
       query
FROM pg_stat_activity
WHERE state != 'idle'
  AND xact_start IS NOT NULL
ORDER BY xact_start
LIMIT 20;
```

### Checkpoint Stats

```sql
SELECT checkpoints_timed,
       checkpoints_req,
       checkpoint_write_time,
       checkpoint_sync_time,
       buffers_checkpoint,
       buffers_backend
FROM pg_stat_bgwriter;
```

### Dead Tuple Accumulation (Bloat Indicator)

```sql
SELECT schemaname,
       relname,
       n_live_tup,
       n_dead_tup,
       ROUND(n_dead_tup::numeric / NULLIF(n_live_tup, 0) * 100, 2) AS dead_pct,
       last_autovacuum,
       autovacuum_count
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC
LIMIT 20;
```

### Active Vacuum Processes

```sql
SELECT pid, datname, usename, query, state, now() - query_start AS duration
FROM pg_stat_activity
WHERE query ILIKE '%vacuum%'
ORDER BY query_start;
```

---

## 10. Log-Based Metric Filters Reference

All filters use `resource.type="cloudsql_database"`. Add `resource.labels.database_id="PROJECT:INSTANCE"` to scope to a specific instance.

| Metric Name                        | Log Filter                                                    | Type    | Alert When          |
|------------------------------------|---------------------------------------------------------------|---------|---------------------|
| `cloudsql/checkpoint_too_frequent` | `textPayload=~"checkpoints are occurring too frequently"`     | Counter | count > 0           |
| `cloudsql/checkpoint_complete`     | `textPayload=~"checkpoint complete"`                          | Counter | rate monitoring      |
| `cloudsql/autovacuum_completed`    | `textPayload=~"automatic vacuum of table"`                    | Counter | tracking             |
| `cloudsql/autovacuum_canceled`     | `textPayload=~"canceling autovacuum task"`                    | Counter | count > 2/hour       |
| `cloudsql/wraparound_vacuum`      | `textPayload=~"to prevent wraparound"`                        | Counter | count > 0           |
| `cloudsql/lock_timeout`           | `textPayload=~"lock timeout"`                                 | Counter | count > 5/hour       |
| `cloudsql/deadlock_detected`      | `textPayload=~"deadlock detected"`                            | Counter | count > 0           |
| `cloudsql/temp_file_usage`        | `textPayload=~"temporary file"`                               | Counter | rate monitoring       |
| `cloudsql/connection_error`       | `textPayload=~"too many connections" OR textPayload=~"FATAL"` | Counter | count > 0           |

---

## Quick Reference Table

| Alert                     | Source             | Metric / Filter                                             | Threshold                | Severity |
|---------------------------|--------------------|-------------------------------------------------------------|--------------------------|----------|
| Instance down             | Built-in metric    | `database/instance_state`                                   | ≠ RUNNING for 5 min      | CRITICAL |
| CPU saturation            | Built-in metric    | `database/cpu/utilization`                                   | > 80% for 5 min          | WARNING  |
| Memory pressure           | Built-in metric    | `database/memory/utilization`                                | > 85% for 5 min          | WARNING  |
| Disk full                 | Built-in metric    | `database/disk/utilization`                                  | > 85%                    | CRITICAL |
| TXID wraparound (warn)    | Built-in metric    | `postgresql/vacuum/oldest_transaction_age`                   | > 500M                   | WARNING  |
| TXID wraparound (crit)    | Built-in metric    | `postgresql/vacuum/oldest_transaction_age`                   | > 1B                     | CRITICAL |
| TXID wraparound (emerg)   | Built-in metric    | `postgresql/vacuum/oldest_transaction_age`                   | > 1.5B                   | CRITICAL |
| Replication lag           | Built-in metric    | `database/replication/replica_lag`                            | > 30s                    | WARNING  |
| Connections near limit    | Built-in metric    | `database/network/connections`                               | > 80% of max             | WARNING  |
| Frequent checkpoints      | Log-based metric   | `"checkpoints are occurring too frequently"`                 | count > 0                | WARNING  |
| Long autovacuum           | Log-based metric   | `"automatic vacuum of table"`                                | duration-based           | INFO     |
| Autovacuum canceled       | Log-based metric   | `"canceling autovacuum task"`                                | count > 2/hour           | WARNING  |
| Anti-wraparound vacuum    | Log-based metric   | `"to prevent wraparound"`                                   | count > 0                | WARNING  |
| Deadlocks                 | Log-based metric   | `"deadlock detected"`                                       | count > 0                | WARNING  |

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
