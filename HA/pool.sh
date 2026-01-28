#!/bin/bash
#===============================================================================
# Pgpool-II Automated Setup Script
# Description: Automates installation and configuration of Pgpool-II for 
#              PostgreSQL with streaming replication
# Usage: ./pgpool_setup.sh <backend0_ip> <backend1_ip> [options]
# Example: ./pgpool_setup.sh 192.168.110.171 192.168.110.172
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Parse Arguments
#-------------------------------------------------------------------------------
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <backend0_hostname> <backend1_hostname> [options]"
    echo ""
    echo "Arguments:"
    echo "  backend0_hostname    Primary PostgreSQL server IP/hostname"
    echo "  backend1_hostname    Standby PostgreSQL server IP/hostname"
    echo ""
    echo "Options:"
    echo "  -p, --port PORT      PostgreSQL port (default: 5432)"
    echo "  -d, --datadir DIR    PostgreSQL data directory (default: /u01/pgsql/16)"
    echo "  -u, --user USER      Health check user (default: postgres)"
    echo "  -P, --password PASS  Health check password (default: postgres)"
    echo "  -h, --help           Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 192.168.110.171 192.168.110.172"
    echo "  $0 pg-primary pg-standby -p 5433 -u replicator"
    echo "  $0 10.0.0.1 10.0.0.2 -d /var/lib/pgsql/17/data"
    exit 1
fi

# Required arguments
BACKEND0_HOSTNAME="$1"
BACKEND1_HOSTNAME="$2"
shift 2

# Default values
BACKEND_PORT=5432
BACKEND_DATA_DIR="/u01/pgsql/16"
CHECK_USER="postgres"
CHECK_PASSWORD="postgres"

# Parse optional arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--port)
            BACKEND_PORT="$2"
            shift 2
            ;;
        -d|--datadir)
            BACKEND_DATA_DIR="$2"
            shift 2
            ;;
        -u|--user)
            CHECK_USER="$2"
            shift 2
            ;;
        -P|--password)
            CHECK_PASSWORD="$2"
            shift 2
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
PGPOOL_PORT=9999
HEALTH_CHECK_PERIOD=1

# Paths
PGPOOL_CONF_DIR="/etc/pgpool-II"
PGPOOL_CONF="${PGPOOL_CONF_DIR}/pgpool.conf"
PGPOOL_CONF_SAMPLE="${PGPOOL_CONF_DIR}/pgpool.conf.sample"
POOL_PASSWD="${PGPOOL_CONF_DIR}/pool_passwd"
SOCKET_DIR="/var/run/postgresql"

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
# Pre-flight Checks
#-------------------------------------------------------------------------------
preflight_checks() {
    log_info "Running pre-flight checks..."
    
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    if ! command -v dnf &> /dev/null; then
        log_error "dnf package manager not found. This script requires RHEL/CentOS 8+."
        exit 1
    fi
    
    log_success "Pre-flight checks passed"
}

#-------------------------------------------------------------------------------
# Install Pgpool-II
#-------------------------------------------------------------------------------
install_pgpool() {
    log_info "Installing Pgpool-II..."
    
    if rpm -q pgpool-II &> /dev/null; then
        log_warning "Pgpool-II is already installed"
        read -p "Do you want to reinstall? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping installation"
            return 0
        fi
    fi
    
    dnf install -y pgpool-II
    
    log_success "Pgpool-II installed successfully"
}

#-------------------------------------------------------------------------------
# Create Required Directories
#-------------------------------------------------------------------------------
create_directories() {
    log_info "Creating required directories..."
    
    # Socket directory
    mkdir -p "${SOCKET_DIR}"
    chown postgres:postgres "${SOCKET_DIR}"
    chmod 755 "${SOCKET_DIR}"
    
    # Pgpool runtime directory (for lock files, status files)
    mkdir -p /var/run/pgpool-II/oiddir
    chown -R postgres:postgres /var/run/pgpool-II
    chmod 755 /var/run/pgpool-II
    
    # Log directory
    mkdir -p /var/log/pgpool-II
    chown postgres:postgres /var/log/pgpool-II
    
    # Make directories persistent across reboots (tmpfs)
    cat > /etc/tmpfiles.d/pgpool-II.conf << EOF
d /var/run/postgresql 0755 postgres postgres -
d /var/run/pgpool-II 0755 postgres postgres -
d /var/run/pgpool-II/oiddir 0755 postgres postgres -
EOF
    
    log_success "Directories created"
}

