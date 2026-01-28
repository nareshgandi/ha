#!/bin/bash
#===============================================================================
# PgBouncer Automated Setup Script
# Description: Automates installation, configuration, testing and verification
#              of PgBouncer connection pooler for PostgreSQL
# Usage: ./pgbouncer_setup.sh <backend_ip> [options]
# Example: ./pgbouncer_setup.sh 192.168.44.128
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Parse Arguments
#-------------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <backend_hostname> [options]"
    echo ""
    echo "Arguments:"
    echo "  backend_hostname     PostgreSQL server IP/hostname"
    echo ""
    echo "Options:"
    echo "  -p, --port PORT      PostgreSQL port (default: 5432)"
    echo "  -b, --bouncer-port   PgBouncer port (default: 6432)"
    echo "  -u, --user USER      Database user (default: postgres)"
    echo "  -P, --password PASS  Database password (default: postgres)"
    echo "  -m, --pool-mode MODE Pool mode: session|transaction|statement (default: transaction)"
    echo "  -s, --pool-size SIZE Default pool size (default: 20)"
    echo "  -h, --help           Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 192.168.44.128"
    echo "  $0 192.168.44.128 -m session -s 50"
    echo "  $0 pg-primary -p 5433 -b 6433"
    exit 1
fi

# Required arguments
BACKEND_HOSTNAME="$1"
shift

# Default values
BACKEND_PORT=5432
PGBOUNCER_PORT=6432
DB_USER="postgres"
DB_PASSWORD="postgres"
POOL_MODE="transaction"
POOL_SIZE=20

