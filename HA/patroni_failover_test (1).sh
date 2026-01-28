#!/bin/bash
#===============================================================================
# Patroni Failover Testing Script
# Description: Comprehensive failure scenarios and testing for Patroni HA cluster
# Usage: ./patroni_failover_test.sh <lab01_ip> <lab02_ip> <lab03_ip> <vip>
# Example: ./patroni_failover_test.sh 192.168.44.132 192.168.44.133 192.168.44.130 192.168.44.140
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Parse Arguments
#-------------------------------------------------------------------------------
if [[ $# -lt 4 ]]; then
    echo "==============================================================================="
    echo "           PATRONI FAILOVER TESTING SCRIPT"
    echo "==============================================================================="
    echo ""
    echo "Usage: $0 <lab01_ip> <lab02_ip> <lab03_ip> <vip> [test_number]"
    echo ""
    echo "Arguments:"
    echo "  lab01_ip       IP address of lab01"
    echo "  lab02_ip       IP address of lab02"
    echo "  lab03_ip       IP address of lab03"
    echo "  vip            Virtual IP address"
    echo "  test_number    (Optional) Run specific test only (1-10)"
    echo ""
    echo "Available Tests:"
    echo "  1.  Planned Switchover"
    echo "  2.  Stop Patroni Service on Leader"
    echo "  3.  Kill PostgreSQL Process on Leader"
    echo "  4.  Network Isolation (iptables block)"
    echo "  5.  Stop etcd on Leader Node"
    echo "  6.  Simulate Disk Full (PostgreSQL crash)"
    echo "  7.  Kill Patroni Process (SIGKILL)"
    echo "  8.  Stop HAProxy"
    echo "  9.  Stop Keepalived (VIP failover)"
    echo "  10. Full Node Shutdown"
    echo "  11. Split Brain Test"
    echo "  12. Cascade Failure (Multiple nodes)"
    echo "  13. Watchdog Test"
    echo "  14. Recovery Test (Rejoin failed node)"
    echo "  all Run all tests sequentially"
    echo ""
    echo "Examples:"
    echo "  $0 192.168.44.132 192.168.44.133 192.168.44.130 192.168.44.140"
    echo "  $0 192.168.44.132 192.168.44.133 192.168.44.130 192.168.44.140 1"
    echo "  $0 192.168.44.132 192.168.44.133 192.168.44.130 192.168.44.140 all"
    exit 1
fi

LAB01_IP="$1"
LAB02_IP="$2"
LAB03_IP="$3"
VIP="$4"
TEST_NUMBER="${5:-menu}"

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
declare -A NODES=(
    ["lab01"]="${LAB01_IP}"
    ["lab02"]="${LAB02_IP}"
    ["lab03"]="${LAB03_IP}"
)

SSH_OPTIONS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
PATRONI_CONFIG="/etc/patroni/patroni.yml"
POSTGRES_PASSWORD="postgres"

#-------------------------------------------------------------------------------
# Color Output
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_test()    { echo -e "${MAGENTA}[TEST]${NC} $1"; }
log_step()    { echo -e "${CYAN}[STEP]${NC} $1"; }

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------
run_on_node() {
    local node=$1
    local ip=${NODES[$node]}
    shift
    ssh ${SSH_OPTIONS} root@${ip} "$@" 2>/dev/null
}

get_leader() {
    for node in lab01 lab02 lab03; do
        local role=$(run_on_node "$node" "patronictl -c ${PATRONI_CONFIG} list 2>/dev/null | grep -E 'Leader|running' | grep Leader | awk '{print \$2}'" 2>/dev/null)
        if [[ -n "$role" ]]; then
            echo "$role"
            return
        fi
    done
}

get_leader_ip() {
    local leader=$(get_leader)
    if [[ -n "$leader" ]]; then
        echo "${NODES[$leader]}"
    fi
}

show_cluster_status() {
    log_info "Current Cluster Status:"
    echo ""
    for node in lab01 lab02 lab03; do
        run_on_node "$node" "patronictl -c ${PATRONI_CONFIG} list 2>/dev/null" && break
    done || echo "Unable to get cluster status"
    echo ""
}

wait_for_failover() {
    local old_leader=$1
    local timeout=${2:-60}
    local elapsed=0
    
    log_info "Waiting for failover (timeout: ${timeout}s)..."
    
    while [[ $elapsed -lt $timeout ]]; do
        sleep 5
        elapsed=$((elapsed + 5))
        
        local new_leader=$(get_leader)
        if [[ -n "$new_leader" && "$new_leader" != "$old_leader" ]]; then
            log_success "Failover complete! New leader: $new_leader (took ${elapsed}s)"
            return 0
        fi
        echo -n "."
    done
    
    echo ""
    log_error "Failover timeout after ${timeout}s"
    return 1
}

wait_for_cluster_healthy() {
    local timeout=${1:-120}
    local elapsed=0
    
    log_info "Waiting for cluster to become healthy (timeout: ${timeout}s)..."
    
    while [[ $elapsed -lt $timeout ]]; do
        sleep 5
        elapsed=$((elapsed + 5))
        
        local streaming_count=0
        for node in lab01 lab02 lab03; do
            local status=$(run_on_node "$node" "patronictl -c ${PATRONI_CONFIG} list 2>/dev/null | grep -c 'streaming\|running'" 2>/dev/null || echo "0")
            if [[ "$status" -ge 3 ]]; then
                log_success "Cluster healthy (took ${elapsed}s)"
                return 0
            fi
        done
        echo -n "."
    done
    
    echo ""
    log_warning "Cluster may not be fully healthy after ${timeout}s"
    return 1
}

test_vip_connection() {
    log_info "Testing VIP connection..."
    export PGPASSWORD="${POSTGRES_PASSWORD}"
    
    if psql -h ${VIP} -p 5000 -U postgres -c "SELECT 1;" &>/dev/null; then
        local server=$(psql -h ${VIP} -p 5000 -U postgres -t -c "SELECT inet_server_addr();" 2>/dev/null | tr -d ' ')
        log_success "VIP connection working (connected to: $server)"
        return 0
    else
        log_error "VIP connection failed"
        return 1
    fi
}

print_separator() {
    echo ""
    echo "==============================================================================="
    echo ""
}

restore_node() {
    local node=$1
    log_step "Restoring ${node}..."
    
    run_on_node "$node" "
        iptables -F 2>/dev/null || true
        systemctl start etcd 2>/dev/null || true
        sleep 2
        systemctl start keepalived 2>/dev/null || true
        systemctl start haproxy 2>/dev/null || true
        systemctl start patroni 2>/dev/null || true
    "
    
    log_success "${node} restored"
}

start_all_on_node() {
    local node=$1
    log_step "Starting all services on ${node}..."
    
    run_on_node "$node" "
        iptables -F 2>/dev/null || true
        systemctl start etcd 2>/dev/null || true
        sleep 2
        systemctl start keepalived 2>/dev/null || true
        sleep 1
        systemctl start haproxy 2>/dev/null || true
        sleep 1
        systemctl start patroni 2>/dev/null || true
    "
    
    log_success "${node} services started"
}

full_health_check() {
    print_separator
    log_info "=== FULL HEALTH CHECK ==="
    print_separator
    
    # Check services on each node
    echo "SERVICE STATUS:"
    echo ""
    for node in lab01 lab02 lab03; do
        echo "--- ${node} (${NODES[$node]}) ---"
        for service in etcd keepalived haproxy patroni; do
            local status=$(run_on_node "$node" "systemctl is-active ${service} 2>/dev/null" || echo "inactive")
            if [[ "$status" == "active" ]]; then
                echo -e "  ${service}: ${GREEN}active${NC}"
            else
                echo -e "  ${service}: ${RED}${status}${NC}"
            fi
        done
        
        # Check iptables
        local ipt=$(run_on_node "$node" "iptables -L -n 2>/dev/null | grep -c DROP || echo 0" | head -1)
        if [[ "$ipt" -gt 0 ]] 2>/dev/null; then
            echo -e "  iptables: ${YELLOW}${ipt} DROP rules${NC}"
        else
            echo -e "  iptables: ${GREEN}clean${NC}"
        fi
        echo ""
    done
    
    # Check etcd cluster
    echo "ETCD CLUSTER:"
    local etcd_endpoints="${LAB01_IP}:2379,${LAB02_IP}:2379,${LAB03_IP}:2379"
    run_on_node "lab01" "etcdctl endpoint status --endpoints=${etcd_endpoints} --write-out=table 2>/dev/null" || echo "Unable to check etcd"
    echo ""
    
    # Check Patroni cluster
    echo "PATRONI CLUSTER:"
    show_cluster_status
    
    # Check replication
    echo "REPLICATION STATUS:"
    local leader=$(get_leader)
    if [[ -n "$leader" ]]; then
        run_on_node "$leader" "
            export PGPASSWORD='${POSTGRES_PASSWORD}'
            psql -U postgres -c \"SELECT client_addr, state, sent_lsn, replay_lsn, 
                   pg_wal_lsn_diff(sent_lsn, replay_lsn) as lag_bytes 
                   FROM pg_stat_replication;\" 2>/dev/null
        " || echo "Unable to check replication"
    else
        echo "No leader found"
    fi
    echo ""
    
    # Check VIP
    echo "VIP STATUS:"
    for node in lab01 lab02 lab03; do
        if run_on_node "$node" "ip addr show | grep -q '${VIP}'"; then
            echo -e "  VIP (${VIP}) is on: ${GREEN}${node}${NC}"
        fi
    done
    echo ""
    
    # Test VIP connection
    test_vip_connection
}

reinit_failed_node() {
    local node=$1
    
    if [[ -z "$node" || ! "${NODES[$node]+isset}" ]]; then
        log_error "Invalid node: $node. Use lab01, lab02, or lab03"
        return 1
    fi
    
    print_separator
    log_warning "REINITIALIZE NODE: ${node}"
    log_warning "This will ERASE all PostgreSQL data on ${node}!"
    print_separator
    
    read -p "Are you sure? (y/N): " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Cancelled."
        return
    fi
    
    # Find a healthy node
    local healthy_node=""
    for n in lab01 lab02 lab03; do
        if [[ "$n" != "$node" ]]; then
            local status=$(run_on_node "$n" "systemctl is-active patroni" || echo "inactive")
            if [[ "$status" == "active" ]]; then
                healthy_node=$n
                break
            fi
        fi
    done
    
    if [[ -z "$healthy_node" ]]; then
        log_error "No healthy node found to run reinit"
        return 1
    fi
    
    log_step "Stopping Patroni on ${node}..."
    run_on_node "$node" "systemctl stop patroni 2>/dev/null || true"
    
    log_step "Clearing PostgreSQL data on ${node}..."
    run_on_node "$node" "rm -rf /u01/pgsql/17/* /u01/pgsql/18/* 2>/dev/null || true"
    
    log_step "Reinitializing ${node} via patronictl on ${healthy_node}..."
    run_on_node "$healthy_node" "patronictl -c ${PATRONI_CONFIG} reinit postgres ${node} --force 2>/dev/null" || {
        log_warning "patronictl reinit command completed (may show errors)"
    }
    
    log_step "Starting Patroni on ${node}..."
    run_on_node "$node" "systemctl start patroni"
    
    log_info "Waiting for node to sync (30 seconds)..."
    sleep 30
    
    show_cluster_status
    log_success "Reinit complete for ${node}"
}

#-------------------------------------------------------------------------------
# Test 1: Planned Switchover
#-------------------------------------------------------------------------------
test_planned_switchover() {
    print_separator
    log_test "TEST 1: Planned Switchover"
    echo "Description: Graceful switchover using patronictl"
    echo "Expected: Zero downtime, clean transition"
    print_separator
    
    show_cluster_status
    
    local current_leader=$(get_leader)
    log_info "Current leader: $current_leader"
    
    # Find a replica to switch to
    local target=""
    for node in lab01 lab02 lab03; do
        if [[ "$node" != "$current_leader" ]]; then
            target=$node
            break
        fi
    done
    
    log_step "Initiating switchover to ${target}..."
    
    run_on_node "$current_leader" "patronictl -c ${PATRONI_CONFIG} switchover --leader ${current_leader} --candidate ${target} --force"
    
    sleep 10
    show_cluster_status
    
    local new_leader=$(get_leader)
    if [[ "$new_leader" == "$target" ]]; then
        log_success "TEST 1 PASSED: Switchover to ${target} successful"
    else
        log_error "TEST 1 FAILED: Expected leader ${target}, got ${new_leader}"
    fi
    
    test_vip_connection
}

#-------------------------------------------------------------------------------
# Test 2: Stop Patroni Service on Leader
#-------------------------------------------------------------------------------
test_stop_patroni_service() {
    print_separator
    log_test "TEST 2: Stop Patroni Service on Leader"
    echo "Description: Simulate Patroni service crash"
    echo "Expected: Automatic failover within 30 seconds"
    print_separator
    
    show_cluster_status
    
    local leader=$(get_leader)
    local leader_ip=$(get_leader_ip)
    log_info "Current leader: $leader ($leader_ip)"
    
    log_step "Stopping Patroni service on ${leader}..."
    run_on_node "$leader" "systemctl stop patroni"
    
    wait_for_failover "$leader" 60
    
    show_cluster_status
    test_vip_connection
    
    log_step "Restarting Patroni on ${leader}..."
    run_on_node "$leader" "systemctl start patroni"
    
    sleep 15
    show_cluster_status
    
    log_success "TEST 2 COMPLETED"
}

#-------------------------------------------------------------------------------
# Test 3: Kill PostgreSQL Process on Leader
#-------------------------------------------------------------------------------
test_kill_postgresql() {
    print_separator
    log_test "TEST 3: Kill PostgreSQL Process on Leader"
    echo "Description: Simulate PostgreSQL crash (SIGKILL)"
    echo "Expected: Patroni detects and either restarts or triggers failover"
    print_separator
    
    show_cluster_status
    
    local leader=$(get_leader)
    log_info "Current leader: $leader"
    
    log_step "Killing PostgreSQL process on ${leader}..."
    run_on_node "$leader" "pkill -9 postgres"
    
    log_info "Waiting 30 seconds for Patroni to detect and respond..."
    sleep 30
    
    show_cluster_status
    test_vip_connection
    
    log_success "TEST 3 COMPLETED"
}

#-------------------------------------------------------------------------------
# Test 4: Network Isolation (iptables block)
#-------------------------------------------------------------------------------
test_network_isolation() {
    print_separator
    log_test "TEST 4: Network Isolation"
    echo "Description: Block all network traffic to leader node"
    echo "Expected: Cluster detects isolation, elects new leader"
    print_separator
    
    show_cluster_status
    
    local leader=$(get_leader)
    local leader_ip=$(get_leader_ip)
    log_info "Current leader: $leader ($leader_ip)"
    
    log_warning "This test will isolate ${leader} from the network"
    log_step "Blocking network on ${leader}..."
    
    # Block incoming connections except SSH
    run_on_node "$leader" "
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT
        iptables -A INPUT -p tcp --dport 2379 -j DROP
        iptables -A INPUT -p tcp --dport 2380 -j DROP
        iptables -A INPUT -p tcp --dport 5432 -j DROP
        iptables -A INPUT -p tcp --dport 8008 -j DROP
        iptables -A OUTPUT -p tcp --dport 2379 -j DROP
        iptables -A OUTPUT -p tcp --dport 2380 -j DROP
    "
    
    log_info "Network isolated. Waiting for failover..."
    wait_for_failover "$leader" 90
    
    show_cluster_status
    
    log_step "Restoring network on ${leader}..."
    run_on_node "$leader" "iptables -F"
    
    sleep 15
    show_cluster_status
    test_vip_connection
    
    log_success "TEST 4 COMPLETED"
}

#-------------------------------------------------------------------------------
# Test 5: Stop etcd on Leader Node
#-------------------------------------------------------------------------------
test_stop_etcd_leader() {
    print_separator
    log_test "TEST 5: Stop etcd on Leader Node"
    echo "Description: Stop etcd service on the current Patroni leader"
    echo "Expected: Leader demotes itself (cannot maintain lock)"
    print_separator
    
    show_cluster_status
    
    local leader=$(get_leader)
    log_info "Current leader: $leader"
    
    log_step "Stopping etcd on ${leader}..."
    run_on_node "$leader" "systemctl stop etcd"
    
    log_info "Waiting for cluster to respond..."
    sleep 30
    
    show_cluster_status
    
    log_step "Restarting etcd on ${leader}..."
    run_on_node "$leader" "systemctl start etcd"
    
    sleep 15
    show_cluster_status
    test_vip_connection
    
    log_success "TEST 5 COMPLETED"
}

#-------------------------------------------------------------------------------
# Test 6: Simulate Disk Full
#-------------------------------------------------------------------------------
test_disk_full() {
    print_separator
    log_test "TEST 6: Simulate Disk Full (PostgreSQL WAL failure)"
    echo "Description: Fill up disk space causing PostgreSQL to fail"
    echo "Expected: PostgreSQL crashes, failover occurs"
    print_separator
    
    show_cluster_status
    
    local leader=$(get_leader)
    log_info "Current leader: $leader"
    
    log_warning "Creating large file to simulate disk pressure..."
    log_step "Creating 100MB file in PostgreSQL data directory..."
    
    run_on_node "$leader" "dd if=/dev/zero of=/u01/pgsql/17/test_disk_full.tmp bs=1M count=100 2>/dev/null || true"
    
    log_info "Attempting to trigger checkpoint failure..."
    run_on_node "$leader" "
        export PGPASSWORD='${POSTGRES_PASSWORD}'
        psql -U postgres -c 'CHECKPOINT;' 2>/dev/null || true
    "
    
    sleep 10
    show_cluster_status
    
    log_step "Cleaning up test file..."
    run_on_node "$leader" "rm -f /u01/pgsql/17/test_disk_full.tmp"
    
    test_vip_connection
    
    log_success "TEST 6 COMPLETED"
}

#-------------------------------------------------------------------------------
# Test 7: Kill Patroni Process (SIGKILL)
#-------------------------------------------------------------------------------
test_kill_patroni() {
    print_separator
    log_test "TEST 7: Kill Patroni Process (SIGKILL)"
    echo "Description: Hard kill of Patroni process"
    echo "Expected: Watchdog triggers, system reboots or failover occurs"
    print_separator
    
    show_cluster_status
    
    local leader=$(get_leader)
    log_info "Current leader: $leader"
    
    log_warning "Killing Patroni process with SIGKILL..."
    log_step "Executing: pkill -9 patroni on ${leader}"
    
    run_on_node "$leader" "pkill -9 patroni"
    
    log_info "Waiting for watchdog/failover response..."
    wait_for_failover "$leader" 90
    
    show_cluster_status
    
    log_step "Restarting Patroni on ${leader}..."
    run_on_node "$leader" "systemctl start patroni"
    
    sleep 20
    show_cluster_status
    test_vip_connection
    
    log_success "TEST 7 COMPLETED"
}

#-------------------------------------------------------------------------------
# Test 8: Stop HAProxy
#-------------------------------------------------------------------------------
test_stop_haproxy() {
    print_separator
    log_test "TEST 8: Stop HAProxy"
    echo "Description: Stop HAProxy on the VIP holder"
    echo "Expected: Keepalived detects failure, moves VIP to another node"
    print_separator
    
    show_cluster_status
    
    log_info "Finding node holding VIP..."
    local vip_node=""
    for node in lab01 lab02 lab03; do
        if run_on_node "$node" "ip addr show | grep -q ${VIP}"; then
            vip_node=$node
            break
        fi
    done
    
    if [[ -z "$vip_node" ]]; then
        log_error "Could not find VIP holder"
        return 1
    fi
    
    log_info "VIP is on: $vip_node"
    
    log_step "Stopping HAProxy on ${vip_node}..."
    run_on_node "$vip_node" "systemctl stop haproxy"
    
    log_info "Waiting for VIP failover (Keepalived)..."
    sleep 15
    
    # Check where VIP moved
    local new_vip_node=""
    for node in lab01 lab02 lab03; do
        if run_on_node "$node" "ip addr show | grep -q ${VIP}"; then
            new_vip_node=$node
            break
        fi
    done
    
    if [[ "$new_vip_node" != "$vip_node" ]]; then
        log_success "VIP moved from ${vip_node} to ${new_vip_node}"
    else
        log_warning "VIP did not move (might be configured differently)"
    fi
    
    test_vip_connection
    
    log_step "Restarting HAProxy on ${vip_node}..."
    run_on_node "$vip_node" "systemctl start haproxy"
    
    sleep 10
    test_vip_connection
    
    log_success "TEST 8 COMPLETED"
}

#-------------------------------------------------------------------------------
# Test 9: Stop Keepalived (VIP failover)
#-------------------------------------------------------------------------------
test_stop_keepalived() {
    print_separator
    log_test "TEST 9: Stop Keepalived (VIP failover)"
    echo "Description: Stop Keepalived to test VIP migration"
    echo "Expected: VIP moves to backup node"
    print_separator
    
    log_info "Finding node holding VIP..."
    local vip_node=""
    for node in lab01 lab02 lab03; do
        if run_on_node "$node" "ip addr show | grep -q ${VIP}"; then
            vip_node=$node
            break
        fi
    done
    
    log_info "VIP is currently on: $vip_node"
    
    log_step "Stopping Keepalived on ${vip_node}..."
    run_on_node "$vip_node" "systemctl stop keepalived"
    
    log_info "Waiting for VIP migration..."
    sleep 10
    
    # Check where VIP moved
    local new_vip_node=""
    for node in lab01 lab02 lab03; do
        if run_on_node "$node" "ip addr show | grep -q ${VIP}"; then
            new_vip_node=$node
            break
        fi
    done
    
    if [[ -n "$new_vip_node" ]]; then
        log_success "VIP is now on: ${new_vip_node}"
    else
        log_error "VIP not found on any node!"
    fi
    
    test_vip_connection
    
    log_step "Restarting Keepalived on ${vip_node}..."
    run_on_node "$vip_node" "systemctl start keepalived"
    
    sleep 10
    
    log_success "TEST 9 COMPLETED"
}

#-------------------------------------------------------------------------------
# Test 10: Full Node Shutdown
#-------------------------------------------------------------------------------
test_full_node_shutdown() {
    print_separator
    log_test "TEST 10: Full Node Shutdown"
    echo "Description: Complete shutdown of the leader node"
    echo "Expected: Cluster continues with 2 nodes, automatic failover"
    print_separator
    
    show_cluster_status
    
    local leader=$(get_leader)
    log_info "Current leader: $leader"
    
    log_warning "This will stop ALL services on ${leader}"
    log_step "Stopping all services on ${leader}..."
    
    run_on_node "$leader" "
        systemctl stop patroni
        systemctl stop haproxy
        systemctl stop keepalived
        systemctl stop etcd
    "
    
    log_info "Waiting for failover..."
    wait_for_failover "$leader" 90
    
    show_cluster_status
    test_vip_connection
    
    log_step "Restarting all services on ${leader}..."
    run_on_node "$leader" "
        systemctl start etcd
        sleep 5
        systemctl start keepalived
        systemctl start haproxy
        systemctl start patroni
    "
    
    log_info "Waiting for node to rejoin..."
    sleep 30
    
    show_cluster_status
    wait_for_cluster_healthy 120
    
    log_success "TEST 10 COMPLETED"
}

#-------------------------------------------------------------------------------
# Test 11: Split Brain Test
#-------------------------------------------------------------------------------
test_split_brain() {
    print_separator
    log_test "TEST 11: Split Brain Test"
    echo "Description: Isolate leader from etcd but not from replicas"
    echo "Expected: Leader demotes (cannot maintain etcd lock)"
    print_separator
    
    show_cluster_status
    
    local leader=$(get_leader)
    log_info "Current leader: $leader"
    
    log_warning "Blocking etcd communication on ${leader}..."
    
    run_on_node "$leader" "
        iptables -A INPUT -p tcp --dport 2379 -j DROP
        iptables -A INPUT -p tcp --dport 2380 -j DROP
        iptables -A OUTPUT -p tcp --dport 2379 -j DROP
        iptables -A OUTPUT -p tcp --dport 2380 -j DROP
    "
    
    log_info "Leader is now isolated from etcd..."
    log_info "Waiting for leader to demote (TTL expiry)..."
    
    sleep 45
    
    show_cluster_status
    
    log_step "Restoring etcd communication on ${leader}..."
    run_on_node "$leader" "iptables -F"
    
    sleep 20
    show_cluster_status
    test_vip_connection
    
    log_success "TEST 11 COMPLETED"
}

#-------------------------------------------------------------------------------
# Test 12: Cascade Failure (Multiple nodes)
#-------------------------------------------------------------------------------
test_cascade_failure() {
    print_separator
    log_test "TEST 12: Cascade Failure"
    echo "Description: Fail primary, then fail new primary"
    echo "Expected: Third node becomes leader"
    print_separator
    
    show_cluster_status
    
    # First failure
    local leader1=$(get_leader)
    log_info "First leader: $leader1"
    
    log_step "Stopping Patroni on ${leader1}..."
    run_on_node "$leader1" "systemctl stop patroni"
    
    wait_for_failover "$leader1" 60
    
    # Second failure
    local leader2=$(get_leader)
    log_info "Second leader: $leader2"
    
    log_step "Stopping Patroni on ${leader2}..."
    run_on_node "$leader2" "systemctl stop patroni"
    
    wait_for_failover "$leader2" 60
    
    local leader3=$(get_leader)
    log_info "Third leader: $leader3"
    
    show_cluster_status
    test_vip_connection
    
    # Restore nodes
    log_step "Restoring failed nodes..."
    run_on_node "$leader1" "systemctl start patroni"
    sleep 10
    run_on_node "$leader2" "systemctl start patroni"
    
    sleep 30
    show_cluster_status
    
    log_success "TEST 12 COMPLETED"
}

#-------------------------------------------------------------------------------
# Test 13: Watchdog Test
#-------------------------------------------------------------------------------
test_watchdog() {
    print_separator
    log_test "TEST 13: Watchdog Test"
    echo "Description: Test watchdog functionality"
    echo "Expected: Watchdog prevents split-brain by fencing failed leader"
    print_separator
    
    show_cluster_status
    
    local leader=$(get_leader)
    log_info "Current leader: $leader"
    
    log_info "Checking watchdog configuration..."
    run_on_node "$leader" "
        echo 'Watchdog device:'
        ls -la /dev/watchdog 2>/dev/null || echo 'Not found'
        echo ''
        echo 'Patroni watchdog config:'
        grep -A3 'watchdog:' ${PATRONI_CONFIG} 2>/dev/null || echo 'Not configured'
    "
    
    log_warning "Watchdog test requires careful handling"
    log_info "In production, watchdog would reboot the node if Patroni hangs"
    
    log_success "TEST 13 COMPLETED (informational)"
}

#-------------------------------------------------------------------------------
# Test 14: Recovery Test (Rejoin failed node)
#-------------------------------------------------------------------------------
test_recovery() {
    print_separator
    log_test "TEST 14: Recovery Test"
    echo "Description: Verify failed node can rejoin cluster"
    echo "Expected: Node rejoins as replica and syncs data"
    print_separator
    
    show_cluster_status
    
    local leader=$(get_leader)
    
    # Find a replica
    local replica=""
    for node in lab01 lab02 lab03; do
        if [[ "$node" != "$leader" ]]; then
            replica=$node
            break
        fi
    done
    
    log_info "Testing recovery of: $replica"
    
    log_step "Stopping Patroni on ${replica}..."
    run_on_node "$replica" "systemctl stop patroni"
    
    sleep 10
    show_cluster_status
    
    log_step "Corrupting replica data (removing recovery.signal)..."
    run_on_node "$replica" "rm -f /u01/pgsql/17/recovery.signal 2>/dev/null || true"
    
    log_step "Starting Patroni on ${replica}..."
    run_on_node "$replica" "systemctl start patroni"
    
    log_info "Waiting for replica to rejoin and sync..."
    sleep 30
    
    show_cluster_status
    
    # Verify replica is streaming
    local status=$(run_on_node "$leader" "
        export PGPASSWORD='${POSTGRES_PASSWORD}'
        psql -U postgres -t -c \"SELECT state FROM pg_stat_replication WHERE client_addr = '${NODES[$replica]}'\" 2>/dev/null
    " | tr -d ' ')
    
    if [[ "$status" == "streaming" ]]; then
        log_success "Replica ${replica} successfully rejoined and is streaming"
    else
        log_warning "Replica status: $status"
    fi
    
    log_success "TEST 14 COMPLETED"
}

#-------------------------------------------------------------------------------
# Run All Tests
#-------------------------------------------------------------------------------
run_all_tests() {
    log_warning "Running ALL tests sequentially. This will take a while..."
    echo ""
    read -p "Are you sure? (y/N): " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Cancelled."
        return
    fi
    
    test_planned_switchover
    sleep 30
    
    test_stop_patroni_service
    sleep 30
    
    test_kill_postgresql
    sleep 30
    
    test_network_isolation
    sleep 30
    
    test_stop_etcd_leader
    sleep 30
    
    test_kill_patroni
    sleep 30
    
    test_stop_haproxy
    sleep 30
    
    test_stop_keepalived
    sleep 30
    
    test_full_node_shutdown
    sleep 30
    
    test_split_brain
    sleep 30
    
    test_cascade_failure
    sleep 30
    
    test_watchdog
    
    test_recovery
    
    print_separator
    log_success "ALL TESTS COMPLETED"
    show_cluster_status
}

#-------------------------------------------------------------------------------
# Interactive Menu
#-------------------------------------------------------------------------------
show_main_menu() {
    clear
    echo "==============================================================================="
    echo "           PATRONI FAILOVER TESTING & RECOVERY"
    echo "==============================================================================="
    echo ""
    
    # Quick status line
    local leader=$(get_leader 2>/dev/null || echo "unknown")
    echo -e "  Cluster Leader: ${GREEN}${leader}${NC}"
    echo ""
    
    echo "  1. Failure Tests      (14 scenarios)"
    echo "  2. Status & Health    (cluster status, VIP, health check)"
    echo "  3. Recovery - Start   (start services)"
    echo "  4. Recovery - Stop    (stop services)"
    echo "  5. Recovery - Fix     (iptables, reinit)"
    echo ""
    echo "  q. Quit"
    echo ""
    read -p "Select menu [1-5, q]: " choice
    
    case $choice in
        1) show_failure_menu ;;
        2) show_status_menu ;;
        3) show_start_menu ;;
        4) show_stop_menu ;;
        5) show_fix_menu ;;
        q|Q) exit 0 ;;
        *) log_error "Invalid option" ;;
    esac
    
    show_main_menu
}

