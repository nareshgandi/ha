# SOP: Checkpoint Monitoring on Cloud SQL for PostgreSQL

Track "checkpoints are occurring too frequently" in Log Explorer, create an alert, and automate it for every new instance.

---

## What Is the Problem

When PostgreSQL writes more WAL than `max_wal_size` allows between checkpoints, it forces early checkpoints. Each checkpoint flushes all dirty buffers to disk — doing this too often causes I/O spikes, increased latency, and full-page writes after every checkpoint.

PostgreSQL logs this as:

```
LOG: checkpoints are occurring too frequently (17 seconds apart)
HINT: Consider increasing the configuration parameter "max_wal_size".
```

This SOP sets up detection and alerting for this in Cloud SQL using only GCP-native tools.

---

## Steps Overview

```
Step 1: Enable log_checkpoints flag on the instance
Step 2: Verify logs appear in Log Explorer
Step 3: Create a log-based metric from the filter
Step 4: Create an alert policy on that metric
Step 5: Automate for new instances
```

---

## Step 1: Enable the Database Flag

The flag `log_checkpoints` must be ON for PostgreSQL to log checkpoint details. It is OFF by default in Cloud SQL.

### Console

1. Go to **Cloud SQL** → click your instance
2. Click **Edit**
3. Scroll to **Flags and parameters**
4. Click **Add a database flag**
5. Search for `log_checkpoints` → set to `on`
6. Click **Save**
7. Instance restarts (takes ~1–2 minutes)

### gcloud CLI

```bash
# Replace with your instance name
INSTANCE="my-pg-instance"

# If instance has NO existing flags:
gcloud sql instances patch $INSTANCE \
  --database-flags=log_checkpoints=on

# If instance HAS existing flags, include them all:
# (this command REPLACES all flags — omitted flags get reset)
gcloud sql instances patch $INSTANCE \
  --database-flags=log_checkpoints=on,log_lock_waits=on,log_autovacuum_min_duration=60000
```

### Verify flag is set

```bash
gcloud sql instances describe $INSTANCE \
  --format="table(settings.databaseFlags)"
```

Expected output:

```
NAME              VALUE
log_checkpoints   on
```

---

## Step 2: Verify Logs in Log Explorer

### Open Log Explorer

1. Go to **Google Cloud Console** → **Logging** → **Logs Explorer**
   Direct URL: `https://console.cloud.google.com/logs/query`

### Enter this query

```
resource.type="cloudsql_database"
resource.labels.database_id="YOUR_PROJECT_ID:YOUR_INSTANCE_NAME"
textPayload=~"checkpoint"
```

Replace `YOUR_PROJECT_ID:YOUR_INSTANCE_NAME` with your actual values. Example:

```
resource.type="cloudsql_database"
resource.labels.database_id="myproject-123:my-pg-instance"
textPayload=~"checkpoint"
```

3. Click **Run query**

### What you should see

After enabling `log_checkpoints=on`, every checkpoint produces two log lines:

```
LOG: checkpoint starting: time
LOG: checkpoint complete: wrote 128 buffers (0.8%); 0 WAL file(s) added, ...
```

If checkpoints are too frequent, you will also see:

```
LOG: checkpoints are occurring too frequently (17 seconds apart)
HINT: Consider increasing the configuration parameter "max_wal_size".
```

> **Note:** If you see nothing, wait for the next checkpoint cycle (default `checkpoint_timeout` = 5 min). You can force one for testing: connect via `psql` and run `CHECKPOINT;`

### Filter specifically for the WARNING

To isolate only the "too frequent" warning:

```
resource.type="cloudsql_database"
resource.labels.database_id="myproject-123:my-pg-instance"
textPayload=~"checkpoints are occurring too frequently"
```

---

## Step 3: Create a Log-Based Metric

This converts the log entry into a Cloud Monitoring metric you can alert on.

### Console

