# PostgreSQL High Availability Solutions
## PgBouncer, Pgpool-II & Patroni

---

# Agenda

1. **Connection Pooling Fundamentals**
2. **PgBouncer** - Lightweight Connection Pooler
3. **Pgpool-II** - Connection Pooling + Load Balancing + HA
4. **Patroni** - Automated HA with Failover
5. **Comparison & When to Use What**
6. **Hands-on Lab**

---

# Why Connection Pooling?

## The Problem

```
PostgreSQL max_connections = 100 (default)
Each connection = ~10MB RAM
1000 users hitting database = 💥 CRASH
```

## The Solution

```
1000 Users → Connection Pooler (20 connections) → PostgreSQL
```

**Benefits:**
- Reduced memory usage
- Faster connection times
- Better resource utilization
- Handle more concurrent users

---

# Connection Pooling - How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                         CLIENTS                              │
│  [App1] [App2] [App3] [App4] ... [App200]                   │
└──────────────────────┬──────────────────────────────────────┘
                       │ 200 client connections
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                   CONNECTION POOLER                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │            Connection Pool (20 connections)          │   │
│  │  [1] [2] [3] [4] [5] ... [20]                       │   │
│  └─────────────────────────────────────────────────────┘   │
└──────────────────────┬──────────────────────────────────────┘
                       │ 20 server connections
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                      POSTGRESQL                              │
│                   max_connections = 100                      │
└─────────────────────────────────────────────────────────────┘
```

---

# PgBouncer

## What is PgBouncer?

- **Lightweight** connection pooler for PostgreSQL
- Written in C, very low memory footprint (~2KB per connection)
- Single-threaded, event-based architecture
- Created by Skype, now widely used

## Key Features

- Three pool modes: Session, Transaction, Statement
- Authentication pass-through
- Online restart/reload
- Admin console for monitoring

---

# PgBouncer - Pool Modes

| Mode | Description | Best For |
|------|-------------|----------|
| **Session** | Connection held until client disconnects | Legacy apps, session variables |
| **Transaction** | Connection returned after each transaction | Most applications (recommended) |
| **Statement** | Connection returned after each statement | Simple queries, autocommit |

## Transaction Mode (Recommended)

```
Client A: BEGIN → query → COMMIT → connection released
Client B: picks up same connection immediately
```

**Result:** 200 clients can share 20 PostgreSQL connections!

---

# PgBouncer - Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    APPLICATION SERVER                     │
│                                                          │
│   psql -h localhost -p 6432 -U postgres postgres        │
│                           │                              │
└───────────────────────────┼──────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────┐
│                      PGBOUNCER                            │
│                    Port: 6432                             │
│  ┌────────────────────────────────────────────────────┐  │
│  │ pgbouncer.ini:                                     │  │
│  │   pool_mode = transaction                          │  │
│  │   default_pool_size = 20                           │  │
│  │   max_client_conn = 1000                           │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────┬───────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────┐
│                     POSTGRESQL                            │
│                    Port: 5432                             │
└──────────────────────────────────────────────────────────┘
```

---

# PgBouncer - Key Configuration

```ini
[databases]
* = host=192.168.44.128 port=5432

[pgbouncer]
listen_addr = *
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt

# Pool settings
pool_mode = transaction
default_pool_size = 20
max_client_conn = 1000
```

---

# PgBouncer - Admin Commands

Connect to admin console:
```bash
psql -U postgres -h localhost -p 6432 pgbouncer
```

| Command | Description |
|---------|-------------|
| `SHOW POOLS;` | View connection pools |
| `SHOW CLIENTS;` | View client connections |
| `SHOW SERVERS;` | View server connections |
| `SHOW STATS;` | View statistics |
| `RELOAD;` | Reload configuration |
| `PAUSE;` | Pause all connections |
| `RESUME;` | Resume connections |

---

# PgBouncer - Demo: High Concurrency Test

## Without PgBouncer (Direct Connection)

```bash
pgbench -c 200 -t 10 -S -U postgres -h 192.168.44.128 -p 5432 postgres

# Result: FATAL: sorry, too many clients already ❌
```

## With PgBouncer

```bash
pgbench -c 200 -t 10 -S -U postgres -h localhost -p 6432 postgres

# Result: 
# number of transactions: 2000/2000 ✅
# tps = 4500.470299
```

**PgBouncer handles 200 clients with only 20 PostgreSQL connections!**

---

# Pgpool-II

## What is Pgpool-II?

- **Multi-function** middleware for PostgreSQL
- More than just connection pooling
- Created by PgPool Global Development Group

## Key Features