show_failure_menu() {
    clear
    echo "==============================================================================="
    echo "           FAILURE TESTS"
    echo "==============================================================================="
    echo ""
    show_cluster_status
    echo ""
    echo "  1.  Planned Switchover"
    echo "  2.  Stop Patroni Service on Leader"
    echo "  3.  Kill PostgreSQL Process"
    echo "  4.  Network Isolation (iptables)"
    echo "  5.  Stop etcd on Leader"
    echo "  6.  Simulate Disk Full"
    echo "  7.  Kill Patroni (SIGKILL)"
    echo "  8.  Stop HAProxy"
    echo "  9.  Stop Keepalived"
    echo "  10. Full Node Shutdown"
    echo "  11. Split Brain Test"
    echo "  12. Cascade Failure"
    echo "  13. Watchdog Test"
    echo "  14. Recovery Test (Rejoin)"
    echo ""
    echo "  a.  Run ALL Tests"
    echo "  b.  Back to Main Menu"
    echo ""
    read -p "Select test [1-14, a, b]: " choice
    
    case $choice in
        1)  test_planned_switchover ;;
        2)  test_stop_patroni_service ;;
        3)  test_kill_postgresql ;;
        4)  test_network_isolation ;;
        5)  test_stop_etcd_leader ;;
        6)  test_disk_full ;;
        7)  test_kill_patroni ;;
        8)  test_stop_haproxy ;;
        9)  test_stop_keepalived ;;
        10) test_full_node_shutdown ;;
        11) test_split_brain ;;
        12) test_cascade_failure ;;
        13) test_watchdog ;;
        14) test_recovery ;;
        a|A) run_all_tests ;;
        b|B) return ;;
        *) log_error "Invalid option" ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
    show_failure_menu
}

