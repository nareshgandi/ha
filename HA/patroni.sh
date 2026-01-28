#!/bin/bash
#===============================================================================
# PostgreSQL HA with Patroni - Automated Setup Script
# Description: Deploys a 3-node PostgreSQL HA cluster with Patroni, etcd,
#              HAProxy, and Keepalived from a single control machine via SSH
# Hostnames: lab01, lab02, lab03
# Usage: ./patroni_ha_setup.sh <lab01_ip> <lab02_ip> <lab03_ip> <vip> [options]
# Example: ./patroni_ha_setup.sh 192.168.44.128 192.168.44.129 192.168.44.130 192.168.44.140
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Parse Arguments
#-------------------------------------------------------------------------------
if [[ $# -lt 4 ]]; then
    echo "Usage: $0 <lab01_ip> <lab02_ip> <lab03_ip> <vip> [options]"
    echo ""
    echo "Arguments:"
    echo "  lab01_ip       IP address of lab01 (first node)"
    echo "  lab02_ip       IP address of lab02 (second node)"
    echo "  lab03_ip       IP address of lab03 (third node)"
    echo "  vip            Virtual IP for HAProxy/Keepalived"
    echo ""
    echo "Options:"
    echo "  -i, --interface IFACE   Network interface (default: ens160)"
    echo "  -v, --pg-version VER    PostgreSQL version: 17 or 18 (default: 17)"
    echo "  -P, --password PASS     PostgreSQL password (default: postgres)"
    echo "  -c, --check             Only run pre-flight checks"
    echo "  --verify                Only verify existing cluster"
    echo "  -h, --help              Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 192.168.44.128 192.168.44.129 192.168.44.130 192.168.44.140"
    echo "  $0 192.168.44.128 192.168.44.129 192.168.44.130 192.168.44.140 -v 18"
    echo "  $0 10.0.0.1 10.0.0.2 10.0.0.3 10.0.0.100 -i eth0 -v 17"
    exit 1
fi

# Required arguments
LAB01_IP="$1"
LAB02_IP="$2"
LAB03_IP="$3"
VIP="$4"
shift 4

# Default values
NETWORK_INTERFACE="ens160"
PG_VERSION="17"
POSTGRES_PASSWORD="postgres"
REPLICATOR_PASSWORD="replicator"
CHECK_ONLY=false
VERIFY_ONLY=false

# Parse optional arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--interface)
            NETWORK_INTERFACE="$2"
            shift 2
            ;;
        -v|--pg-version)
            PG_VERSION="$2"
            shift 2
            ;;
        -P|--password)
            POSTGRES_PASSWORD="$2"
            shift 2
            ;;
        -c|--check)
            CHECK_ONLY=true
            shift
            ;;
        --verify)
            VERIFY_ONLY=true
            shift
            ;;
        -h|--help)
            exec "$0"
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
# Node Configuration
declare -A NODES=(
    ["lab01"]="${LAB01_IP}"
    ["lab02"]="${LAB02_IP}"
    ["lab03"]="${LAB03_IP}"
)

# PostgreSQL Settings
PG_DATA_DIR="/u01/pgsql/${PG_VERSION}"
PG_BIN_DIR="/usr/pgsql-${PG_VERSION}/bin"

# SSH Settings
SSH_USER="root"
SSH_OPTIONS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

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
    ssh ${SSH_OPTIONS} ${SSH_USER}@${ip} "$@"
}

run_on_all_nodes() {
    for node in lab01 lab02 lab03; do
        log_info "Running on ${node} (${NODES[$node]})..."
        run_on_node "$node" "$@"
    done
}

#-------------------------------------------------------------------------------
# Pre-flight Checks
#-------------------------------------------------------------------------------
preflight_checks() {
    log_step "Running pre-flight checks..."
    
    for node in lab01 lab02 lab03; do
        local ip=${NODES[$node]}
        log_info "Testing SSH connectivity to ${node} (${ip})..."
        if ! ssh ${SSH_OPTIONS} ${SSH_USER}@${ip} "echo 'SSH OK'" &>/dev/null; then
            log_error "Cannot connect to ${node} (${ip}). Please setup SSH keys first."
            log_info "Run: ssh-copy-id ${SSH_USER}@${ip}"
            exit 1
        fi
    done
    
    log_success "All nodes are reachable via SSH"
}