- Connection Pooling
- Load Balancing (read queries to replicas)
- Automatic Failover
- Replication (native)
- Query Caching
- Watchdog for HA

---

# Pgpool-II - Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                       APPLICATIONS                           │
│                                                             │
│     psql -h localhost -p 9999 -U postgres postgres         │
│                            │                                │
└────────────────────────────┼────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                        PGPOOL-II                             │
│                       Port: 9999                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  • Connection Pooling                                │   │
│  │  • Load Balancing (SELECT → Replicas)               │   │
│  │  • Health Check                                      │   │
│  │  • Automatic Failover                               │   │
│  └─────────────────────────────────────────────────────┘   │
└──────────────┬─────────────────────────┬────────────────────┘
               │                         │
               ▼                         ▼
┌──────────────────────────┐  ┌──────────────────────────┐
│       PRIMARY            │  │       STANDBY            │
│   192.168.44.128:5432    │  │   192.168.44.129:5432    │
│   (Read + Write)         │  │   (Read Only)            │
└──────────────────────────┘  └──────────────────────────┘
```

---

# Pgpool-II - Load Balancing

## How It Works

```
┌────────────────────────────────────────────────────────────┐
│                         PGPOOL-II                           │
│                                                            │
│   SELECT queries ──────────────┐                           │
│                                ▼                           │
│   ┌─────────────────────────────────────────────────┐     │
│   │         LOAD BALANCER (Round Robin)              │     │
│   └──────────┬────────────────────────┬─────────────┘     │
│              │                        │                    │
│              ▼                        ▼                    │
│   ┌──────────────────┐    ┌──────────────────┐           │
│   │     PRIMARY      │    │     STANDBY      │           │
│   │ weight = 0.5     │    │ weight = 0.5     │           │
│   └──────────────────┘    └──────────────────┘           │
│                                                            │
│   INSERT/UPDATE/DELETE ────────► PRIMARY only             │
└────────────────────────────────────────────────────────────┘
```

---

# Pgpool-II - Key Configuration

```ini
# Backend Connection Settings
backend_hostname0 = '192.168.44.128'
backend_port0 = 5432
backend_weight0 = 1
backend_flag0 = 'ALLOW_TO_FAILOVER'

backend_hostname1 = '192.168.44.129'
backend_port1 = 5432
backend_weight1 = 1
backend_flag1 = 'ALLOW_TO_FAILOVER'

# Health Check
health_check_period = 1
health_check_user = 'postgres'
health_check_password = 'postgres'

# Streaming Replication Check
sr_check_user = 'postgres'
sr_check_password = 'postgres'
```

---

# Pgpool-II - Monitoring

## Show Pool Nodes

```bash
psql -U postgres -p 9999 -c "show pool_nodes"
```

```
 node_id |    hostname    | port | status | pg_status | role    
---------+----------------+------+--------+-----------+---------
 0       | 192.168.44.128 | 5432 | up     | up        | primary 
 1       | 192.168.44.129 | 5432 | up     | up        | standby 
```

## Key Status Values

| Status | Meaning |
|--------|---------|
| `up` | Node is healthy |
| `down` | Node is unreachable |
| `primary` | Write node |
| `standby` | Read-only replica |

---

# Patroni

## What is Patroni?

- **Template** for PostgreSQL HA with automatic failover
- Uses distributed consensus (etcd, Consul, ZooKeeper)
- Created by Zalando
- Industry standard for PostgreSQL HA

## Key Features

- Automatic failover
- Automatic cluster bootstrap
- REST API for management
- Watchdog support (fencing)
- Supports multiple DCS backends

---

# Patroni - Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                            CLIENTS                               │
│              psql -h VIP -p 5000 -U postgres                    │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                          HAPROXY                                 │
│   ┌───────────────────┐  ┌───────────────────┐                  │
│   │ Primary: Port 5000│  │ Standby: Port 5001│                  │
│   │ (Read/Write)      │  │ (Read Only)       │                  │
│   └─────────┬─────────┘  └─────────┬─────────┘                  │
└─────────────┼─────────────────────┼─────────────────────────────┘
              │                     │
    ┌─────────┴─────────┬───────────┴─────────┐
    ▼                   ▼                     ▼
┌─────────┐       ┌─────────┐           ┌─────────┐
│  lab01  │       │  lab02  │           │  lab03  │
│ LEADER  │◄─────►│ REPLICA │◄─────────►│ REPLICA │
│Patroni  │       │ Patroni │           │ Patroni │
│PostgreSQL│       │PostgreSQL│           │PostgreSQL│
└────┬────┘       └────┬────┘           └────┬────┘
     │                 │                     │
     └────────────┬────┴─────────────────────┘
                  ▼
        ┌─────────────────┐
        │      ETCD       │
        │  (DCS Cluster)  │
        │   Leader Lock   │
        └─────────────────┘
```