show_status_menu() {
    clear
    echo "==============================================================================="
    echo "           STATUS & HEALTH"
    echo "==============================================================================="
    echo ""
    echo "  1. Show Cluster Status (patronictl list)"
    echo "  2. Test VIP Connection"
    echo "  3. Full Health Check"
    echo "  4. Show etcd Status"
    echo "  5. Show Replication Lag"
    echo "  6. Show Service Status (all nodes)"
    echo ""
    echo "  b. Back to Main Menu"
    echo ""
    read -p "Select [1-6, b]: " choice
    
    case $choice in
        1) show_cluster_status ;;
        2) test_vip_connection ;;
        3) full_health_check ;;
        4) show_etcd_status ;;
        5) show_replication_lag ;;
        6) show_service_status ;;
        b|B) return ;;
        *) log_error "Invalid option" ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
    show_status_menu
}

show_start_menu() {
    clear
    echo "==============================================================================="
    echo "           RECOVERY - START SERVICES"
    echo "==============================================================================="
    echo ""
    echo "  Start ALL services:"
    echo "    1. All nodes (lab01, lab02, lab03)"
    echo "    2. lab01 only"
    echo "    3. lab02 only"
    echo "    4. lab03 only"
    echo ""
    echo "  Start specific service (all nodes):"
    echo "    5. Start Patroni"
    echo "    6. Start etcd"
    echo "    7. Start HAProxy"
    echo "    8. Start Keepalived"
    echo ""
    echo "  b. Back to Main Menu"
    echo ""
    read -p "Select [1-8, b]: " choice
    
    case $choice in
        1)
            log_info "Starting all services on all nodes..."
            for node in lab01 lab02 lab03; do
                start_all_on_node "$node"
            done
            sleep 15
            show_cluster_status
            ;;
        2) start_all_on_node "lab01"; sleep 10; show_cluster_status ;;
        3) start_all_on_node "lab02"; sleep 10; show_cluster_status ;;
        4) start_all_on_node "lab03"; sleep 10; show_cluster_status ;;
        5)
            log_info "Starting Patroni on all nodes..."
            for node in lab01 lab02 lab03; do
                run_on_node "$node" "systemctl start patroni 2>/dev/null || true"
            done
            sleep 15
            show_cluster_status
            ;;
        6)
            log_info "Starting etcd on all nodes..."
            for node in lab01 lab02 lab03; do
                run_on_node "$node" "systemctl start etcd 2>/dev/null || true"
            done
            sleep 10
            show_etcd_status
            ;;
        7)
            log_info "Starting HAProxy on all nodes..."
            for node in lab01 lab02 lab03; do
                run_on_node "$node" "systemctl start haproxy 2>/dev/null || true"
            done
            sleep 5
            log_success "HAProxy started"
            ;;
        8)
            log_info "Starting Keepalived on all nodes..."
            for node in lab01 lab02 lab03; do
                run_on_node "$node" "systemctl start keepalived 2>/dev/null || true"
            done
            sleep 5
            log_success "Keepalived started"
            ;;
        b|B) return ;;
        *) log_error "Invalid option" ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
    show_start_menu
}