1. In **Logs Explorer**, enter the filter for warnings:

```
resource.type="cloudsql_database"
textPayload=~"checkpoints are occurring too frequently"
```

> **Important:** Remove the `resource.labels.database_id` filter here. We want this metric to fire for ALL instances, not just one.

2. Click **Run query** to verify it works
3. Click the **Actions** dropdown (⋮ or "Create" button above results)
4. Click **Create metric**
5. Fill in:

| Field | Value |
|-------|-------|
| Metric type | **Counter** |
| Log-based metric name | `cloudsql_checkpoint_too_frequent` |
| Description | Fires when PostgreSQL logs checkpoint frequency warning |
| Units | `1` |
| Filter | (already populated from your query) |

6. Click **Create Metric**

### gcloud CLI

```bash
gcloud logging metrics create cloudsql_checkpoint_too_frequent \
  --description="Cloud SQL PostgreSQL checkpoint frequency warning" \
  --log-filter='resource.type="cloudsql_database" textPayload=~"checkpoints are occurring too frequently"'
```

### Verify metric was created

```bash
gcloud logging metrics list --format="table(name, filter)"
```

### Also create a metric for all checkpoint completions (optional, for dashboards)

```bash
gcloud logging metrics create cloudsql_checkpoint_complete \
  --description="Cloud SQL PostgreSQL checkpoint completed" \
  --log-filter='resource.type="cloudsql_database" textPayload=~"checkpoint complete"'
```

---

## Step 4: Create an Alert Policy

### Console

1. Go to **Monitoring** → **Alerting** → **Create Policy**
   Direct URL: `https://console.cloud.google.com/monitoring/alerting/policies/create`