#-------------------------------------------------------------------------------
# Setup /etc/hosts on all nodes
#-------------------------------------------------------------------------------
setup_hosts() {
    log_step "Configuring /etc/hosts on all nodes..."
    
    for node in lab01 lab02 lab03; do
        run_on_node "$node" "
            # Backup original hosts file
            cp /etc/hosts /etc/hosts.backup.\$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
            
            # Remove old entries if they exist
            sed -i '/lab01/d; /lab02/d; /lab03/d; /ha-vip/d' /etc/hosts
            
            # Add new entries
            echo '${LAB01_IP}	lab01' >> /etc/hosts
            echo '${LAB02_IP}	lab02' >> /etc/hosts
            echo '${LAB03_IP}	lab03' >> /etc/hosts
            echo '${VIP}	ha-vip' >> /etc/hosts
        "
    done
    
    log_success "/etc/hosts configured on all nodes"
}

#-------------------------------------------------------------------------------
# Create postgres user
#-------------------------------------------------------------------------------
setup_postgres_user() {
    log_step "Creating postgres user on all nodes..."
    
    run_on_all_nodes "
        if ! id postgres &>/dev/null; then
            useradd postgres
            echo '${POSTGRES_PASSWORD}' | passwd --stdin postgres
        fi
        
        # Add to sudoers
        if ! grep -q '^postgres ALL' /etc/sudoers; then
            echo 'postgres ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
        fi
    "
    
    log_success "postgres user configured on all nodes"
}

#-------------------------------------------------------------------------------
# Set hostnames
#-------------------------------------------------------------------------------
setup_hostnames() {
    log_step "Setting hostnames on all nodes..."
    
    for node in lab01 lab02 lab03; do
        run_on_node "$node" "hostnamectl set-hostname ${node}"
    done
    
    log_success "Hostnames configured"
}

#-------------------------------------------------------------------------------
# Disable SELinux
#-------------------------------------------------------------------------------
disable_selinux() {
    log_step "Disabling SELinux on all nodes..."
    
    run_on_all_nodes "
        if [ -f /etc/selinux/config ]; then
            sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
            sed -i 's/^SELINUX=permissive/SELINUX=disabled/' /etc/selinux/config
            setenforce 0 2>/dev/null || true
        fi
    "
    
    log_success "SELinux disabled (reboot may be required for full effect)"
}

#-------------------------------------------------------------------------------
# Configure Firewall
#-------------------------------------------------------------------------------
configure_firewall() {
    log_step "Configuring firewall on all nodes..."
    
    run_on_all_nodes "
        systemctl start firewalld 2>/dev/null || true
        systemctl enable firewalld 2>/dev/null || true
        
        firewall-cmd --zone=public --add-port=5432/tcp --permanent
        firewall-cmd --zone=public --add-port=6432/tcp --permanent
        firewall-cmd --zone=public --add-port=8008/tcp --permanent
        firewall-cmd --zone=public --add-port=2379/tcp --permanent
        firewall-cmd --zone=public --add-port=2380/tcp --permanent
        firewall-cmd --permanent --zone=public --add-service=http
        firewall-cmd --zone=public --add-port=5000/tcp --permanent
        firewall-cmd --zone=public --add-port=5001/tcp --permanent
        firewall-cmd --zone=public --add-port=7000/tcp --permanent
        firewall-cmd --zone=public --add-port=112/tcp --permanent
        firewall-cmd --zone=public --add-port=5405/tcp --permanent
        firewall-cmd --add-rich-rule='rule protocol value=\"vrrp\" accept' --permanent
        firewall-cmd --reload
    "
    
    log_success "Firewall configured on all nodes"
}

#-------------------------------------------------------------------------------
# Install PostgreSQL
#-------------------------------------------------------------------------------
install_postgresql() {
    log_step "Installing PostgreSQL ${PG_VERSION} on all nodes..."
    
    run_on_all_nodes "
        dnf install -y epel-release
        dnf config-manager --set-enabled crb 2>/dev/null || true
        dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm || true
        dnf -qy module disable postgresql 2>/dev/null || true
        dnf install -y postgresql${PG_VERSION}-server postgresql${PG_VERSION}-contrib postgresql${PG_VERSION}-devel
    "
    
    log_success "PostgreSQL ${PG_VERSION} installed on all nodes"
}