show_stop_menu() {
    clear
    echo "==============================================================================="
    echo "           RECOVERY - STOP SERVICES"
    echo "==============================================================================="
    echo ""
    echo "  Stop ALL services:"
    echo "    1. All nodes (lab01, lab02, lab03)"
    echo "    2. lab01 only"
    echo "    3. lab02 only"
    echo "    4. lab03 only"
    echo ""
    echo "  Stop specific service (all nodes):"
    echo "    5. Stop Patroni"
    echo "    6. Stop etcd"
    echo "    7. Stop HAProxy"
    echo "    8. Stop Keepalived"
    echo ""
    echo "  b. Back to Main Menu"
    echo ""
    read -p "Select [1-8, b]: " choice
    
    case $choice in
        1)
            log_warning "Stopping all services on all nodes..."
            for node in lab01 lab02 lab03; do
                stop_all_on_node "$node"
            done
            log_success "All services stopped"
            ;;
        2) stop_all_on_node "lab01" ;;
        3) stop_all_on_node "lab02" ;;
        4) stop_all_on_node "lab03" ;;
        5)
            log_info "Stopping Patroni on all nodes..."
            for node in lab01 lab02 lab03; do
                run_on_node "$node" "systemctl stop patroni 2>/dev/null || true"
            done
            log_success "Patroni stopped"
            ;;
        6)
            log_info "Stopping etcd on all nodes..."
            for node in lab01 lab02 lab03; do
                run_on_node "$node" "systemctl stop etcd 2>/dev/null || true"
            done
            log_success "etcd stopped"
            ;;
        7)
            log_info "Stopping HAProxy on all nodes..."
            for node in lab01 lab02 lab03; do
                run_on_node "$node" "systemctl stop haproxy 2>/dev/null || true"
            done
            log_success "HAProxy stopped"
            ;;
        8)
            log_info "Stopping Keepalived on all nodes..."
            for node in lab01 lab02 lab03; do
                run_on_node "$node" "systemctl stop keepalived 2>/dev/null || true"
            done
            log_success "Keepalived stopped"
            ;;
        b|B) return ;;
        *) log_error "Invalid option" ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
    show_stop_menu
}

