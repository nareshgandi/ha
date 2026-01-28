# PostgreSQL High Availability - Complete Lab Guide

## Overview

This guide provides step-by-step instructions for setting up and testing three PostgreSQL HA solutions:

1. **PgBouncer** - Connection Pooling
2. **Pgpool-II** - Connection Pooling + Load Balancing + Failover
3. **Patroni** - Automated HA with Failover (3-node cluster)

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Lab Environment](#lab-environment)
3. [Part 1: PgBouncer Setup & Demo](#part-1-pgbouncer-setup--demo)
4. [Part 2: Pgpool-II Setup & Demo](#part-2-pgpool-ii-setup--demo)
5. [Part 3: Patroni HA Cluster Setup & Demo](#part-3-patroni-ha-cluster-setup--demo)
6. [Part 4: Patroni Failover Testing](#part-4-patroni-failover-testing)
7. [Cleanup Procedures](#cleanup-procedures)
8. [Troubleshooting](#troubleshooting)
9. [Quick Reference](#quick-reference)

---

## Prerequisites

### Software Requirements
- RHEL/Rocky/Alma Linux 9
- PostgreSQL 17 or 18 installed
- Root access on all machines

### Scripts Required
Download all scripts to your working directory:
- `ssh_setup.sh` - Passwordless SSH setup
- `pgbouncer_setup.sh` - PgBouncer installation
- `pgpool_setup.sh` - Pgpool-II installation  
- `patroni_ha_setup.sh` - Patroni cluster setup
- `patroni_failover_test.sh` - Failover testing & recovery
- `pgbouncer_cleanup.sh` - Remove PgBouncer
- `pgpool_cleanup.sh` - Remove Pgpool-II
- `patroni_cleanup.sh` - Remove Patroni cluster

### Make Scripts Executable
```bash
chmod +x *.sh
```

---

## Lab Environment

### For PgBouncer (Single Node)
```
┌─────────────────────────────────────┐
│           Application               │
│    psql -h localhost -p 6432        │
└─────────────────┬───────────────────┘
                  │
                  ▼
┌─────────────────────────────────────┐
│           PgBouncer                 │
│           Port: 6432                │
└─────────────────┬───────────────────┘
                  │
                  ▼
┌─────────────────────────────────────┐
│          PostgreSQL                 │
│      192.168.44.128:5432            │
└─────────────────────────────────────┘
```

### For Pgpool-II (2 Nodes)
```
┌─────────────────────────────────────┐
│           Application               │
│    psql -h localhost -p 9999        │
└─────────────────┬───────────────────┘
                  │
                  ▼
┌─────────────────────────────────────┐
│           Pgpool-II                 │
│           Port: 9999                │
│     (Load Balancing + Failover)     │
└────────┬───────────────────┬────────┘
         │                   │
         ▼                   ▼
┌─────────────────┐ ┌─────────────────┐
│    Primary      │ │    Standby      │
│ 192.168.44.128  │ │ 192.168.44.129  │
│    Port 5432    │ │    Port 5432    │
└─────────────────┘ └─────────────────┘
```

### For Patroni (3 Nodes)
```
┌─────────────────────────────────────────────────────────┐
│                      Application                         │
│           psql -h 192.168.44.140 -p 5000                │
└─────────────────────────┬───────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│                    HAProxy + VIP                         │
│              VIP: 192.168.44.140                         │
│         Port 5000 (Primary) / 5001 (Standby)            │
└────────────┬────────────┬────────────┬──────────────────┘
             │            │            │
             ▼            ▼            ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│      lab01       │ │      lab02       │ │      lab03       │
│  192.168.44.132  │ │  192.168.44.133  │ │  192.168.44.130  │
│  Patroni + PG    │ │  Patroni + PG    │ │  Patroni + PG    │
│  etcd + HAProxy  │ │  etcd + HAProxy  │ │  etcd + HAProxy  │
│  Keepalived      │ │  Keepalived      │ │  Keepalived      │
└──────────────────┘ └──────────────────┘ └──────────────────┘
             │            │            │
             └────────────┼────────────┘
                          ▼
               ┌──────────────────┐
               │   etcd Cluster   │
               │  (Consensus)     │
               └──────────────────┘
```

---

## Part 1: PgBouncer Setup & Demo

### 1.1 Installation

**Run the setup script:**
```bash
./pgbouncer_setup.sh 192.168.44.128
```

**With custom options:**
```bash
./pgbouncer_setup.sh 192.168.44.128 -m transaction -s 20 -b 6432
```

**Options:**
| Option | Description | Default |
|--------|-------------|---------|
| `-m` | Pool mode (session/transaction/statement) | transaction |
| `-s` | Pool size | 20 |
| `-b` | PgBouncer port | 6432 |
| `-u` | Database user | postgres |
| `-P` | Password | postgres |

### 1.2 Verify Installation

**Check service status:**
```bash
systemctl status pgbouncer
```

**Check listening port:**
```bash
ss -tlnp | grep 6432
```

**Expected output:**
```
LISTEN 0 128 0.0.0.0:6432 0.0.0.0:* users:(("pgbouncer",pid=1234,fd=9))
```

### 1.3 Test Connection

**Connect via PgBouncer:**
```bash
psql -U postgres -h localhost -p 6432 postgres
```

**Verify backend connection:**
```sql
SELECT inet_server_addr(), inet_server_port();
```

**Expected output:**
```
 inet_server_addr | inet_server_port 
------------------+------------------
 192.168.44.128   |             5432
```

### 1.4 Admin Console

**Connect to admin console:**
```bash
psql -U postgres -h localhost -p 6432 pgbouncer
```

**Show connection pools:**
```sql
SHOW POOLS;
```

**Expected output:**
```
 database  |   user    | cl_active | cl_waiting | sv_active | sv_idle | pool_mode
-----------+-----------+-----------+------------+-----------+---------+-------------
 pgbouncer | pgbouncer |         1 |          0 |         0 |       0 | statement
 postgres  | postgres  |         0 |          0 |         0 |       1 | transaction
```

**Show statistics:**
```sql
SHOW STATS;
```

**Show clients:**
```sql
SHOW CLIENTS;
```

**Show servers:**
```sql
SHOW SERVERS;
```

**Show configuration:**
```sql
SHOW CONFIG;
```

### 1.5 Performance Test - Connection Pooling Benefit

This is the key demonstration of why PgBouncer is valuable.

**Test 1: Direct connection with 200 clients (will FAIL)**
```bash
pgbench -c 200 -t 10 -S -U postgres -h 192.168.44.128 -p 5432 postgres
```

**Expected result:**
```
pgbench: error: connection to server failed: FATAL: sorry, too many clients already
```

**Test 2: Via PgBouncer with 200 clients (will SUCCEED)**
```bash
pgbench -c 200 -t 10 -S -U postgres -h localhost -p 6432 postgres
```

**Expected result:**
```
pgbench (17.0)
transaction type: <builtin: select only>
number of clients: 200
number of transactions per client: 10
number of transactions actually processed: 2000/2000
tps = 4500.470299 (without initial connection time)
```

### 1.6 Key Takeaway

| Scenario | Direct Connection | Via PgBouncer |
|----------|-------------------|---------------|
| 200 concurrent clients | ❌ FAILS | ✅ Works |
| PostgreSQL connections used | 200 (exceeds limit) | 20 (pooled) |
| Result | Connection refused | 4500+ TPS |

**How it works:**
- 200 clients connect to PgBouncer
- PgBouncer maintains only 20 connections to PostgreSQL
- Clients share these 20 connections
- In transaction mode, connection is released after each transaction

### 1.7 Useful Commands

```bash
# Reload configuration (no restart needed)
psql -U postgres -h localhost -p 6432 pgbouncer -c "RELOAD;"

# Pause all connections
psql -U postgres -h localhost -p 6432 pgbouncer -c "PAUSE;"

# Resume connections
psql -U postgres -h localhost -p 6432 pgbouncer -c "RESUME;"

# View logs
tail -f /var/log/pgbouncer/pgbouncer.log

# Restart service
systemctl restart pgbouncer
```

---

## Part 2: Pgpool-II Setup & Demo

### 2.1 Prerequisites

Ensure you have:
- Primary PostgreSQL: 192.168.44.128
- Standby PostgreSQL: 192.168.44.129 (streaming replication configured)

### 2.2 Installation

**Run the setup script:**
```bash
./pgpool_setup.sh 192.168.44.128 192.168.44.129
```

**With custom options:**
```bash
./pgpool_setup.sh 192.168.44.128 192.168.44.129 -d /var/lib/pgsql/17/data
```

### 2.3 Verify Installation

**Check service status:**
```bash
systemctl status pgpool
```

**Check listening port:**
```bash
ss -tlnp | grep 9999
```

### 2.4 Check Pool Nodes

**Connect via Pgpool:**
```bash
psql -U postgres -h localhost -p 9999 postgres
```

**Show pool nodes:**
```sql
SHOW pool_nodes;
```

**Expected output:**
```
 node_id |    hostname    | port | status | pg_status | lb_weight |  role   | pg_role
---------+----------------+------+--------+-----------+-----------+---------+---------
 0       | 192.168.44.128 | 5432 | up     | up        | 0.500000  | primary | primary
 1       | 192.168.44.129 | 5432 | up     | up        | 0.500000  | standby | standby
```

**Key columns:**
- `status`: up/down - Pgpool's view
- `pg_status`: up/down - PostgreSQL actual status
- `role`: primary/standby - Pgpool assigned role
- `lb_weight`: Load balancing weight (0.5 = 50%)

### 2.5 Test Load Balancing

**Run multiple SELECT queries:**
```bash
for i in {1..10}; do
  psql -U postgres -h localhost -p 9999 -t -c "SELECT inet_server_addr();" postgres
done
```

**Expected output (distributed between primary and standby):**
```
 192.168.44.128
 192.168.44.129
 192.168.44.128
 192.168.44.129
 ...
```

### 2.6 Test Write Routing

**Write queries always go to primary:**
```bash
psql -U postgres -h localhost -p 9999 postgres -c "
  CREATE TABLE test_write (id serial, data text);
  INSERT INTO test_write (data) VALUES ('test');
  SELECT inet_server_addr();
"
```

**Expected:** Always returns primary IP (192.168.44.128)

### 2.7 Performance Test

**Initialize pgbench:**
```bash
pgbench -i -s 10 -U postgres -h localhost -p 9999 postgres
```

**Run read/write test:**
```bash
pgbench -c 10 -t 100 -U postgres -h localhost -p 9999 postgres
```

**Run read-only test (load balanced):**
```bash
pgbench -c 10 -t 100 -S -U postgres -h localhost -p 9999 postgres
```

### 2.8 Monitoring Commands

**Show pool status:**
```sql
SHOW pool_status;
```

**Show pool processes:**
```sql
SHOW pool_processes;
```

**Show pool pools:**
```sql
SHOW pool_pools;
```

**Show pool version:**
```sql
SHOW pool_version;
```

### 2.9 PCP Commands (Pgpool Control)

```bash
# Show node info
pcp_node_info -h localhost -p 9898 -U postgres -w 0
pcp_node_info -h localhost -p 9898 -U postgres -w 1

# Show pool status
pcp_pool_status -h localhost -p 9898 -U postgres

# Attach a node
pcp_attach_node -h localhost -p 9898 -U postgres -w 0

# Detach a node
pcp_detach_node -h localhost -p 9898 -U postgres -w 1
```

---

## Part 3: Patroni HA Cluster Setup & Demo

### 3.1 Prerequisites

**Three servers:**
- lab01: 192.168.44.132
- lab02: 192.168.44.133
- lab03: 192.168.44.130
- VIP: 192.168.44.140

### 3.2 Setup Passwordless SSH

**Run from the control machine (lab01):**
```bash
./ssh_setup.sh 192.168.44.132 192.168.44.133 192.168.44.130
```

**Verify:**
```bash
ssh lab01 hostname
ssh lab02 hostname
ssh lab03 hostname
```

### 3.3 Install Patroni Cluster

**Run the setup script:**
```bash
./patroni_ha_setup.sh 192.168.44.132 192.168.44.133 192.168.44.130 192.168.44.140
```

**With PostgreSQL 18:**
```bash
./patroni_ha_setup.sh 192.168.44.132 192.168.44.133 192.168.44.130 192.168.44.140 -v 18
```

**With custom network interface:**
```bash
./patroni_ha_setup.sh 192.168.44.132 192.168.44.133 192.168.44.130 192.168.44.140 -i eth0
```

### 3.4 Verify Cluster Status

**Check Patroni cluster:**
```bash
patronictl -c /etc/patroni/patroni.yml list
```

**Expected output:**
```
+ Cluster: postgres -------+----+-----------+
| Member |      Host      | Role    | State     |
+--------+----------------+---------+-----------+
| lab01  | 192.168.44.132 | Leader  | running   |
| lab02  | 192.168.44.133 | Replica | streaming |
| lab03  | 192.168.44.130 | Replica | streaming |
+--------+----------------+---------+-----------+
```

### 3.5 Verify etcd Cluster

```bash
etcdctl endpoint status \
  --endpoints=192.168.44.132:2379,192.168.44.133:2379,192.168.44.130:2379 \
  --write-out=table
```

**Expected output:**
```
+---------------------+------------------+---------+---------+-----------+
|      ENDPOINT       |        ID        | VERSION | DB SIZE | IS LEADER |
+---------------------+------------------+---------+---------+-----------+
| 192.168.44.132:2379 | 7896e8429a390c14 |   3.6.6 |   37 kB |     false |
| 192.168.44.133:2379 | 5c3f47589f0be802 |   3.6.6 |   25 kB |     false |
| 192.168.44.130:2379 | c262847557f194ac |   3.6.6 |   37 kB |      true |
+---------------------+------------------+---------+---------+-----------+
```

### 3.6 Verify VIP

**Check which node has VIP:**
```bash
for node in lab01 lab02 lab03; do
  echo -n "$node: "
  ssh $node "ip addr show | grep 192.168.44.140" 2>/dev/null && echo "HAS VIP" || echo "no vip"
done
```

### 3.7 Test VIP Connection

**Connect to primary via VIP:**
```bash
psql -h 192.168.44.140 -p 5000 -U postgres -c "SELECT inet_server_addr(), pg_is_in_recovery();"
```

**Expected output:**
```
 inet_server_addr | pg_is_in_recovery 
------------------+-------------------
 192.168.44.132   | f
```

**Connect to standby via VIP:**
```bash
psql -h 192.168.44.140 -p 5001 -U postgres -c "SELECT inet_server_addr(), pg_is_in_recovery();"
```

**Expected output:**
```
 inet_server_addr | pg_is_in_recovery 
------------------+-------------------
 192.168.44.133   | t
```

### 3.8 Check Replication Status

**On primary:**
```bash
psql -h 192.168.44.140 -p 5000 -U postgres -c "
  SELECT client_addr, state, sent_lsn, replay_lsn,
         pg_wal_lsn_diff(sent_lsn, replay_lsn) as lag_bytes
  FROM pg_stat_replication;
"
```

**Expected output:**
```
  client_addr   |   state   |  sent_lsn   | replay_lsn  | lag_bytes 
----------------+-----------+-------------+-------------+-----------
 192.168.44.133 | streaming | 0/5054CC0   | 0/5054CC0   |         0
 192.168.44.130 | streaming | 0/5054CC0   | 0/5054CC0   |         0
```

### 3.9 HAProxy Stats

**Open in browser:**
```
http://192.168.44.140:7000/
```

This shows:
- Backend servers status (UP/DOWN)
- Active connections
- Request statistics

### 3.10 Patroni REST API

**Check leader:**
```bash
curl -s http://192.168.44.132:8008/leader | jq
```

**Check replica:**
```bash
curl -s http://192.168.44.133:8008/replica | jq
```

**Check cluster:**
```bash
curl -s http://192.168.44.132:8008/cluster | jq
```

---

## Part 4: Patroni Failover Testing

### 4.1 Launch Testing Tool

```bash
./patroni_failover_test.sh 192.168.44.132 192.168.44.133 192.168.44.130 192.168.44.140
```

### 4.2 Main Menu

```
===============================================================================
           PATRONI FAILOVER TESTING & RECOVERY
===============================================================================

  Cluster Leader: lab01

  1. Failure Tests      (14 scenarios)
  2. Status & Health    (cluster status, VIP, health check)
  3. Recovery - Start   (start services)
  4. Recovery - Stop    (stop services)
  5. Recovery - Fix     (iptables, reinit)

  q. Quit
```

### 4.3 Status & Health Menu (Option 2)

```
  1. Show Cluster Status (patronictl list)
  2. Test VIP Connection
  3. Full Health Check
  4. Show etcd Status
  5. Show Replication Lag
  6. Show Service Status (all nodes)
```

**Demo: Full Health Check (Option 3)**

This provides a comprehensive view of your cluster:
- Service status on all nodes (etcd, keepalived, haproxy, patroni)
- iptables status (clean or blocked)
- etcd cluster status
- Patroni cluster status
- Replication lag
- VIP location
- VIP connection test

### 4.4 Failure Tests Menu (Option 1)

#### Test 1: Planned Switchover

**Purpose:** Graceful leadership transition

**Steps:**
1. Select option `1` from Failure Tests menu
2. Confirm switchover

**What happens:**
```
Before:
| lab01  | Leader  | running   |
| lab02  | Replica | streaming |
| lab03  | Replica | streaming |

After:
| lab01  | Replica | streaming |
| lab02  | Leader  | running   |  ← New Leader
| lab03  | Replica | streaming |
```

**Recovery:** Automatic (no action needed)

---

#### Test 2: Stop Patroni Service on Leader

**Purpose:** Simulate Patroni service crash

**Steps:**
1. Select option `2` from Failure Tests menu
2. Watch automatic failover

**What happens:**
1. Patroni stops on leader
2. Leader lock in etcd expires (30 seconds)
3. New leader elected
4. HAProxy detects change

**Recovery:** 
- Automatic (Patroni restarts itself)
- Or manual: Menu → 3 → 5 (Start Patroni)

---

#### Test 3: Kill PostgreSQL Process

**Purpose:** Simulate PostgreSQL crash

**Steps:**
1. Select option `3` from Failure Tests menu

**What happens:**
1. PostgreSQL killed with SIGKILL
2. Patroni detects PostgreSQL is down
3. Patroni attempts to restart PostgreSQL
4. If restart fails, failover occurs

**Recovery:** Automatic (Patroni restarts PostgreSQL)

---

#### Test 4: Network Isolation

**Purpose:** Simulate complete network failure on leader

**Steps:**
1. Select option `4` from Failure Tests menu

**What happens:**
1. All network traffic blocked on leader (iptables)
2. Leader cannot communicate with etcd or other nodes
3. Leader lock expires
4. New leader elected from remaining nodes

**Recovery:** 
- Menu → 5 → 1 (Fix Network - Clear iptables all nodes)

---

#### Test 5: Stop etcd on Leader

**Purpose:** Test etcd failure on leader node

**Steps:**
1. Select option `5` from Failure Tests menu

**What happens:**
1. etcd stops on leader
2. Leader loses connection to DCS
3. Leader demotes itself
4. New leader elected

**Recovery:**
- Menu → 3 → 6 (Start etcd)

---

#### Test 6: Simulate Disk Full

**Purpose:** Demonstrate disk full scenario (informational)

**Steps:**
1. Select option `6` from Failure Tests menu

**Note:** This is a safe simulation - creates small test file and cleans up.

---

#### Test 7: Kill Patroni Process (SIGKILL)

**Purpose:** Hard kill of Patroni process

**Steps:**
1. Select option `7` from Failure Tests menu

**What happens:**
1. Patroni killed immediately
2. Watchdog may trigger (if configured)
3. Or leader lock expires and failover occurs

**Recovery:**
- Menu → 3 → 5 (Start Patroni)

---

#### Test 8: Stop HAProxy

**Purpose:** Test load balancer failure

**Steps:**
1. Select option `8` from Failure Tests menu

**What happens:**
1. HAProxy stops on VIP holder
2. Keepalived detects HAProxy failure
3. VIP moves to another node with working HAProxy

**Recovery:**
- Menu → 3 → 7 (Start HAProxy)

---

#### Test 9: Stop Keepalived

**Purpose:** Test VIP failover

**Steps:**
1. Select option `9` from Failure Tests menu

**What happens:**
1. Keepalived stops on VIP holder
2. VRRP advertisements stop
3. Backup node takes over VIP

**Recovery:**
- Menu → 3 → 8 (Start Keepalived)

---

#### Test 10: Full Node Shutdown

**Purpose:** Simulate complete server failure

**Steps:**
1. Select option `10` from Failure Tests menu

**What happens:**
1. All services stop on leader (patroni, haproxy, keepalived, etcd)
2. etcd cluster continues with 2 nodes
3. New leader elected
4. VIP moves

**Recovery:**
- Menu → 3 → 1 (Start all services on all nodes)
- Or Menu → 3 → 2/3/4 (Start specific node)

---

#### Test 11: Split Brain Test

**Purpose:** Test etcd isolation (partial network failure)

**Steps:**
1. Select option `11` from Failure Tests menu

**What happens:**
1. Only etcd traffic blocked on leader
2. Leader can still reach PostgreSQL replicas
3. But cannot reach etcd
4. Leader demotes itself (cannot maintain lock)
5. New leader elected

**Key insight:** This demonstrates split-brain prevention:
- Leader CANNOT accept writes without etcd confirmation
- Prevents two primaries scenario

**Recovery:**
- Menu → 5 → 1 (Fix Network - Clear iptables)

---

#### Test 12: Cascade Failure

**Purpose:** Multiple sequential failures

**Steps:**
1. Select option `12` from Failure Tests menu

**What happens:**
1. First leader fails → Second node becomes leader
2. Second leader fails → Third node becomes leader
3. Cluster runs with single node (degraded but functional)

**Recovery:**
- Menu → 3 → 1 (Start all services on all nodes)

---

#### Test 13: Watchdog Test

**Purpose:** Test fencing mechanism (informational)

**Steps:**
1. Select option `13` from Failure Tests menu

**Note:** This shows watchdog configuration. In production, watchdog reboots the node if Patroni hangs.

---

#### Test 14: Recovery Test

**Purpose:** Verify failed node can rejoin cluster

**Steps:**
1. Select option `14` from Failure Tests menu

**What happens:**
1. Patroni stops on a replica
2. Patroni restarts
3. Node rejoins as replica
4. Replication resumes

---

### 4.5 Recovery Menu (Option 3 - Start)

```
  Start ALL services:
    1. All nodes (lab01, lab02, lab03)
    2. lab01 only
    3. lab02 only
    4. lab03 only

  Start specific service (all nodes):
    5. Start Patroni
    6. Start etcd
    7. Start HAProxy
    8. Start Keepalived
```

**Service start order (automatic):**
1. etcd (wait 2s)
2. Keepalived (wait 1s)
3. HAProxy (wait 1s)
4. Patroni

---

### 4.6 Recovery Menu (Option 4 - Stop)

Same structure as Start menu but stops services.

**Service stop order (automatic):**
1. Patroni
2. HAProxy
3. Keepalived
4. etcd

---

### 4.7 Fix Issues Menu (Option 5)

```
  1. Fix Network - Clear iptables (all nodes)
  2. Fix Network - Clear iptables (lab01)
  3. Fix Network - Clear iptables (lab02)
  4. Fix Network - Clear iptables (lab03)

  5. Reinitialize Failed Node
  6. Restart Failed Node (full restart)
```

**Reinitialize Node (Option 5):**
- Erases PostgreSQL data
- Rejoins cluster as fresh replica
- Use when node is corrupted or out of sync

---

## Cleanup Procedures

### Remove PgBouncer
```bash
./pgbouncer_cleanup.sh
```

### Remove Pgpool-II
```bash
./pgpool_cleanup.sh
```

### Remove Patroni Cluster
```bash
./patroni_cleanup.sh 192.168.44.132 192.168.44.133 192.168.44.130
```

---

## Troubleshooting

### PgBouncer Issues

**Connection refused:**
```bash
# Check service
systemctl status pgbouncer

# Check logs
tail -f /var/log/pgbouncer/pgbouncer.log

# Check config
cat /etc/pgbouncer/pgbouncer.ini
```

**Authentication failed:**
```bash
# Check userlist
cat /etc/pgbouncer/userlist.txt

# Regenerate password hash
echo "\"postgres\" \"$(echo -n 'postgrespostgres' | md5sum | cut -d' ' -f1 | sed 's/^/md5/')\"" 
```

---

### Pgpool-II Issues

**Pool nodes showing down:**
```bash
# Check PostgreSQL connectivity
psql -h 192.168.44.128 -U postgres -c "SELECT 1;"

# Check Pgpool logs
journalctl -u pgpool -f

# Check pool_hba.conf
cat /etc/pgpool-II/pool_hba.conf
```

**Permission denied errors:**
```bash
# Fix directories
mkdir -p /var/run/pgpool-II /run/postgresql
chown postgres:postgres /var/run/pgpool-II /run/postgresql
```

---

### Patroni Issues

**Cluster not forming:**
```bash
# Check etcd
etcdctl endpoint health --endpoints=192.168.44.132:2379

# Check Patroni logs
journalctl -u patroni -f

# Check Patroni config
cat /etc/patroni/patroni.yml
```

**patronictl not found:**
```bash
# Create patronictl script
cat > /usr/bin/patronictl << 'EOF'
#!/usr/bin/python3.12
import sys
try:
    from importlib.metadata import distribution
    _distribution = distribution('patroni')
    _ep = _distribution.entry_points[('console_scripts', 'patronictl')]
    _ep.load()()
except Exception:
    from patroni.ctl import ctl
    ctl()
EOF
chmod +x /usr/bin/patronictl
```

**VIP not assigned:**
```bash
# Check Keepalived
systemctl status keepalived

# Check network interface
ip addr show ens33

# Check Keepalived config
cat /etc/keepalived/keepalived.conf
```

**Failover not happening:**
```bash
# Check etcd leader lock
etcdctl get /db/postgres/leader

# Check Patroni logs
journalctl -u patroni -f

# Force failover
patronictl -c /etc/patroni/patroni.yml failover
```

---

## Quick Reference

### Connection Strings

```bash
# PgBouncer
psql -h localhost -p 6432 -U postgres postgres

# Pgpool-II
psql -h localhost -p 9999 -U postgres postgres

# Patroni Primary (via VIP)
psql -h 192.168.44.140 -p 5000 -U postgres postgres

# Patroni Standby (via VIP)
psql -h 192.168.44.140 -p 5001 -U postgres postgres
```

### Service Commands

```bash
# PgBouncer
systemctl start|stop|restart|status pgbouncer

# Pgpool-II
systemctl start|stop|restart|status pgpool

# Patroni
systemctl start|stop|restart|status patroni

# etcd
systemctl start|stop|restart|status etcd

# HAProxy
systemctl start|stop|restart|status haproxy

# Keepalived
systemctl start|stop|restart|status keepalived
```

### Patroni Commands

```bash
# Cluster status
patronictl -c /etc/patroni/patroni.yml list

# Switchover
patronictl -c /etc/patroni/patroni.yml switchover

# Failover
patronictl -c /etc/patroni/patroni.yml failover

# Reinitialize node
patronictl -c /etc/patroni/patroni.yml reinit postgres lab01

# Pause cluster
patronictl -c /etc/patroni/patroni.yml pause

# Resume cluster
patronictl -c /etc/patroni/patroni.yml resume

# Edit config
patronictl -c /etc/patroni/patroni.yml edit-config
```

### Test Commands

```bash
# PgBouncer high concurrency test
pgbench -c 200 -t 10 -S -U postgres -h localhost -p 6432 postgres

# Pgpool load balancing test
for i in {1..10}; do psql -h localhost -p 9999 -t -c "SELECT inet_server_addr();"; done

# Patroni VIP test
psql -h 192.168.44.140 -p 5000 -U postgres -c "SELECT inet_server_addr();"
```

---

## Summary

| Solution | Use Case | Complexity | Features |
|----------|----------|------------|----------|
| **PgBouncer** | Connection pooling | Low | Pooling, lightweight |
| **Pgpool-II** | Pooling + Load Balancing | Medium | Pooling, LB, Failover |
| **Patroni** | Enterprise HA | High | Auto-failover, Consensus |

**Recommended Architecture:**
```
Applications
     │
     ▼
 PgBouncer (connection pooling)
     │
     ▼
  HAProxy (load balancing via VIP)
     │
     ▼
 Patroni Cluster (3 nodes with etcd)
```

This provides:
- Connection pooling (PgBouncer)
- High availability (Patroni)
- Automatic failover (Patroni + etcd)
- Load balancing for reads (HAProxy)
- Single endpoint for applications (VIP)