#-------------------------------------------------------------------------------
# Backup Existing Configuration
#-------------------------------------------------------------------------------
backup_config() {
    log_info "Backing up existing configuration..."
    
    if [[ -f "${PGPOOL_CONF}" ]]; then
        BACKUP_FILE="${PGPOOL_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "${PGPOOL_CONF}" "${BACKUP_FILE}"
        log_success "Backup created: ${BACKUP_FILE}"
    fi
}

#-------------------------------------------------------------------------------
# Configure Pgpool-II
#-------------------------------------------------------------------------------
configure_pgpool() {
    log_info "Configuring Pgpool-II..."
    
    if [[ -f "${PGPOOL_CONF_SAMPLE}" ]]; then
        cp "${PGPOOL_CONF_SAMPLE}" "${PGPOOL_CONF}"
    else
        log_error "Sample configuration not found at ${PGPOOL_CONF_SAMPLE}"
        exit 1
    fi
    
    log_info "Applying configuration..."
    
    # Connection Settings (handle both commented and uncommented lines)
    sed -i "s/^#*listen_addresses = .*/listen_addresses = '*'/" "${PGPOOL_CONF}"
    sed -i "s|^#*pcp_socket_dir = .*|pcp_socket_dir = '${SOCKET_DIR}'|" "${PGPOOL_CONF}"
    sed -i "s|^#*unix_socket_directories = .*|unix_socket_directories = '${SOCKET_DIR}'|" "${PGPOOL_CONF}"
    
    # Authentication
    sed -i "s/^#*allow_clear_text_frontend_auth = .*/allow_clear_text_frontend_auth = on/" "${PGPOOL_CONF}"
    sed -i "s/^#*pool_passwd = .*/pool_passwd = ''/" "${PGPOOL_CONF}"
    
    # Backend 0 (Primary) - handle commented lines with #*
    sed -i "s/^#*backend_hostname0 = .*/backend_hostname0 = '${BACKEND0_HOSTNAME}'/" "${PGPOOL_CONF}"
    sed -i "s/^#*backend_port0 = .*/backend_port0 = ${BACKEND_PORT}/" "${PGPOOL_CONF}"
    sed -i "s/^#*backend_weight0 = .*/backend_weight0 = 1/" "${PGPOOL_CONF}"
    sed -i "s|^#*backend_data_directory0 = .*|backend_data_directory0 = '${BACKEND_DATA_DIR}'|" "${PGPOOL_CONF}"
    sed -i "s/^#*backend_flag0 = .*/backend_flag0 = 'ALLOW_TO_FAILOVER'/" "${PGPOOL_CONF}"
    sed -i "s/^#*backend_application_name0 = .*/backend_application_name0 = 'server0'/" "${PGPOOL_CONF}"
    
    # Backend 1 (Standby) - append since it doesn't exist in sample
    cat >> "${PGPOOL_CONF}" << EOF

# Backend 1 Configuration
backend_hostname1 = '${BACKEND1_HOSTNAME}'
backend_port1 = ${BACKEND_PORT}
backend_weight1 = 1
backend_data_directory1 = '${BACKEND_DATA_DIR}'
backend_flag1 = 'ALLOW_TO_FAILOVER'
backend_application_name1 = 'server1'
EOF
    
    # Streaming Replication Check
    sed -i "s/^#*sr_check_user = .*/sr_check_user = '${CHECK_USER}'/" "${PGPOOL_CONF}"
    sed -i "s/^#*sr_check_password = .*/sr_check_password = '${CHECK_PASSWORD}'/" "${PGPOOL_CONF}"
    sed -i "s/^#*sr_check_database = .*/sr_check_database = 'postgres'/" "${PGPOOL_CONF}"
    
    # Health Check
    sed -i "s/^#*health_check_period = .*/health_check_period = ${HEALTH_CHECK_PERIOD}/" "${PGPOOL_CONF}"
    sed -i "s/^#*health_check_user = .*/health_check_user = '${CHECK_USER}'/" "${PGPOOL_CONF}"
    sed -i "s/^#*health_check_password = .*/health_check_password = '${CHECK_PASSWORD}'/" "${PGPOOL_CONF}"
    sed -i "s/^#*health_check_database = .*/health_check_database = 'postgres'/" "${PGPOOL_CONF}"
    
    # Fix directory paths for lock files and status files
    sed -i "s|^#*logdir = .*|logdir = '/var/run/pgpool-II'|" "${PGPOOL_CONF}"
    sed -i "s|^#*memqcache_oiddir = .*|memqcache_oiddir = '/var/run/pgpool-II/oiddir'|" "${PGPOOL_CONF}"
    
    # Ensure logdir is set (append if sed didn't match)
    if ! grep -q "^logdir = " "${PGPOOL_CONF}"; then
        echo "logdir = '/var/run/pgpool-II'" >> "${PGPOOL_CONF}"
    fi
    
    log_success "Configuration applied"
}