show_fix_menu() {
    clear
    echo "==============================================================================="
    echo "           RECOVERY - FIX ISSUES"
    echo "==============================================================================="
    echo ""
    echo "  1. Fix Network - Clear iptables (all nodes)"
    echo "  2. Fix Network - Clear iptables (lab01)"
    echo "  3. Fix Network - Clear iptables (lab02)"
    echo "  4. Fix Network - Clear iptables (lab03)"
    echo ""
    echo "  5. Reinitialize Failed Node"
    echo "  6. Restart Failed Node (full restart)"
    echo ""
    echo "  b. Back to Main Menu"
    echo ""
    read -p "Select [1-6, b]: " choice
    
    case $choice in
        1)
            log_info "Clearing iptables on all nodes..."
            for node in lab01 lab02 lab03; do
                run_on_node "$node" "iptables -F 2>/dev/null || true"
            done
            log_success "iptables cleared on all nodes"
            ;;
        2) run_on_node "lab01" "iptables -F"; log_success "iptables cleared on lab01" ;;
        3) run_on_node "lab02" "iptables -F"; log_success "iptables cleared on lab02" ;;
        4) run_on_node "lab03" "iptables -F"; log_success "iptables cleared on lab03" ;;
        5)
            echo ""
            read -p "Enter node to reinitialize (lab01/lab02/lab03): " node
            reinit_failed_node "$node"
            ;;
        6)
            echo ""
            read -p "Enter node to restart (lab01/lab02/lab03): " node
            if [[ -n "$node" && "${NODES[$node]+isset}" ]]; then
                log_info "Restarting all services on ${node}..."
                stop_all_on_node "$node"
                sleep 5
                start_all_on_node "$node"
                sleep 10
                show_cluster_status
            else
                log_error "Invalid node: $node"
            fi
            ;;
        b|B) return ;;
        *) log_error "Invalid option" ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
    show_fix_menu
}

