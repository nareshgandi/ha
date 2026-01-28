#!/bin/bash
#===============================================================================
# Patroni HA Cluster - Complete Cleanup Script
# Description: Removes all Patroni HA components for fresh testing
# Usage: ./patroni_cleanup.sh <lab01_ip> <lab02_ip> <lab03_ip>
# Example: ./patroni_cleanup.sh 192.168.44.132 192.168.44.133 192.168.44.130
# WARNING: This will DELETE all data! Use with caution.
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Parse Arguments
#-------------------------------------------------------------------------------
if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <lab01_ip> <lab02_ip> <lab03_ip>"
    echo ""
    echo "WARNING: This will completely remove:"
    echo "  - Patroni and PostgreSQL data"
    echo "  - etcd cluster and data"
    echo "  - HAProxy"
    echo "  - Keepalived"
    echo ""
    echo "Example: $0 192.168.44.132 192.168.44.133 192.168.44.130"
    exit 1
fi

LAB01_IP="$1"
LAB02_IP="$2"
LAB03_IP="$3"

#-------------------------------------------------------------------------------
# Color Output
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
declare -A NODES=(
    ["lab01"]="${LAB01_IP}"
    ["lab02"]="${LAB02_IP}"
    ["lab03"]="${LAB03_IP}"
)

SSH_OPTIONS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------
run_on_node() {
    local node=$1
    local ip=${NODES[$node]}
    shift
    ssh ${SSH_OPTIONS} root@${ip} "$@" 2>/dev/null || true
}

run_on_all_nodes() {
    for node in lab01 lab02 lab03; do
        log_info "Running on ${node} (${NODES[$node]})..."
        run_on_node "$node" "$@"
    done
}

#-------------------------------------------------------------------------------
# Confirmation
#-------------------------------------------------------------------------------
confirm_cleanup() {
    echo "==============================================================================="
    echo "                    PATRONI HA CLUSTER CLEANUP"
    echo "==============================================================================="
    echo ""
    echo "This will COMPLETELY REMOVE the following from all 3 nodes:"
    echo "  - Patroni service and configuration"
    echo "  - PostgreSQL data directory (/u01/pgsql/*)"
    echo "  - etcd service and data"
    echo "  - HAProxy service and configuration"
    echo "  - Keepalived service and configuration"
    echo ""
    echo "Nodes:"
    echo "  - lab01: ${LAB01_IP}"
    echo "  - lab02: ${LAB02_IP}"
    echo "  - lab03: ${LAB03_IP}"
    echo ""
    log_warning "THIS ACTION CANNOT BE UNDONE!"
    echo ""
    read -p "Are you sure you want to proceed? (type 'YES' to confirm): " confirm
    
    if [[ "$confirm" != "YES" ]]; then
        log_info "Cleanup cancelled."
        exit 0
    fi
    echo ""
}

#-------------------------------------------------------------------------------
# Stop Services
#-------------------------------------------------------------------------------
stop_services() {
    log_info "Stopping all services on all nodes..."
    
    run_on_all_nodes "
        systemctl stop patroni 2>/dev/null || true
        systemctl stop haproxy 2>/dev/null || true
        systemctl stop keepalived 2>/dev/null || true
        systemctl stop etcd 2>/dev/null || true
        
        systemctl disable patroni 2>/dev/null || true
        systemctl disable haproxy 2>/dev/null || true
        systemctl disable keepalived 2>/dev/null || true
        systemctl disable etcd 2>/dev/null || true
    "
    
    log_success "Services stopped"
}