#-------------------------------------------------------------------------------
# Install and Configure etcd
#-------------------------------------------------------------------------------
install_etcd() {
    log_step "Installing etcd on all nodes..."
    
    run_on_all_nodes "
        dnf install -y 'dnf-command(config-manager)'
        dnf config-manager --enable pgdg-rhel9-extras 2>/dev/null || true
        dnf install -y etcd
    "
    
    log_success "etcd installed on all nodes"
}

configure_etcd() {
    log_step "Configuring etcd on all nodes..."
    
    local etcd_cluster="lab01=http://${LAB01_IP}:2380,lab02=http://${LAB02_IP}:2380,lab03=http://${LAB03_IP}:2380"
    
    for node in lab01 lab02 lab03; do
        local ip=${NODES[$node]}
        
        run_on_node "$node" "
            mv /etc/etcd/etcd.conf /etc/etcd/etcd.conf.orig 2>/dev/null || true
            
            cat > /etc/etcd/etcd.conf << 'ETCDEOF'
# etcd configuration for ${node}
ETCD_NAME=${node}
ETCD_DATA_DIR=\"/var/lib/etcd/${node}\"
ETCD_LISTEN_PEER_URLS=\"http://${ip}:2380,http://127.0.0.1:2380\"
ETCD_LISTEN_CLIENT_URLS=\"http://${ip}:2379,http://127.0.0.1:2379\"
ETCD_INITIAL_ADVERTISE_PEER_URLS=\"http://${ip}:2380\"
ETCD_ADVERTISE_CLIENT_URLS=\"http://${ip}:2379\"
ETCD_INITIAL_CLUSTER=\"${etcd_cluster}\"
ETCD_INITIAL_CLUSTER_STATE=\"new\"
ETCD_INITIAL_CLUSTER_TOKEN=\"etcd-cluster\"
ETCD_ENABLE_V2=\"true\"
ETCDEOF
        "
    done
    
    log_success "etcd configured on all nodes"
}

start_etcd() {
    log_step "Starting etcd on all nodes..."
    
    # Start etcd on all nodes simultaneously
    for node in lab01 lab02 lab03; do
        run_on_node "$node" "systemctl enable etcd; systemctl start etcd" &
    done
    wait
    
    sleep 5
    
    # Verify etcd cluster
    local endpoints="${LAB01_IP}:2379,${LAB02_IP}:2379,${LAB03_IP}:2379"
    run_on_node "lab01" "etcdctl endpoint status --write-out=table --endpoints=${endpoints}" || true
    
    log_success "etcd cluster started"
}

#-------------------------------------------------------------------------------
# Install and Configure Keepalived
#-------------------------------------------------------------------------------
install_keepalived() {
    log_step "Installing Keepalived on all nodes..."
    
    run_on_all_nodes "dnf -y install keepalived"
    
    log_success "Keepalived installed on all nodes"
}