# Helper functions for status menu
show_etcd_status() {
    log_info "etcd Cluster Status:"
    local etcd_endpoints="${LAB01_IP}:2379,${LAB02_IP}:2379,${LAB03_IP}:2379"
    run_on_node "lab01" "etcdctl endpoint status --endpoints=${etcd_endpoints} --write-out=table 2>/dev/null" || echo "Unable to check etcd"
}

show_replication_lag() {
    log_info "Replication Status:"
    local leader=$(get_leader)
    if [[ -n "$leader" ]]; then
        run_on_node "$leader" "
            export PGPASSWORD='${POSTGRES_PASSWORD}'
            psql -U postgres -c \"SELECT client_addr, state, sent_lsn, replay_lsn, 
                   pg_wal_lsn_diff(sent_lsn, replay_lsn) as lag_bytes 
                   FROM pg_stat_replication;\" 2>/dev/null
        " || echo "Unable to check replication"
    else
        echo "No leader found"
    fi
}

show_service_status() {
    log_info "Service Status on All Nodes:"
    echo ""
    for node in lab01 lab02 lab03; do
        echo "--- ${node} (${NODES[$node]}) ---"
        for service in etcd keepalived haproxy patroni; do
            local status=$(run_on_node "$node" "systemctl is-active ${service} 2>/dev/null" || echo "inactive")
            if [[ "$status" == "active" ]]; then
                echo -e "  ${service}: ${GREEN}active${NC}"
            else
                echo -e "  ${service}: ${RED}${status}${NC}"
            fi
        done
        echo ""
    done
}