---

# Patroni - Components

| Component | Purpose |
|-----------|---------|
| **Patroni** | HA agent running on each PostgreSQL node |
| **etcd** | Distributed key-value store (consensus) |
| **HAProxy** | Load balancer, routes to current leader |
| **Keepalived** | Manages Virtual IP (VIP) |
| **Watchdog** | Fencing (prevents split-brain) |

---

# Patroni - How Failover Works

## Step 1: Leader Failure Detected

```
etcd detects: lab01 (leader) not responding
             └── Leader lock expires (TTL = 30s)
```

## Step 2: New Leader Election

```
lab02: "I want to be leader!"
lab03: "I want to be leader!"

etcd: Grants lock to lab02 (first to acquire)
      └── lab02 becomes new leader
```

## Step 3: Promotion & Recovery

```
lab02: Promotes to primary (pg_ctl promote)
lab03: Follows new leader (lab02)
lab01: When recovered, rejoins as replica
```

**Total failover time: ~10-30 seconds**

---

# Patroni - Key Configuration

```yaml
scope: postgres
name: lab01

restapi:
  listen: 192.168.44.132:8008
  connect_address: 192.168.44.132:8008

etcd3:
  hosts: 192.168.44.132:2379,192.168.44.133:2379,192.168.44.130:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576

postgresql:
  listen: 192.168.44.132:5432
  data_dir: /u01/pgsql/17
  authentication:
    replication:
      username: replicator
      password: replicator
    superuser:
      username: postgres
      password: postgres
```

---

# Patroni - Management Commands

## Cluster Status

```bash
patronictl -c /etc/patroni/patroni.yml list
```

```
+ Cluster: postgres -------+----+-----------+
| Member |      Host      | Role    | State     |
+--------+----------------+---------+-----------+
| lab01  | 192.168.44.132 | Leader  | running   |
| lab02  | 192.168.44.133 | Replica | streaming |
| lab03  | 192.168.44.130 | Replica | streaming |
+--------+----------------+---------+-----------+
```

## Switchover (Planned)

```bash
patronictl -c /etc/patroni/patroni.yml switchover
```

## Failover (Emergency)

```bash
patronictl -c /etc/patroni/patroni.yml failover
```

---

# Patroni - Demo: Switchover

## Before Switchover

```
| lab01  | Leader  | running   |
| lab02  | Replica | streaming |
| lab03  | Replica | streaming |
```

## Execute Switchover

```bash
patronictl -c /etc/patroni/patroni.yml switchover
# Select: lab02 as new leader
```

## After Switchover

```
| lab01  | Replica | streaming |
| lab02  | Leader  | running   |  ← New Leader
| lab03  | Replica | streaming |
```

**Zero downtime! Applications continue through VIP.**

---

# Comparison: PgBouncer vs Pgpool-II vs Patroni

| Feature | PgBouncer | Pgpool-II | Patroni |
|---------|-----------|-----------|---------|
| Connection Pooling | ✅ Excellent | ✅ Good | ❌ No |
| Load Balancing | ❌ No | ✅ Yes | ❌ (via HAProxy) |
| Automatic Failover | ❌ No | ✅ Yes | ✅ Yes |
| Query Caching | ❌ No | ✅ Yes | ❌ No |
| Memory Usage | Very Low | Medium | Low |
| Complexity | Low | Medium | High |
| Best For | Pooling only | All-in-one | HA clusters |

---

# When to Use What?

## PgBouncer

- Need connection pooling only
- Want minimal overhead
- Already have HA solution

## Pgpool-II

- Need pooling + load balancing
- Want single solution for everything
- 2-node setups

## Patroni

- Production HA cluster
- Need automatic failover
- 3+ node clusters
- Cloud deployments

---

# Common Architecture Patterns

## Pattern 1: Simple (PgBouncer + Streaming Replication)

```
Apps → PgBouncer → Primary → Standby
```

## Pattern 2: Load Balanced (Pgpool-II)

```
Apps → Pgpool-II → Primary + Standby (load balanced)
```

## Pattern 3: Enterprise HA (Patroni + PgBouncer)

```
Apps → PgBouncer → HAProxy → Patroni Cluster (3 nodes)
                              └── etcd (consensus)
```

---

# Hands-on Lab

## Lab 1: PgBouncer Setup