# Parse optional arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--port)
            BACKEND_PORT="$2"
            shift 2
            ;;
        -b|--bouncer-port)
            PGBOUNCER_PORT="$2"
            shift 2
            ;;
        -u|--user)
            DB_USER="$2"
            shift 2
            ;;
        -P|--password)
            DB_PASSWORD="$2"
            shift 2
            ;;
        -m|--pool-mode)
            POOL_MODE="$2"
            shift 2
            ;;
        -s|--pool-size)
            POOL_SIZE="$2"
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
PGBOUNCER_CONF_DIR="/etc/pgbouncer"
PGBOUNCER_CONF="${PGBOUNCER_CONF_DIR}/pgbouncer.ini"
PGBOUNCER_USERLIST="${PGBOUNCER_CONF_DIR}/userlist.txt"
PGBOUNCER_LOG_DIR="/var/log/pgbouncer"
PGBOUNCER_RUN_DIR="/var/run/pgbouncer"

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
# Pre-flight Checks
#-------------------------------------------------------------------------------
preflight_checks() {
    log_step "Running pre-flight checks..."
    
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
# Install PgBouncer
#-------------------------------------------------------------------------------
install_pgbouncer() {
    log_step "Installing PgBouncer..."
    
    if rpm -q pgbouncer &> /dev/null; then
        log_warning "PgBouncer is already installed"
        read -p "Do you want to reinstall? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping installation"
            return 0
        fi
    fi
    
    dnf install -y pgbouncer
    
    log_success "PgBouncer installed successfully"
}

#-------------------------------------------------------------------------------
# Create Required Directories
#-------------------------------------------------------------------------------
create_directories() {
    log_step "Creating required directories..."
    
    # Log directory
    mkdir -p "${PGBOUNCER_LOG_DIR}"
    chown pgbouncer:pgbouncer "${PGBOUNCER_LOG_DIR}"
    chmod 755 "${PGBOUNCER_LOG_DIR}"
    
    # Run directory
    mkdir -p "${PGBOUNCER_RUN_DIR}"
    chown pgbouncer:pgbouncer "${PGBOUNCER_RUN_DIR}"
    chmod 755 "${PGBOUNCER_RUN_DIR}"
    
    # Make directories persistent across reboots
    cat > /etc/tmpfiles.d/pgbouncer.conf << EOF
d /var/run/pgbouncer 0755 pgbouncer pgbouncer -
EOF
    
    log_success "Directories created"
}

#-------------------------------------------------------------------------------
# Backup Existing Configuration
#-------------------------------------------------------------------------------
backup_config() {
    log_step "Backing up existing configuration..."
    
    if [[ -f "${PGBOUNCER_CONF}" ]]; then
        BACKUP_FILE="${PGBOUNCER_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "${PGBOUNCER_CONF}" "${BACKUP_FILE}"
        log_success "Backup created: ${BACKUP_FILE}"
    fi
}

#-------------------------------------------------------------------------------
# Generate MD5 Password Hash
#-------------------------------------------------------------------------------
generate_md5_password() {
    local user=$1
    local pass=$2
    echo "md5$(echo -n "${pass}${user}" | md5sum | cut -d' ' -f1)"
}

#-------------------------------------------------------------------------------
# Configure PgBouncer
#-------------------------------------------------------------------------------
configure_pgbouncer() {
    log_step "Configuring PgBouncer..."
    
    # Generate MD5 password
    local md5_pass=$(generate_md5_password "${DB_USER}" "${DB_PASSWORD}")
    
    # Create pgbouncer.ini
    cat > "${PGBOUNCER_CONF}" << EOF
;; PgBouncer Configuration File
;; Generated by pgbouncer_setup.sh on $(date)

[databases]
;; Database connection definitions
;; dbname = host=hostname port=port dbname=actual_dbname
* = host=${BACKEND_HOSTNAME} port=${BACKEND_PORT}
postgres = host=${BACKEND_HOSTNAME} port=${BACKEND_PORT} dbname=postgres

[pgbouncer]
;; Administrative settings
listen_addr = *
listen_port = ${PGBOUNCER_PORT}
auth_type = md5
auth_file = ${PGBOUNCER_USERLIST}

;; Pool settings
pool_mode = ${POOL_MODE}
default_pool_size = ${POOL_SIZE}
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 3
max_client_conn = 1000
max_db_connections = 100

;; Timeouts
server_idle_timeout = 600
server_connect_timeout = 15
server_login_retry = 15
query_timeout = 0
query_wait_timeout = 120
client_idle_timeout = 0
client_login_timeout = 60

;; Logging
logfile = ${PGBOUNCER_LOG_DIR}/pgbouncer.log
pidfile = ${PGBOUNCER_RUN_DIR}/pgbouncer.pid
admin_users = ${DB_USER}
stats_users = ${DB_USER}

;; Connection sanity checks
server_reset_query = DISCARD ALL
server_check_query = SELECT 1
server_check_delay = 30

;; TLS settings (disabled by default)
;client_tls_sslmode = disable
;server_tls_sslmode = disable

;; Unix socket settings
unix_socket_dir = ${PGBOUNCER_RUN_DIR}
EOF

    # Create userlist.txt
    cat > "${PGBOUNCER_USERLIST}" << EOF
"${DB_USER}" "${md5_pass}"
EOF

    # Set proper permissions
    chown pgbouncer:pgbouncer "${PGBOUNCER_CONF}"
    chmod 640 "${PGBOUNCER_CONF}"
    chown pgbouncer:pgbouncer "${PGBOUNCER_USERLIST}"
    chmod 600 "${PGBOUNCER_USERLIST}"
    
    log_success "Configuration applied"
}

#-------------------------------------------------------------------------------
# Start PgBouncer Service
#-------------------------------------------------------------------------------
start_pgbouncer_service() {
    log_step "Starting PgBouncer service..."
    
    systemctl enable pgbouncer
    systemctl restart pgbouncer
    
    sleep 2
    if systemctl is-active --quiet pgbouncer; then
        log_success "PgBouncer service started"
    else
        log_error "Failed to start PgBouncer service"
        systemctl status pgbouncer --no-pager
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# Test PgBouncer Connection
#-------------------------------------------------------------------------------
test_connection() {
    log_step "Testing PgBouncer connection..."
    
    echo ""
    log_info "Test 1: Basic connection test"
    export PGPASSWORD="${DB_PASSWORD}"
    if psql -U "${DB_USER}" -h 127.0.0.1 -p ${PGBOUNCER_PORT} -d postgres -c "SELECT 'PgBouncer connection successful!' AS status;" 2>/dev/null; then
        log_success "Basic connection test passed"
    else
        log_error "Basic connection test failed"
    fi
    
    echo ""
    log_info "Test 2: Check backend server"
    if psql -U "${DB_USER}" -h 127.0.0.1 -p ${PGBOUNCER_PORT} -d postgres -c "SELECT inet_server_addr() AS backend_ip, inet_server_port() AS backend_port;" 2>/dev/null; then
        log_success "Backend connection verified"
    else
        log_warning "Could not verify backend"
    fi
    
    echo ""
    log_info "Test 3: PgBouncer admin - SHOW POOLS"
    if psql -U "${DB_USER}" -h 127.0.0.1 -p ${PGBOUNCER_PORT} -d pgbouncer -c "SHOW POOLS;" 2>/dev/null; then
        log_success "Admin interface working"
    else
        log_warning "Admin interface test failed"
    fi
    
    echo ""
    log_info "Test 4: PgBouncer admin - SHOW STATS"
    if psql -U "${DB_USER}" -h 127.0.0.1 -p ${PGBOUNCER_PORT} -d pgbouncer -c "SHOW STATS;" 2>/dev/null; then
        log_success "Stats available"
    else
        log_warning "Stats test failed"
    fi
    
    unset PGPASSWORD
}

#-------------------------------------------------------------------------------
# Run pgbench Test
#-------------------------------------------------------------------------------
run_pgbench_test() {
    log_step "Running pgbench performance test..."
    
    # Find pgbench
    PGBENCH_BIN=""
    for ver in 18 17 16 15 14; do
        if [[ -x "/usr/pgsql-${ver}/bin/pgbench" ]]; then
            PGBENCH_BIN="/usr/pgsql-${ver}/bin/pgbench"
            break
        fi
    done
    
    if [[ -z "${PGBENCH_BIN}" ]] && command -v pgbench &> /dev/null; then
        PGBENCH_BIN="pgbench"
    fi
    
    if [[ -z "${PGBENCH_BIN}" ]]; then
        log_warning "pgbench not found. Skipping performance test."
        log_info "Install with: dnf install postgresql*-contrib"
        return 0
    fi
    
    export PGPASSWORD="${DB_PASSWORD}"
    
    echo ""
    log_info "Initializing pgbench tables..."
    ${PGBENCH_BIN} -i -s 5 -U "${DB_USER}" -h 127.0.0.1 -p ${PGBOUNCER_PORT} postgres 2>/dev/null || {
        log_warning "pgbench init failed (tables may already exist)"
    }
    
    echo ""
    log_info "Running read/write test (10 clients, 10 transactions each)..."
    ${PGBENCH_BIN} -c 10 -t 10 -U "${DB_USER}" -h 127.0.0.1 -p ${PGBOUNCER_PORT} postgres 2>/dev/null || {
        log_warning "Read/write test failed"
    }
    
    echo ""
    log_info "Running read-only test (10 clients, 10 transactions each)..."
    ${PGBENCH_BIN} -c 10 -t 10 -S -U "${DB_USER}" -h 127.0.0.1 -p ${PGBOUNCER_PORT} postgres 2>/dev/null || {
        log_warning "Read-only test failed"
    }
    
    unset PGPASSWORD
    
    log_success "pgbench tests completed"
}

#-------------------------------------------------------------------------------
# Verify Installation
#-------------------------------------------------------------------------------
verify_installation() {
    log_step "Verifying PgBouncer installation..."
    
    echo ""
    log_info "Service Status:"
    systemctl status pgbouncer --no-pager -l | head -15
    
    echo ""
    log_info "Listening ports:"
    ss -tlnp | grep ${PGBOUNCER_PORT} || netstat -tlnp | grep ${PGBOUNCER_PORT} 2>/dev/null || true
    
    echo ""
    log_info "Log file:"
    if [[ -f "${PGBOUNCER_LOG_DIR}/pgbouncer.log" ]]; then
        tail -10 "${PGBOUNCER_LOG_DIR}/pgbouncer.log"
    else
        log_warning "Log file not found yet"
    fi
}

#-------------------------------------------------------------------------------
# Print Summary
#-------------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "==============================================================================="
    echo "                        PGBOUNCER SETUP COMPLETE"
    echo "==============================================================================="
    echo ""
    echo "Configuration:"
    echo "  - PgBouncer Port:    ${PGBOUNCER_PORT}"
    echo "  - Pool Mode:         ${POOL_MODE}"
    echo "  - Pool Size:         ${POOL_SIZE}"
    echo "  - Config File:       ${PGBOUNCER_CONF}"
    echo "  - Userlist File:     ${PGBOUNCER_USERLIST}"
    echo ""
    echo "Backend Server:"
    echo "  - Host:              ${BACKEND_HOSTNAME}:${BACKEND_PORT}"
    echo ""
    echo "Connection:"
    echo "  - Connect:           psql -U ${DB_USER} -h localhost -p ${PGBOUNCER_PORT} postgres"
    echo "  - Admin console:     psql -U ${DB_USER} -h localhost -p ${PGBOUNCER_PORT} pgbouncer"
    echo ""
    echo "Admin Commands (connect to pgbouncer database):"
    echo "  - SHOW POOLS;        View connection pools"
    echo "  - SHOW CLIENTS;      View client connections"
    echo "  - SHOW SERVERS;      View server connections"
    echo "  - SHOW STATS;        View statistics"
    echo "  - SHOW CONFIG;       View configuration"
    echo "  - RELOAD;            Reload configuration"
    echo "  - PAUSE;             Pause all connections"
    echo "  - RESUME;            Resume connections"
    echo ""
    echo "Service Commands:"
    echo "  - Status:            systemctl status pgbouncer"
    echo "  - Logs:              tail -f ${PGBOUNCER_LOG_DIR}/pgbouncer.log"
    echo "  - Restart:           systemctl restart pgbouncer"
    echo ""
    echo "pgbench Tests:"
    echo "  - Initialize:        pgbench -i -s 10 -U ${DB_USER} -h localhost -p ${PGBOUNCER_PORT} postgres"
    echo "  - Read/Write test:   pgbench -c 10 -t 10 -U ${DB_USER} -h localhost -p ${PGBOUNCER_PORT} postgres"
    echo "  - Read-only test:    pgbench -c 10 -t 10 -S -U ${DB_USER} -h localhost -p ${PGBOUNCER_PORT} postgres"
    echo ""
    echo "==============================================================================="
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    echo "==============================================================================="
    echo "                    PGBOUNCER AUTOMATED SETUP"
    echo "==============================================================================="
    echo ""
    echo "Backend:    ${BACKEND_HOSTNAME}:${BACKEND_PORT}"
    echo "PgBouncer:  Port ${PGBOUNCER_PORT}, Pool Mode: ${POOL_MODE}, Pool Size: ${POOL_SIZE}"
    echo ""
    
    preflight_checks
    install_pgbouncer
    create_directories
    backup_config
    configure_pgbouncer
    start_pgbouncer_service
    verify_installation
    test_connection
    run_pgbench_test
    print_summary
}

main