stop_all_on_node() {
    local node=$1
    log_step "Stopping all services on ${node}..."
    
    run_on_node "$node" "
        systemctl stop patroni 2>/dev/null || true
        systemctl stop haproxy 2>/dev/null || true
        systemctl stop keepalived 2>/dev/null || true
        systemctl stop etcd 2>/dev/null || true
    "
    
    log_success "${node} services stopped"
}

# Legacy menu function for backward compatibility
show_menu() {
    show_main_menu
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    echo "==============================================================================="
    echo "           PATRONI FAILOVER TESTING SCRIPT"
    echo "==============================================================================="
    echo ""
    echo "Cluster Nodes:"
    echo "  - lab01: ${LAB01_IP}"
    echo "  - lab02: ${LAB02_IP}"
    echo "  - lab03: ${LAB03_IP}"
    echo "  - VIP:   ${VIP}"
    echo ""
    
    case $TEST_NUMBER in
        1)   test_planned_switchover ;;
        2)   test_stop_patroni_service ;;
        3)   test_kill_postgresql ;;
        4)   test_network_isolation ;;
        5)   test_stop_etcd_leader ;;
        6)   test_disk_full ;;
        7)   test_kill_patroni ;;
        8)   test_stop_haproxy ;;
        9)   test_stop_keepalived ;;
        10)  test_full_node_shutdown ;;
        11)  test_split_brain ;;
        12)  test_cascade_failure ;;
        13)  test_watchdog ;;
        14)  test_recovery ;;
        all) run_all_tests ;;
        menu) show_menu ;;
        *)   log_error "Invalid test number: $TEST_NUMBER" ;;
    esac
}

main