```bash
./pgbouncer_setup.sh 192.168.44.128
```

## Lab 2: Pgpool-II Setup

```bash
./pgpool_setup.sh 192.168.44.128 192.168.44.129
```

## Lab 3: Patroni HA Cluster

```bash
./patroni_ha_setup.sh 192.168.44.132 192.168.44.133 192.168.44.130 192.168.44.140
```

---

# Lab Scripts - Complete Reference

## Setup Scripts

### 1. SSH Passwordless Setup (Run First for Patroni)

```bash
./ssh_setup.sh <lab01_ip> <lab02_ip> <lab03_ip>
```

**Example:**
```bash
./ssh_setup.sh 192.168.44.132 192.168.44.133 192.168.44.130
```

**What it does:**
- Generates SSH key if not exists
- Copies SSH key to all 3 machines (will ask password 3 times)
- Updates /etc/hosts with hostnames
- Tests passwordless connectivity

---

### 2. PgBouncer Setup

```bash
./pgbouncer_setup.sh <backend_ip> [options]
```

**Options:**
| Option | Description | Default |
|--------|-------------|---------|
| `-p, --port` | PostgreSQL port | 5432 |
| `-b, --bouncer-port` | PgBouncer port | 6432 |
| `-u, --user` | Database user | postgres |
| `-P, --password` | Database password | postgres |
| `-m, --pool-mode` | Pool mode: session/transaction/statement | transaction |
| `-s, --pool-size` | Default pool size | 20 |

**Examples:**
```bash
# Basic setup
./pgbouncer_setup.sh 192.168.44.128

# With custom pool mode and size
./pgbouncer_setup.sh 192.168.44.128 -m session -s 50

# With custom port
./pgbouncer_setup.sh 192.168.44.128 -b 6433
```

**What it does:**
- Installs PgBouncer via dnf
- Creates configuration files
- Sets up authentication
- Starts and enables service
- Runs connection tests
- Runs pgbench performance tests (including 200 client test)

---

### 3. Pgpool-II Setup

```bash
./pgpool_setup.sh <primary_ip> <standby_ip> [options]
```

**Options:**
| Option | Description | Default |
|--------|-------------|---------|
| `-p, --port` | PostgreSQL port | 5432 |
| `-d, --data-dir` | PostgreSQL data directory | /u01/pgsql/16 |
| `-u, --user` | Health check user | postgres |
| `-P, --password` | Health check password | postgres |

**Examples:**
```bash
# Basic setup
./pgpool_setup.sh 192.168.44.128 192.168.44.129

# With custom data directory
./pgpool_setup.sh 192.168.44.128 192.168.44.129 -d /var/lib/pgsql/17/data
```

**What it does:**
- Installs Pgpool-II via dnf
- Creates required directories with proper permissions
- Configures backends, health check, streaming replication check
- Sets up load balancing
- Starts and enables service
- Verifies with `show pool_nodes`

---

### 4. Patroni HA Cluster Setup

```bash
./patroni_ha_setup.sh <lab01_ip> <lab02_ip> <lab03_ip> <vip> [options]
```

**Options:**
| Option | Description | Default |
|--------|-------------|---------|
| `-i, --interface` | Network interface | ens33 |
| `-v, --pg-version` | PostgreSQL version (17 or 18) | 17 |
| `-P, --password` | PostgreSQL password | postgres |
| `-c, --check` | Only run pre-flight checks | - |
| `--verify` | Only verify existing cluster | - |

**Examples:**
```bash
# Basic setup with PostgreSQL 17
./patroni_ha_setup.sh 192.168.44.132 192.168.44.133 192.168.44.130 192.168.44.140

# With PostgreSQL 18
./patroni_ha_setup.sh 192.168.44.132 192.168.44.133 192.168.44.130 192.168.44.140 -v 18

# With custom network interface
./patroni_ha_setup.sh 192.168.44.132 192.168.44.133 192.168.44.130 192.168.44.140 -i eth0

# Check SSH connectivity only
./patroni_ha_setup.sh 192.168.44.132 192.168.44.133 192.168.44.130 192.168.44.140 -c

# Verify existing cluster
./patroni_ha_setup.sh 192.168.44.132 192.168.44.133 192.168.44.130 192.168.44.140 --verify
```

**What it does:**
- Sets up /etc/hosts on all nodes
- Creates postgres user
- Disables SELinux, configures firewall
- Installs PostgreSQL, etcd, Keepalived, HAProxy, Patroni
- Configures all components
- Starts cluster with lab01 as initial leader
- Verifies cluster status