2. **Add Condition:**
   - Click **Select a metric**
   - Choose resource type: **Cloud SQL Database**
   - In the metric filter, search for: `logging/user/cloudsql_checkpoint_too_frequent`
     (If you don't see it, type the full path: `logging.googleapis.com/user/cloudsql_checkpoint_too_frequent`)
   - Click **Apply**

3. **Configure Trigger:**

| Setting | Value |
|---------|-------|
| Condition type | Threshold |
| Alert when | Any time series violates |
| Threshold position | Above threshold |
| Threshold value | `0` |
| For | `0 minutes` (immediate) |
| Rolling window | `5 min` |
| Rolling window function | `sum` |

4. Click **Next**

5. **Notification Channels:**
   - Click **Manage Notification Channels** if you haven't set one up
   - Add Email / Slack / PagerDuty as needed
   - Select your channel and click **OK**

6. **Name the policy:** `CloudSQL PG - Checkpoints Too Frequent`

7. **Documentation** (optional but recommended — shows in the alert email):

```
Checkpoints are occurring too frequently on this Cloud SQL instance.

Impact: High I/O, increased latency, excessive full-page writes.

Fix:
1. Connect to the instance and check current settings:
   SELECT name, setting FROM pg_settings
   WHERE name IN ('max_wal_size', 'checkpoint_timeout', 'checkpoint_completion_target');

2. Check checkpoint stats:
   SELECT checkpoints_timed, checkpoints_req,
          checkpoint_write_time, checkpoint_sync_time
   FROM pg_stat_bgwriter;

3. Increase max_wal_size:
   gcloud sql instances patch INSTANCE --database-flags=max_wal_size=4096
   (Start with 4GB, increase to 8-20GB for heavy write loads)

4. Optionally increase checkpoint_timeout:
   gcloud sql instances patch INSTANCE --database-flags=checkpoint_timeout=900
   (15 minutes instead of default 5)
```

8. Click **Create Policy**

### gcloud CLI

```bash
# Get your notification channel ID first
CHANNEL=$(gcloud beta monitoring channels list \
  --filter="displayName='DBA Email'" \
  --format="value(name)")

# Create the alert policy
gcloud beta monitoring policies create \
  --display-name="CloudSQL PG - Checkpoints Too Frequent" \
  --condition-display-name="Checkpoint warning in logs" \
  --condition-filter='resource.type="cloudsql_database" AND metric.type="logging.googleapis.com/user/cloudsql_checkpoint_too_frequent"' \
  --condition-threshold-comparison="COMPARISON_GT" \
  --condition-threshold-value=0 \
  --condition-threshold-duration="0s" \
  --condition-threshold-aggregations-aligner="ALIGN_SUM" \
  --condition-threshold-aggregations-alignment-period="300s" \
  --notification-channels="$CHANNEL" \
  --combiner="OR"
```

### Terraform

```hcl
resource "google_logging_metric" "checkpoint_too_frequent" {
  name   = "cloudsql_checkpoint_too_frequent"
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

resource "google_monitoring_alert_policy" "checkpoint_alert" {
  display_name = "CloudSQL PG - Checkpoints Too Frequent"
  combiner     = "OR"

  conditions {
    display_name = "Checkpoint warning in logs"
    condition_threshold {
      filter = <<-EOT
        resource.type = "cloudsql_database"
        AND metric.type = "logging.googleapis.com/user/cloudsql_checkpoint_too_frequent"
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

  notification_channels = [google_monitoring_notification_channel.email.id]

  documentation {
    content   = <<-EOD
      Checkpoints too frequent on $${resource.label.database_id}.
      Increase max_wal_size (try 4-20GB) and checkpoint_timeout (try 10-15 min).
    EOD
    mime_type = "text/markdown"
  }
}
```

---

## Step 5: Automate for New Instances

The log-based metric (Step 3) and alert policy (Step 4) are **already project-wide** — they fire for any Cloud SQL instance that emits the warning. No per-instance alert setup needed.

The only thing a new instance needs is the **`log_checkpoints=on` flag**. Without it, PostgreSQL won't write checkpoint details to the log, and the metric has nothing to match.

### Option A: Terraform Module (best if infra is in code)

Create a reusable module with the flag baked in:

```hcl
# modules/cloudsql-pg/main.tf

variable "instance_name" { type = string }
variable "tier"          { type = string }
variable "region"        { type = string }

variable "extra_flags" {
  type    = list(object({ name = string, value = string }))
  default = []
}

resource "google_sql_database_instance" "pg" {
  name             = var.instance_name
  database_version = "POSTGRES_16"
  region           = var.region

  settings {
    tier            = var.tier
    disk_autoresize = true

    # Monitoring flag — always present
    database_flags {
      name  = "log_checkpoints"
      value = "on"
    }

    # Caller can add more flags
    dynamic "database_flags" {
      for_each = var.extra_flags
      content {
        name  = database_flags.value.name
        value = database_flags.value.value
      }
    }
  }
}
```

Usage:

```hcl
module "orders_db" {
  source        = "./modules/cloudsql-pg"
  instance_name = "orders-prod"
  tier          = "db-custom-4-15360"
  region        = "us-central1"
}

module "analytics_db" {
  source        = "./modules/cloudsql-pg"
  instance_name = "analytics-prod"
  tier          = "db-custom-8-30720"
  region        = "us-central1"

  extra_flags = [
    { name = "max_connections", value = "300" }
  ]
}
# Both get log_checkpoints=on automatically
```

### Option B: Eventarc + Cloud Function (catches instances created outside Terraform)

When someone creates a Cloud SQL instance from the Console or gcloud, this function auto-patches the flag.

**`main.py`**

```python
import functions_framework
import subprocess
import json
import logging

logger = logging.getLogger(__name__)

REQUIRED_FLAGS = {"log_checkpoints": "on"}


@functions_framework.cloud_event
def patch_new_instance(cloud_event):
    payload = cloud_event.data.get("protoPayload", {})

    if "cloudsql.instances.create" not in payload.get("methodName", ""):
        return

    resource = payload.get("resourceName", "")
    parts = resource.split("/")
    project, instance = parts[1], parts[3]

    db_ver = payload.get("request", {}).get("body", {}).get("databaseVersion", "")
    if not db_ver.startswith("POSTGRES"):
        return

    # Read existing flags
    try:
        out = subprocess.run(
            ["gcloud", "sql", "instances", "describe", instance,
             "--project", project, "--format=json(settings.databaseFlags)"],
            capture_output=True, text=True, check=True, timeout=30
        )
        existing = {f["name"]: f["value"]
                    for f in json.loads(out.stdout)
                    .get("settings", {}).get("databaseFlags", [])}
    except Exception:
        existing = {}

    # Merge
    merged = {**existing, **REQUIRED_FLAGS}
    flags_str = ",".join(f"{k}={v}" for k, v in merged.items())

    # Patch
    subprocess.run(
        ["gcloud", "sql", "instances", "patch", instance,
         "--project", project, f"--database-flags={flags_str}", "--quiet"],
        check=True, timeout=120
    )
    logger.info(f"Patched {instance} with flags: {flags_str}")
```

**`requirements.txt`**

```
functions-framework==3.*
```

**Deploy:**

```bash
PROJECT_ID=$(gcloud config get project)
SA_EMAIL="cloudsql-flag-patcher@${PROJECT_ID}.iam.gserviceaccount.com"

# Create service account
gcloud iam service-accounts create cloudsql-flag-patcher \
  --display-name="CloudSQL Flag Patcher"

# Grant Cloud SQL editor
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/cloudsql.editor"

# Grant Eventarc receiver
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/eventarc.eventReceiver"

# Deploy function
gcloud functions deploy patch-cloudsql-flags \
  --gen2 \
  --runtime=python312 \
  --region=us-central1 \
  --source=. \
  --entry-point=patch_new_instance \
  --trigger-event-filters="type=google.cloud.audit.log.v1.written" \
  --trigger-event-filters="serviceName=sqladmin.googleapis.com" \
  --trigger-event-filters="methodName=cloudsql.instances.create" \
  --service-account=$SA_EMAIL \
  --timeout=180
```

### Option C: Shell Script (quick one-time patch for all existing instances)

Patch every existing PostgreSQL instance in the project right now:

```bash
#!/bin/bash
# patch-all-instances.sh
# Adds log_checkpoints=on to all Cloud SQL PostgreSQL instances

PROJECT_ID=$(gcloud config get project)

for INSTANCE in $(gcloud sql instances list \
  --filter="databaseVersion~POSTGRES" \
  --format="value(name)"); do

  echo "--- Patching: $INSTANCE ---"

  # Get existing flags
  EXISTING=$(gcloud sql instances describe $INSTANCE \
    --format="json(settings.databaseFlags)" 2>/dev/null)

  # Check if log_checkpoints is already on
  if echo "$EXISTING" | grep -q '"log_checkpoints"'; then
    echo "  log_checkpoints already set, skipping."
    continue
  fi

  # Build new flags string: existing + log_checkpoints=on
  CURRENT_FLAGS=$(echo "$EXISTING" | python3 -c "
import sys, json
data = json.load(sys.stdin)
flags = data.get('settings', {}).get('databaseFlags', [])
parts = [f'{f[\"name\"]}={f[\"value\"]}' for f in flags]
parts.append('log_checkpoints=on')
print(','.join(parts))
" 2>/dev/null || echo "log_checkpoints=on")

  gcloud sql instances patch $INSTANCE \
    --database-flags="$CURRENT_FLAGS" \
    --quiet

  echo "  Done."
done
```

Run it:

```bash
chmod +x patch-all-instances.sh
./patch-all-instances.sh
```

---

## How It All Fits Together

```
┌──────────────────────────────────────────────────┐
│         Instance (existing or new)                │
│                                                   │
│   log_checkpoints = on                            │
│          │                                        │
│          ▼                                        │
│   postgres.log writes:                            │
│   "checkpoints are occurring too frequently"      │
│          │                                        │
└──────────┼────────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────┐
│         Cloud Logging (automatic)                 │
│                                                   │
│   Log entry appears in Logs Explorer              │
│          │                                        │
│          ▼                                        │
│   Log-based metric matches the entry              │
│   (cloudsql_checkpoint_too_frequent)              │
│          │                                        │
│          ▼                                        │
│   Alert policy fires (threshold > 0)              │
│          │                                        │
│          ▼                                        │
│   Notification: Email / Slack / PagerDuty         │
└──────────────────────────────────────────────────┘

Scope:
  - Log-based metric = project-wide (all instances)
  - Alert policy      = project-wide (all instances)
  - Database flag     = per-instance (automate via Terraform / Cloud Function / script)
```

---

## When the Alert Fires: Fix the Checkpoint Issue

### 1. Check current settings

```sql
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('max_wal_size', 'min_wal_size',
               'checkpoint_timeout', 'checkpoint_completion_target');
```

Default Cloud SQL values:

| Parameter | Enterprise | Enterprise Plus |
|-----------|-----------|-----------------|
| `max_wal_size` | 1.5 GB | 5 GB |
| `checkpoint_timeout` | 5 min | 5 min |
| `checkpoint_completion_target` | 0.9 | 0.9 |

### 2. Check checkpoint stats

```sql
SELECT checkpoints_timed,
       checkpoints_req,
       ROUND(100.0 * checkpoints_req /
         NULLIF(checkpoints_timed + checkpoints_req, 0), 1) AS pct_forced,
       checkpoint_write_time,
       checkpoint_sync_time
FROM pg_stat_bgwriter;
```

- `checkpoints_timed` = scheduled (good)
- `checkpoints_req` = forced due to WAL volume (bad if high)
- If `pct_forced` > 20%, you need to increase `max_wal_size`

### 3. Increase max_wal_size

```bash
# Start with 4 GB, go up to 8-20 GB for heavy write loads
gcloud sql instances patch $INSTANCE \
  --database-flags=log_checkpoints=on,max_wal_size=4096
```

| Write Load | Recommended max_wal_size |
|------------|--------------------------|
| Light (< 100 TPS) | 2–4 GB |
| Medium (100–500 TPS) | 4–8 GB |
| Heavy (500+ TPS) | 8–20 GB |
| Bulk loads / migrations | 20+ GB (temporary) |

### 4. Optionally increase checkpoint_timeout

```bash
gcloud sql instances patch $INSTANCE \
  --database-flags=log_checkpoints=on,max_wal_size=8192,checkpoint_timeout=900
```

`900` = 15 minutes (default is 300 = 5 min).

> **Trade-off:** Longer checkpoint intervals = longer crash recovery time. For Cloud SQL with HA enabled, this is usually acceptable.

### 5. Verify fix

After changing, monitor logs again:

```
resource.type="cloudsql_database"
resource.labels.database_id="PROJECT:INSTANCE"
textPayload=~"checkpoint"
```

You should see `checkpoint starting: time` (scheduled) instead of `checkpoint starting: xlog` (forced by WAL volume). The "too frequently" warning should stop.

---

## Checklist

- [ ] **Step 1:** `log_checkpoints=on` on current instance
- [ ] **Step 2:** Verified checkpoint logs in Log Explorer
- [ ] **Step 3:** Created log-based metric `cloudsql_checkpoint_too_frequent`
- [ ] **Step 4:** Created alert policy with notification channel
- [ ] **Step 5:** Chose automation for new instances:
  - [ ] Terraform module with flag baked in, OR
  - [ ] Eventarc + Cloud Function to auto-patch, OR
  - [ ] Shell script to patch all existing instances
- [ ] **Runbook:** Team knows how to fix when alert fires (increase `max_wal_size`)