#-------------------------------------------------------------------------------
# Create pool_passwd File
#-------------------------------------------------------------------------------
create_pool_passwd() {
    log_info "Creating pool_passwd file..."
    
    touch "${POOL_PASSWD}"
    chmod 600 "${POOL_PASSWD}"
    chown postgres:postgres "${POOL_PASSWD}"
    
    log_success "pool_passwd file created"
}

#-------------------------------------------------------------------------------
# Start Pgpool-II Service
#-------------------------------------------------------------------------------
start_pgpool_service() {
    log_info "Starting Pgpool-II service..."
    
    systemctl enable pgpool-II
    systemctl start pgpool-II
    
    sleep 3
    if systemctl is-active --quiet pgpool-II; then
        log_success "Pgpool-II service started"
    else
        log_error "Failed to start Pgpool-II service"
        systemctl status pgpool-II --no-pager
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# Verify Installation
#-------------------------------------------------------------------------------
verify_installation() {
    log_info "Verifying Pgpool-II..."
    
    echo ""
    systemctl status pgpool-II --no-pager -l | head -20
    
    echo ""
    log_info "Testing connection..."
    
    export PGPASSWORD="${CHECK_PASSWORD}"
    if psql -U "${CHECK_USER}" -h localhost -p ${PGPOOL_PORT} postgres -c "show pool_nodes" 2>/dev/null; then
        log_success "Pgpool-II is working!"
    else
        log_warning "Could not verify pool_nodes. Check backend connectivity."
        echo "Manual test: psql -U ${CHECK_USER} -h localhost -p ${PGPOOL_PORT} postgres -c 'show pool_nodes'"
    fi
    unset PGPASSWORD
}

#-------------------------------------------------------------------------------
# Print Summary
#-------------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "==============================================================================="
    echo "                        PGPOOL-II SETUP COMPLETE"
    echo "==============================================================================="
    echo ""
    echo "Configuration:"
    echo "  - Pgpool Port:       ${PGPOOL_PORT}"
    echo "  - Config File:       ${PGPOOL_CONF}"
    echo ""
    echo "Backend Servers:"
    echo "  - Backend 0:         ${BACKEND0_HOSTNAME}:${BACKEND_PORT} (server0)"
    echo "  - Backend 1:         ${BACKEND1_HOSTNAME}:${BACKEND_PORT} (server1)"
    echo ""
    echo "Commands:"
    echo "  - Status:            systemctl status pgpool-II"
    echo "  - Logs:              journalctl -u pgpool-II -f"
    echo "  - Show nodes:        psql -U postgres -p 9999 -c 'show pool_nodes'"
    echo ""
    echo "==============================================================================="
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    echo "==============================================================================="
    echo "                    PGPOOL-II AUTOMATED SETUP"
    echo "==============================================================================="
    echo ""
    echo "Backend 0: ${BACKEND0_HOSTNAME}:${BACKEND_PORT}"
    echo "Backend 1: ${BACKEND1_HOSTNAME}:${BACKEND_PORT}"
    echo ""
    
    preflight_checks
    install_pgpool
    create_directories
    backup_config
    configure_pgpool
    create_pool_passwd
    start_pgpool_service
    verify_installation
    print_summary
}

main