#-------------------------------------------------------------------------------
# Remove Patroni
#-------------------------------------------------------------------------------
remove_patroni() {
    log_info "Removing Patroni..."
    
    run_on_all_nodes "
        # Stop any remaining postgres processes
        pkill -9 postgres 2>/dev/null || true
        pkill -9 patroni 2>/dev/null || true
        
        # Remove packages
        dnf remove -y patroni patroni-etcd 2>/dev/null || true
        
        # Remove configuration
        rm -rf /etc/patroni
        
        # Remove data directory
        rm -rf /u01/pgsql
        
        # Remove socket directory
        rm -rf /run/postgresql/*
        
        # Remove patronictl
        rm -f /usr/bin/patronictl
    "
    
    log_success "Patroni removed"
}

#-------------------------------------------------------------------------------
# Remove etcd
#-------------------------------------------------------------------------------
remove_etcd() {
    log_info "Removing etcd..."
    
    run_on_all_nodes "
        # Remove package
        dnf remove -y etcd 2>/dev/null || true
        
        # Remove data
        rm -rf /var/lib/etcd
        
        # Remove configuration
        rm -f /etc/etcd/etcd.conf
        rm -f /etc/etcd/etcd.conf.orig
    "
    
    log_success "etcd removed"
}

#-------------------------------------------------------------------------------
# Remove HAProxy
#-------------------------------------------------------------------------------
remove_haproxy() {
    log_info "Removing HAProxy..."
    
    run_on_all_nodes "
        # Remove package
        dnf remove -y haproxy 2>/dev/null || true
        
        # Remove configuration
        rm -f /etc/haproxy/haproxy.cfg
        rm -f /etc/haproxy/haproxy.cfg.orig
    "
    
    log_success "HAProxy removed"
}

#-------------------------------------------------------------------------------
# Remove Keepalived
#-------------------------------------------------------------------------------
remove_keepalived() {
    log_info "Removing Keepalived..."
    
    run_on_all_nodes "
        # Remove package
        dnf remove -y keepalived 2>/dev/null || true
        
        # Remove configuration
        rm -f /etc/keepalived/keepalived.conf
        rm -f /etc/keepalived/keepalived.conf.orig
        
        # Remove sysctl entries (optional - comment out if you want to keep)
        sed -i '/net.ipv4.ip_nonlocal_bind/d' /etc/sysctl.conf 2>/dev/null || true
        sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf 2>/dev/null || true
        sysctl -p 2>/dev/null || true
    "
    
    log_success "Keepalived removed"
}

#-------------------------------------------------------------------------------
# Remove Watchdog
#-------------------------------------------------------------------------------
remove_watchdog() {
    log_info "Removing Watchdog..."
    
    run_on_all_nodes "
        dnf remove -y watchdog 2>/dev/null || true
        rm -f /dev/watchdog 2>/dev/null || true
        rmmod softdog 2>/dev/null || true
    "
    
    log_success "Watchdog removed"
}

#-------------------------------------------------------------------------------
# Cleanup Remaining Files
#-------------------------------------------------------------------------------
cleanup_remaining() {
    log_info "Cleaning up remaining files..."
    
    run_on_all_nodes "
        # Remove backup files
        rm -f /etc/hosts.backup.* 2>/dev/null || true
        
        # Remove tmpfiles
        rm -f /etc/tmpfiles.d/pgpool-II.conf 2>/dev/null || true
        
        # Clean up /etc/hosts entries (optional)
        # sed -i '/lab01/d; /lab02/d; /lab03/d; /ha-vip/d' /etc/hosts 2>/dev/null || true
    "
    
    log_success "Cleanup complete"
}

#-------------------------------------------------------------------------------
# Verify Cleanup
#-------------------------------------------------------------------------------
verify_cleanup() {
    log_info "Verifying cleanup..."
    
    echo ""
    for node in lab01 lab02 lab03; do
        echo "=== ${node} ==="
        run_on_node "$node" "
            echo 'Services:'
            systemctl is-active patroni 2>/dev/null || echo '  patroni: not running'
            systemctl is-active etcd 2>/dev/null || echo '  etcd: not running'
            systemctl is-active haproxy 2>/dev/null || echo '  haproxy: not running'
            systemctl is-active keepalived 2>/dev/null || echo '  keepalived: not running'
            echo ''
            echo 'Data directories:'
            [ -d /u01/pgsql ] && echo '  /u01/pgsql: EXISTS (WARNING!)' || echo '  /u01/pgsql: removed'
            [ -d /var/lib/etcd ] && echo '  /var/lib/etcd: EXISTS (WARNING!)' || echo '  /var/lib/etcd: removed'
            echo ''
        "
    done
    
    log_success "Verification complete"
}

#-------------------------------------------------------------------------------
# Print Summary
#-------------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "==============================================================================="
    echo "                    CLEANUP COMPLETE"
    echo "==============================================================================="
    echo ""
    echo "All Patroni HA components have been removed from:"
    echo "  - lab01: ${LAB01_IP}"
    echo "  - lab02: ${LAB02_IP}"
    echo "  - lab03: ${LAB03_IP}"
    echo ""
    echo "You can now re-run the setup script:"
    echo "  ./patroni_ha_setup.sh ${LAB01_IP} ${LAB02_IP} ${LAB03_IP} <VIP>"
    echo ""
    echo "==============================================================================="
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    confirm_cleanup
    stop_services
    remove_patroni
    remove_etcd
    remove_haproxy
    remove_keepalived
    remove_watchdog
    cleanup_remaining
    verify_cleanup
    print_summary
}

main