configure_keepalived() {
    log_step "Configuring Keepalived on all nodes..."
    
    # Configure sysctl
    run_on_all_nodes "
        grep -q 'net.ipv4.ip_nonlocal_bind' /etc/sysctl.conf || echo 'net.ipv4.ip_nonlocal_bind = 1' >> /etc/sysctl.conf
        grep -q 'net.ipv4.ip_forward' /etc/sysctl.conf || echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
        sysctl -p
    "
    
    # lab01 - MASTER
    run_on_node "lab01" "
        mv /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.orig 2>/dev/null || true
        
        cat > /etc/keepalived/keepalived.conf << 'KEEPALIVEDEOF'
vrrp_script check_haproxy {
    script \"pkill -0 haproxy\"
    interval 2
    weight 2
}

vrrp_instance VI_1 {
    state MASTER
    interface ${NETWORK_INTERFACE}
    virtual_router_id 51
    priority 101
    advert_int 1
    virtual_ipaddress {
        ${VIP}
    }
    track_script {
        check_haproxy
    }
}
KEEPALIVEDEOF
    "
    
    # lab02 - BACKUP
    run_on_node "lab02" "
        mv /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.orig 2>/dev/null || true
        
        cat > /etc/keepalived/keepalived.conf << 'KEEPALIVEDEOF'
vrrp_script check_haproxy {
    script \"pkill -0 haproxy\"
    interval 2
    weight 2
}

vrrp_instance VI_1 {
    state BACKUP
    interface ${NETWORK_INTERFACE}
    virtual_router_id 51
    priority 100
    advert_int 1
    virtual_ipaddress {
        ${VIP}
    }
    track_script {
        check_haproxy
    }
}
KEEPALIVEDEOF
    "
    
    # lab03 - BACKUP
    run_on_node "lab03" "
        mv /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.orig 2>/dev/null || true
        
        cat > /etc/keepalived/keepalived.conf << 'KEEPALIVEDEOF'
vrrp_script check_haproxy {
    script \"pkill -0 haproxy\"
    interval 2
    weight 2
}

vrrp_instance VI_1 {
    state BACKUP
    interface ${NETWORK_INTERFACE}
    virtual_router_id 51
    priority 99
    advert_int 1
    virtual_ipaddress {
        ${VIP}
    }
    track_script {
        check_haproxy
    }
}
KEEPALIVEDEOF
    "
    
    log_success "Keepalived configured on all nodes"
}

start_keepalived() {
    log_step "Starting Keepalived on all nodes..."
    
    run_on_all_nodes "
        systemctl enable keepalived
        systemctl start keepalived
    "
    
    sleep 3
    
    # Verify VIP
    run_on_node "lab01" "ip addr show ${NETWORK_INTERFACE} | grep -q '${VIP}' && echo 'VIP ${VIP} is active on lab01' || echo 'VIP not yet assigned'"
    
    log_success "Keepalived started"
}

#-------------------------------------------------------------------------------
# Install and Configure HAProxy
#-------------------------------------------------------------------------------
install_haproxy() {
    log_step "Installing HAProxy on all nodes..."
    
    run_on_all_nodes "dnf -y install haproxy"
    
    log_success "HAProxy installed on all nodes"
}

configure_haproxy() {
    log_step "Configuring HAProxy on all nodes..."
    
    # Create HAProxy config on lab01
    run_on_node "lab01" "
        mv /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.orig 2>/dev/null || true
        
        cat > /etc/haproxy/haproxy.cfg << 'HAPROXYEOF'
global
    maxconn     1000

defaults
    mode                    tcp
    log                     global
    option                  tcplog
    retries                 3
    timeout queue           1m
    timeout connect         4s
    timeout client          60m
    timeout server          60m
    timeout check           5s
    maxconn                 900

listen stats
    mode http
    bind *:7000
    stats enable
    stats uri /

listen primary
    bind ${VIP}:5000
    option httpchk OPTIONS /master
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server lab01 ${LAB01_IP}:5432 maxconn 100 check port 8008
    server lab02 ${LAB02_IP}:5432 maxconn 100 check port 8008
    server lab03 ${LAB03_IP}:5432 maxconn 100 check port 8008

listen standby
    bind ${VIP}:5001
    balance roundrobin
    option httpchk OPTIONS /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server lab01 ${LAB01_IP}:5432 maxconn 100 check port 8008
    server lab02 ${LAB02_IP}:5432 maxconn 100 check port 8008
    server lab03 ${LAB03_IP}:5432 maxconn 100 check port 8008
HAPROXYEOF
    "
    
    # Copy to other nodes
    run_on_node "lab01" "scp ${SSH_OPTIONS} /etc/haproxy/haproxy.cfg lab02:/etc/haproxy/haproxy.cfg"
    run_on_node "lab01" "scp ${SSH_OPTIONS} /etc/haproxy/haproxy.cfg lab03:/etc/haproxy/haproxy.cfg"
    
    log_success "HAProxy configured on all nodes"
}

start_haproxy() {
    log_step "Starting HAProxy on all nodes..."
    
    run_on_all_nodes "
        systemctl enable haproxy
        systemctl start haproxy
    "
    
    log_success "HAProxy started"
}

