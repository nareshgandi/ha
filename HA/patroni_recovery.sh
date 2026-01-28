#!/bin/bash
#===============================================================================
# Patroni Service Recovery Script
# Description: Start/restart stopped services on Patroni cluster nodes
# Usage: ./patroni_recovery.sh <lab01_ip> <lab02_ip> <lab03_ip> [action] [node]
# Example: ./patroni_recovery.sh 192.168.44.132 192.168.44.133 192.168.44.130
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Parse Arguments
#-------------------------------------------------------------------------------
if [[ $# -lt 3 ]]; then
    echo "==============================================================================="
    echo "           PATRONI SERVICE RECOVERY SCRIPT"
    echo "==============================================================================="
    echo ""
    echo "Usage: $0 <lab01_ip> <lab02_ip> <lab03_ip> [action] [node]"
    echo ""
    echo "Arguments:"
    echo "  lab01_ip       IP address of lab01"
    echo "  lab02_ip       IP address of lab02"
    echo "  lab03_ip       IP address of lab03"
    echo "  action         (Optional) Action to perform"
    echo "  node           (Optional) Specific node (lab01, lab02, lab03, or all)"
    echo ""
    echo "Actions:"
    echo "  status         Check status of all services (default)"
    echo "  start          Start all stopped services"
    echo "  stop           Stop all services"
    echo "  restart        Restart all services"
    echo "  start-patroni  Start Patroni only"
    echo "  start-etcd     Start etcd only"
    echo "  start-haproxy  Start HAProxy only"
    echo "  start-keepalived Start Keepalived only"
    echo "  fix-network    Clear iptables rules"
    echo "  reinit         Reinitialize a failed node"
    echo "  health         Full health check"
    echo ""
    echo "Examples:"
    echo "  $0 192.168.44.132 192.168.44.133 192.168.44.130                    # Status check"
    echo "  $0 192.168.44.132 192.168.44.133 192.168.44.130 start              # Start all on all nodes"
    echo "  $0 192.168.44.132 192.168.44.133 192.168.44.130 start lab01        # Start all on lab01"
    echo "  $0 192.168.44.132 192.168.44.133 192.168.44.130 start-patroni all  # Start Patroni on all"
    echo "  $0 192.168.44.132 192.168.44.133 192.168.44.130 restart lab02      # Restart all on lab02"
    echo "  $0 192.168.44.132 192.168.44.133 192.168.44.130 reinit lab01       # Reinitialize lab01"
    exit 1
fi

LAB01_IP="$1"
LAB02_IP="$2"
LAB03_IP="$3"
ACTION="${4:-status}"
TARGET_NODE="${5:-all}"

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

#-------------------------------------------------------------------------------
# Color Output
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
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

get_target_nodes() {
    if [[ "$TARGET_NODE" == "all" ]]; then
        echo "lab01 lab02 lab03"
    else
        echo "$TARGET_NODE"
    fi
}

print_header() {
    echo ""
    echo "==============================================================================="
    echo "  $1"
    echo "==============================================================================="
    echo ""
}

#-------------------------------------------------------------------------------
# Status Check
#-------------------------------------------------------------------------------
check_status() {
    print_header "SERVICE STATUS CHECK"
    
    for node in lab01 lab02 lab03; do
        echo "=== ${node} (${NODES[$node]}) ==="
        echo ""
        
        # Check each service
        for service in etcd keepalived haproxy patroni; do
            local status=$(run_on_node "$node" "systemctl is-active ${service} 2>/dev/null" || echo "inactive")
            if [[ "$status" == "active" ]]; then
                echo -e "  ${service}: ${GREEN}${status}${NC}"
            else
                echo -e "  ${service}: ${RED}${status}${NC}"
            fi
        done
        
        # Check PostgreSQL
        local pg_status=$(run_on_node "$node" "pgrep -x postgres > /dev/null && echo 'running' || echo 'stopped'")
        if [[ "$pg_status" == "running" ]]; then
            echo -e "  postgresql: ${GREEN}${pg_status}${NC}"
        else
            echo -e "  postgresql: ${RED}${pg_status}${NC}"
        fi
        
        # Check iptables rules
        local iptables_count=$(run_on_node "$node" "iptables -L -n | grep -c DROP" || echo "0")
        if [[ "$iptables_count" -gt 0 ]]; then
            echo -e "  iptables: ${YELLOW}${iptables_count} DROP rules${NC}"
        else
            echo -e "  iptables: ${GREEN}clean${NC}"
        fi
        
        echo ""
    done
    
    # Show Patroni cluster status
    echo "=== PATRONI CLUSTER STATUS ==="
    echo ""
    for node in lab01 lab02 lab03; do
        run_on_node "$node" "patronictl -c ${PATRONI_CONFIG} list 2>/dev/null" && break
    done || echo "Unable to get cluster status"
    echo ""
}

#-------------------------------------------------------------------------------
# Health Check
#-------------------------------------------------------------------------------
health_check() {
    print_header "FULL HEALTH CHECK"
    
    local issues=0
    
    # Check etcd cluster
    echo "=== ETCD CLUSTER ==="
    local etcd_endpoints="${LAB01_IP}:2379,${LAB02_IP}:2379,${LAB03_IP}:2379"
    run_on_node "lab01" "etcdctl endpoint health --endpoints=${etcd_endpoints}" || {
        log_error "etcd cluster unhealthy"
        ((issues++))
    }
    echo ""
    
    # Check Patroni cluster
    echo "=== PATRONI CLUSTER ==="
    local cluster_ok=false
    for node in lab01 lab02 lab03; do
        if run_on_node "$node" "patronictl -c ${PATRONI_CONFIG} list 2>/dev/null | grep -q Leader"; then
            cluster_ok=true
            run_on_node "$node" "patronictl -c ${PATRONI_CONFIG} list"
            break
        fi
    done
    if [[ "$cluster_ok" == "false" ]]; then
        log_error "No Patroni leader found"
        ((issues++))
    fi
    echo ""
    
    # Check VIP
    echo "=== VIP STATUS ==="
    local vip_found=false
    for node in lab01 lab02 lab03; do
        if run_on_node "$node" "ip addr show | grep -q '192.168'"; then
            local vip=$(run_on_node "$node" "ip addr show | grep -oP 'inet \K192\.168\.\d+\.\d+' | tail -1")
            if [[ -n "$vip" ]]; then
                echo "VIP on ${node}: $vip"
                vip_found=true
            fi
        fi
    done
    if [[ "$vip_found" == "false" ]]; then
        log_warning "VIP might not be configured"
    fi
    echo ""
    
    # Check replication
    echo "=== REPLICATION STATUS ==="
    for node in lab01 lab02 lab03; do
        local is_leader=$(run_on_node "$node" "patronictl -c ${PATRONI_CONFIG} list 2>/dev/null | grep ${node} | grep -q Leader && echo yes || echo no")
        if [[ "$is_leader" == "yes" ]]; then
            run_on_node "$node" "
                export PGPASSWORD='postgres'
                psql -U postgres -c \"SELECT client_addr, state, sent_lsn, replay_lsn FROM pg_stat_replication;\" 2>/dev/null
            " || echo "Unable to check replication"
            break
        fi
    done
    echo ""
    
    # Summary
    if [[ $issues -eq 0 ]]; then
        log_success "Health check passed - no issues found"
    else
        log_error "Health check found ${issues} issue(s)"
    fi
}

#-------------------------------------------------------------------------------
# Start Services
#-------------------------------------------------------------------------------
start_all_services() {
    local nodes=$(get_target_nodes)
    
    print_header "STARTING ALL SERVICES"
    
    for node in $nodes; do
        log_step "Starting services on ${node}..."
        
        # Clear any iptables rules first
        run_on_node "$node" "iptables -F 2>/dev/null || true"
        
        # Start services in correct order
        log_info "  Starting etcd..."
        run_on_node "$node" "systemctl start etcd 2>/dev/null || true"
        sleep 2
        
        log_info "  Starting keepalived..."
        run_on_node "$node" "systemctl start keepalived 2>/dev/null || true"
        sleep 1
        
        log_info "  Starting haproxy..."
        run_on_node "$node" "systemctl start haproxy 2>/dev/null || true"
        sleep 1
        
        log_info "  Starting patroni..."
        run_on_node "$node" "systemctl start patroni 2>/dev/null || true"
        
        log_success "${node} services started"
    done
    
    log_info "Waiting for cluster to stabilize..."
    sleep 15
    
    check_status
}

start_patroni() {
    local nodes=$(get_target_nodes)
    
    print_header "STARTING PATRONI"
    
    for node in $nodes; do
        log_step "Starting Patroni on ${node}..."
        run_on_node "$node" "systemctl start patroni"
        
        local status=$(run_on_node "$node" "systemctl is-active patroni")
        if [[ "$status" == "active" ]]; then
            log_success "Patroni started on ${node}"
        else
            log_error "Failed to start Patroni on ${node}"
        fi
    done
    
    sleep 10
    check_status
}

start_etcd() {
    local nodes=$(get_target_nodes)
    
    print_header "STARTING ETCD"
    
    for node in $nodes; do
        log_step "Starting etcd on ${node}..."
        run_on_node "$node" "systemctl start etcd"
        
        local status=$(run_on_node "$node" "systemctl is-active etcd")
        if [[ "$status" == "active" ]]; then
            log_success "etcd started on ${node}"
        else
            log_error "Failed to start etcd on ${node}"
        fi
    done
    
    sleep 5
    
    # Verify etcd cluster
    log_info "Verifying etcd cluster..."
    local etcd_endpoints="${LAB01_IP}:2379,${LAB02_IP}:2379,${LAB03_IP}:2379"
    run_on_node "lab01" "etcdctl endpoint status --endpoints=${etcd_endpoints} --write-out=table" || true
}

start_haproxy() {
    local nodes=$(get_target_nodes)
    
    print_header "STARTING HAPROXY"
    
    for node in $nodes; do
        log_step "Starting HAProxy on ${node}..."
        run_on_node "$node" "systemctl start haproxy"
        
        local status=$(run_on_node "$node" "systemctl is-active haproxy")
        if [[ "$status" == "active" ]]; then
            log_success "HAProxy started on ${node}"
        else
            log_error "Failed to start HAProxy on ${node}"
        fi
    done
}

start_keepalived() {
    local nodes=$(get_target_nodes)
    
    print_header "STARTING KEEPALIVED"
    
    for node in $nodes; do
        log_step "Starting Keepalived on ${node}..."
        run_on_node "$node" "systemctl start keepalived"
        
        local status=$(run_on_node "$node" "systemctl is-active keepalived")
        if [[ "$status" == "active" ]]; then
            log_success "Keepalived started on ${node}"
        else
            log_error "Failed to start Keepalived on ${node}"
        fi
    done
    
    sleep 5
    
    # Check VIP
    log_info "Checking VIP assignment..."
    for node in lab01 lab02 lab03; do
        local has_vip=$(run_on_node "$node" "ip addr show | grep -c '192.168' || echo 0")
        if [[ "$has_vip" -gt 1 ]]; then
            log_success "VIP is on ${node}"
        fi
    done
}

#-------------------------------------------------------------------------------
# Stop Services
#-------------------------------------------------------------------------------
stop_all_services() {
    local nodes=$(get_target_nodes)
    
    print_header "STOPPING ALL SERVICES"
    
    for node in $nodes; do
        log_step "Stopping services on ${node}..."
        
        # Stop in reverse order
        run_on_node "$node" "systemctl stop patroni 2>/dev/null || true"
        run_on_node "$node" "systemctl stop haproxy 2>/dev/null || true"
        run_on_node "$node" "systemctl stop keepalived 2>/dev/null || true"
        run_on_node "$node" "systemctl stop etcd 2>/dev/null || true"
        
        log_success "${node} services stopped"
    done
}

#-------------------------------------------------------------------------------
# Restart Services
#-------------------------------------------------------------------------------
restart_all_services() {
    local nodes=$(get_target_nodes)
    
    print_header "RESTARTING ALL SERVICES"
    
    for node in $nodes; do
        log_step "Restarting services on ${node}..."
        
        run_on_node "$node" "
            systemctl restart etcd
            sleep 2
            systemctl restart keepalived
            sleep 1
            systemctl restart haproxy
            sleep 1
            systemctl restart patroni
        "
        
        log_success "${node} services restarted"
    done
    
    log_info "Waiting for cluster to stabilize..."
    sleep 15
    
    check_status
}

#-------------------------------------------------------------------------------
# Fix Network (Clear iptables)
#-------------------------------------------------------------------------------
fix_network() {
    local nodes=$(get_target_nodes)
    
    print_header "FIXING NETWORK (CLEARING IPTABLES)"
    
    for node in $nodes; do
        log_step "Clearing iptables on ${node}..."
        run_on_node "$node" "
            iptables -F
            iptables -X
            iptables -P INPUT ACCEPT
            iptables -P OUTPUT ACCEPT
            iptables -P FORWARD ACCEPT
        "
        log_success "${node} iptables cleared"
    done
}

#-------------------------------------------------------------------------------
# Reinitialize Node
#-------------------------------------------------------------------------------
reinit_node() {
    if [[ "$TARGET_NODE" == "all" ]]; then
        log_error "Cannot reinit all nodes. Specify a single node."
        exit 1
    fi
    
    local node=$TARGET_NODE
    
    print_header "REINITIALIZING NODE: ${node}"
    
    log_warning "This will erase all PostgreSQL data on ${node}!"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Cancelled."
        return
    fi
    
    # Find a healthy node to run patronictl
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
        exit 1
    fi
    
    log_step "Stopping Patroni on ${node}..."
    run_on_node "$node" "systemctl stop patroni 2>/dev/null || true"
    
    log_step "Removing PostgreSQL data on ${node}..."
    run_on_node "$node" "rm -rf /u01/pgsql/17/* /u01/pgsql/18/* 2>/dev/null || true"
    
    log_step "Reinitializing ${node} via patronictl..."
    run_on_node "$healthy_node" "patronictl -c ${PATRONI_CONFIG} reinit postgres ${node} --force" || {
        log_warning "patronictl reinit failed, trying manual start..."
    }
    
    log_step "Starting Patroni on ${node}..."
    run_on_node "$node" "systemctl start patroni"
    
    log_info "Waiting for node to sync..."
    sleep 30
    
    check_status
}

#-------------------------------------------------------------------------------
# Interactive Menu
#-------------------------------------------------------------------------------
show_menu() {
    while true; do
        print_header "PATRONI RECOVERY - INTERACTIVE MENU"
        
        echo "Current Status (quick view):"
        for node in lab01 lab02 lab03; do
            local patroni=$(run_on_node "$node" "systemctl is-active patroni 2>/dev/null" || echo "?")
            local etcd=$(run_on_node "$node" "systemctl is-active etcd 2>/dev/null" || echo "?")
            printf "  %-6s: patroni=%-8s etcd=%-8s\n" "$node" "$patroni" "$etcd"
        done
        
        echo ""
        echo "Actions:"
        echo "  1. Check full status"
        echo "  2. Start all services (all nodes)"
        echo "  3. Start all services (specific node)"
        echo "  4. Start Patroni only"
        echo "  5. Start etcd only"
        echo "  6. Start HAProxy only"
        echo "  7. Start Keepalived only"
        echo "  8. Stop all services"
        echo "  9. Restart all services"
        echo "  10. Fix network (clear iptables)"
        echo "  11. Reinitialize failed node"
        echo "  12. Full health check"
        echo "  q. Quit"
        echo ""
        read -p "Select action: " choice
        
        case $choice in
            1)  check_status ;;
            2)  TARGET_NODE="all"; start_all_services ;;
            3)  
                read -p "Enter node (lab01/lab02/lab03): " TARGET_NODE
                start_all_services
                ;;
            4)  
                read -p "Enter node (lab01/lab02/lab03/all): " TARGET_NODE
                start_patroni
                ;;
            5)  
                read -p "Enter node (lab01/lab02/lab03/all): " TARGET_NODE
                start_etcd
                ;;
            6)  
                read -p "Enter node (lab01/lab02/lab03/all): " TARGET_NODE
                start_haproxy
                ;;
            7)  
                read -p "Enter node (lab01/lab02/lab03/all): " TARGET_NODE
                start_keepalived
                ;;
            8)  
                read -p "Enter node (lab01/lab02/lab03/all): " TARGET_NODE
                stop_all_services
                ;;
            9)  
                read -p "Enter node (lab01/lab02/lab03/all): " TARGET_NODE
                restart_all_services
                ;;
            10) 
                read -p "Enter node (lab01/lab02/lab03/all): " TARGET_NODE
                fix_network
                ;;
            11) 
                read -p "Enter node to reinit (lab01/lab02/lab03): " TARGET_NODE
                reinit_node
                ;;
            12) health_check ;;
            q|Q) exit 0 ;;
            *)  log_error "Invalid option" ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    echo "==============================================================================="
    echo "           PATRONI SERVICE RECOVERY"
    echo "==============================================================================="
    echo ""
    echo "Nodes:"
    echo "  - lab01: ${LAB01_IP}"
    echo "  - lab02: ${LAB02_IP}"
    echo "  - lab03: ${LAB03_IP}"
    echo ""
    
    case $ACTION in
        status)          check_status ;;
        start)           start_all_services ;;
        stop)            stop_all_services ;;
        restart)         restart_all_services ;;
        start-patroni)   start_patroni ;;
        start-etcd)      start_etcd ;;
        start-haproxy)   start_haproxy ;;
        start-keepalived) start_keepalived ;;
        fix-network)     fix_network ;;
        reinit)          reinit_node ;;
        health)          health_check ;;
        menu)            show_menu ;;
        *)               
            log_error "Unknown action: $ACTION"
            exit 1
            ;;
    esac
}

main