**Prerequisites:**
- Run `ssh_setup.sh` first for passwordless SSH
- 3 RHEL/Rocky/Alma Linux 9 machines
- Root access on all machines

---

## Cleanup Scripts

### 1. PgBouncer Cleanup

```bash
./pgbouncer_cleanup.sh
```

**What it removes:**
- PgBouncer service and package
- Configuration files (/etc/pgbouncer/)
- Log files (/var/log/pgbouncer/)
- Runtime files (/var/run/pgbouncer/)

---

### 2. Pgpool-II Cleanup

```bash
./pgpool_cleanup.sh
```

**What it removes:**
- Pgpool-II service and package
- Configuration files (/etc/pgpool-II/)
- Runtime files (/var/run/pgpool-II/)
- Log files
- PCP socket files

---

### 3. Patroni Cluster Cleanup

```bash
./patroni_cleanup.sh <lab01_ip> <lab02_ip> <lab03_ip>
```

**Example:**
```bash
./patroni_cleanup.sh 192.168.44.132 192.168.44.133 192.168.44.130
```

**What it removes (on all 3 nodes):**
- Patroni service and package
- PostgreSQL data directory (/u01/pgsql/)
- etcd service, package, and data
- HAProxy service, package, and config
- Keepalived service, package, and config
- Watchdog

---

## Quick Reference Card

### Setup Commands
```bash
# 1. SSH (required for Patroni)
./ssh_setup.sh 192.168.44.132 192.168.44.133 192.168.44.130

# 2. PgBouncer (single node)
./pgbouncer_setup.sh 192.168.44.128

# 3. Pgpool-II (2 nodes)
./pgpool_setup.sh 192.168.44.128 192.168.44.129

# 4. Patroni (3 nodes + VIP)
./patroni_ha_setup.sh 192.168.44.132 192.168.44.133 192.168.44.130 192.168.44.140
```

### Cleanup Commands
```bash
./pgbouncer_cleanup.sh
./pgpool_cleanup.sh
./patroni_cleanup.sh 192.168.44.132 192.168.44.133 192.168.44.130
```

### Test Commands
```bash
# PgBouncer - High concurrency test
pgbench -c 200 -t 10 -S -U postgres -h localhost -p 6432 postgres

# Pgpool-II - Show nodes
psql -U postgres -p 9999 -c "show pool_nodes"

# Patroni - Cluster status
patronictl -c /etc/patroni/patroni.yml list

# Patroni - Switchover
patronictl -c /etc/patroni/patroni.yml switchover
```

### Connection Strings
```bash
# PgBouncer
psql -h localhost -p 6432 -U postgres postgres

# Pgpool-II
psql -h localhost -p 9999 -U postgres postgres

# Patroni (via VIP)
psql -h 192.168.44.140 -p 5000 -U postgres postgres  # Primary (read-write)
psql -h 192.168.44.140 -p 5001 -U postgres postgres  # Standby (read-only)
```

---

# Lab Tests

## PgBouncer Test

```bash
# Direct connection (fails at 200 clients)
pgbench -c 200 -t 10 -S -U postgres -h 192.168.44.128 -p 5432 postgres

# Via PgBouncer (succeeds)
pgbench -c 200 -t 10 -S -U postgres -h localhost -p 6432 postgres
```

## Pgpool-II Test

```bash
# Show nodes
psql -U postgres -p 9999 -c "show pool_nodes"
```

## Patroni Test

```bash
# Cluster status
patronictl -c /etc/patroni/patroni.yml list

# Switchover
patronictl -c /etc/patroni/patroni.yml switchover
```

---

# Summary

| Solution | Primary Use Case | Complexity |
|----------|------------------|------------|
| **PgBouncer** | Connection pooling | Low |
| **Pgpool-II** | Pooling + Load Balancing + HA | Medium |
| **Patroni** | Enterprise HA with automatic failover | High |

## Key Takeaways

1. **Connection pooling is essential** for production
2. **PgBouncer** is lightweight and fast
3. **Pgpool-II** provides all-in-one solution
4. **Patroni** is the industry standard for HA
5. **Combine tools** for best results (e.g., Patroni + PgBouncer)

---

# Questions?

## Resources

- PgBouncer: https://www.pgbouncer.org/
- Pgpool-II: https://www.pgpool.net/
- Patroni: https://github.com/zalando/patroni
- PostgreSQL HA Guide: https://postgreshelp.com/

## Lab Scripts

- `pgbouncer_setup.sh`
- `pgpool_setup.sh`
- `patroni_ha_setup.sh`
- `patroni_cleanup.sh`
- `ssh_setup.sh`

---

# Thank You!