#-------------------------------------------------------------------------------
# Install and Configure Patroni
#-------------------------------------------------------------------------------
install_patroni() {
    log_step "Installing Patroni on all nodes..."
    
    run_on_all_nodes "
        dnf -y install patroni patroni-etcd watchdog
        ln -sf /usr/local/bin/patronictl /bin/patronictl 2>/dev/null || true
    "
    
    log_success "Patroni installed on all nodes"
}

configure_patroni() {
    log_step "Configuring Patroni on all nodes..."
    
    local etcd_hosts="${LAB01_IP}:2379,${LAB02_IP}:2379,${LAB03_IP}:2379"
    
    for node in lab01 lab02 lab03; do
        local ip=${NODES[$node]}
        
        run_on_node "$node" "
            mkdir -p /etc/patroni
            
            cat > /etc/patroni/patroni.yml << 'PATRONIEOF'
scope: postgres
namespace: /db/
name: ${node}

restapi:
    listen: ${ip}:8008
    connect_address: ${ip}:8008

etcd3:
    hosts: ${etcd_hosts}

bootstrap:
    dcs:
        ttl: 30
        loop_wait: 10
        retry_timeout: 10
        maximum_lag_on_failover: 1048576
        postgresql:
            use_pg_rewind: true
    pg_hba:
    - host replication replicator ${LAB01_IP}/32 md5
    - host replication replicator ${LAB02_IP}/32 md5
    - host replication replicator ${LAB03_IP}/32 md5
    - host replication all 0.0.0.0/0 md5
    - host all all 0.0.0.0/0 md5

postgresql:
    listen: ${ip}:5432
    connect_address: ${ip}:5432
    data_dir: ${PG_DATA_DIR}
    bin_dir: ${PG_BIN_DIR}
    authentication:
        replication:
            username: replicator
            password: ${REPLICATOR_PASSWORD}
        superuser:
            username: postgres
            password: ${POSTGRES_PASSWORD}
    parameters:
        unix_socket_directories: '/run/postgresql/'

watchdog:
    mode: required
    device: /dev/watchdog
    safety_margin: 5

tags:
    nofailover: false
    noloadbalance: false
    clonefrom: false
    nosync: false
PATRONIEOF
        "
    done
    
    log_success "Patroni configured on all nodes"
}

configure_watchdog() {
    log_step "Configuring watchdog on all nodes..."
    
    run_on_all_nodes "
        # Enable watchdog in config
        sed -i 's/^#watchdog-device/watchdog-device/' /etc/watchdog.conf 2>/dev/null || true
        
        # Create watchdog device if not exists
        [ -e /dev/watchdog ] || mknod /dev/watchdog c 10 130
        
        # Load softdog module
        modprobe softdog 2>/dev/null || true
        
        # Set ownership
        chown postgres /dev/watchdog
        
        # Create data directory
        mkdir -p /u01
        chown -R postgres:postgres /u01
        
        # Create socket directory
        mkdir -p /run/postgresql
        chown postgres:postgres /run/postgresql
    "
    
    log_success "Watchdog configured on all nodes"
}

start_patroni() {
    log_step "Starting Patroni cluster..."
    
    # Start on lab01 first (will bootstrap the cluster)
    log_info "Starting Patroni on lab01 (bootstrap)..."
    run_on_node "lab01" "systemctl enable patroni; systemctl start patroni"
    
    sleep 15
    
    # Start on remaining nodes
    for node in lab02 lab03; do
        log_info "Starting Patroni on ${node}..."
        run_on_node "$node" "systemctl enable patroni; systemctl start patroni"
        sleep 5
    done
    
    sleep 10
    
    # Verify cluster
    log_info "Verifying Patroni cluster..."
    run_on_node "lab01" "patronictl -c /etc/patroni/patroni.yml list" || true
    
    log_success "Patroni cluster started"
}

#-------------------------------------------------------------------------------
# Verification
#-------------------------------------------------------------------------------
verify_cluster() {
    log_step "Verifying cluster setup..."
    
    echo ""
    log_info "=== Patroni Cluster Status ==="
    run_on_node "lab01" "patronictl -c /etc/patroni/patroni.yml list" || true
    
    echo ""
    log_info "=== Testing connection via VIP ==="
    run_on_node "lab01" "
        export PGPASSWORD='${POSTGRES_PASSWORD}'
        psql -U postgres -h ${VIP} -p 5000 -c 'SELECT inet_server_addr(), now()::timestamp;'
    " || log_warning "Connection test failed - cluster may still be initializing"
    
    echo ""
    log_info "=== HAProxy Stats ==="
    echo "Access HAProxy stats at: http://${VIP}:7000/"
    
    log_success "Cluster verification complete"
}

#-------------------------------------------------------------------------------
# Print Summary
#-------------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "==============================================================================="
    echo "           POSTGRESQL ${PG_VERSION} HA CLUSTER WITH PATRONI - SETUP COMPLETE"
    echo "==============================================================================="
    echo ""
    echo "Cluster Configuration:"
    echo "  - VIP (Virtual IP):     ${VIP}"
    echo "  - Primary Port:         5000 (via HAProxy)"
    echo "  - Standby Port:         5001 (via HAProxy, load balanced)"
    echo "  - HAProxy Stats:        http://${VIP}:7000/"
    echo ""
    echo "Nodes:"
    echo "  - lab01:                ${LAB01_IP}"
    echo "  - lab02:                ${LAB02_IP}"
    echo "  - lab03:                ${LAB03_IP}"
    echo ""
    echo "Connection Strings:"
    echo "  - Primary (read-write): psql -h ${VIP} -p 5000 -U postgres"
    echo "  - Standby (read-only):  psql -h ${VIP} -p 5001 -U postgres"
    echo ""
    echo "Useful Commands:"
    echo "  - Cluster status:       patronictl -c /etc/patroni/patroni.yml list"
    echo "  - Switchover:           patronictl -c /etc/patroni/patroni.yml switchover"
    echo "  - Failover:             patronictl -c /etc/patroni/patroni.yml failover"
    echo "  - Reinitialize node:    patronictl -c /etc/patroni/patroni.yml reinit postgres <node>"
    echo ""
    echo "Credentials:"
    echo "  - postgres password:    ${POSTGRES_PASSWORD}"
    echo "  - replicator password:  ${REPLICATOR_PASSWORD}"
    echo ""
    echo "pgbench Tests:"
    echo "  - Initialize:           pgbench -i -s 10 -U postgres -h ${VIP} -p 5000 postgres"
    echo "  - Read/Write (primary): pgbench -c 10 -t 10 -U postgres -h ${VIP} -p 5000 postgres"
    echo "  - Read-only (standby):  pgbench -c 10 -t 10 -S -U postgres -h ${VIP} -p 5001 postgres"
    echo ""
    echo "==============================================================================="
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    echo "==============================================================================="
    echo "       POSTGRESQL ${PG_VERSION} HA WITH PATRONI - AUTOMATED SETUP"
    echo "==============================================================================="
    echo ""
    echo "Nodes:"
    echo "  - lab01: ${LAB01_IP}"
    echo "  - lab02: ${LAB02_IP}"
    echo "  - lab03: ${LAB03_IP}"
    echo "  - VIP:   ${VIP}"
    echo ""
    echo "Settings:"
    echo "  - PostgreSQL Version:   ${PG_VERSION}"
    echo "  - Network Interface:    ${NETWORK_INTERFACE}"
    echo "  - Data Directory:       ${PG_DATA_DIR}"
    echo ""
    
    preflight_checks
    
    if [ "$CHECK_ONLY" = true ]; then
        log_success "Pre-flight checks passed. Ready for installation."
        exit 0
    fi
    
    if [ "$VERIFY_ONLY" = true ]; then
        verify_cluster
        exit 0
    fi
    
    # Basic setup
    setup_hosts
    setup_postgres_user
    setup_hostnames
    disable_selinux
    configure_firewall
    
    # PostgreSQL
    install_postgresql
    
    # etcd
    install_etcd
    configure_etcd
    start_etcd
    
    # Keepalived
    install_keepalived
    configure_keepalived
    start_keepalived
    
    # HAProxy
    install_haproxy
    configure_haproxy
    start_haproxy
    
    # Patroni
    install_patroni
    configure_patroni
    configure_watchdog
    start_patroni
    
    # Verify and summarize
    verify_cluster
    print_summary
}

main
