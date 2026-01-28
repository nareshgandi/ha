#!/bin/bash
#===============================================================================
# PgBouncer - Cleanup Script
# Description: Removes PgBouncer completely for fresh testing
# Usage: ./pgbouncer_cleanup.sh
#===============================================================================

set -euo pipefail

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
# Check Root
#-------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

#-------------------------------------------------------------------------------
# Confirmation
#-------------------------------------------------------------------------------
echo "==============================================================================="
echo "                    PGBOUNCER CLEANUP"
echo "==============================================================================="
echo ""
echo "This will COMPLETELY REMOVE:"
echo "  - PgBouncer service"
echo "  - PgBouncer package"
echo "  - Configuration files (/etc/pgbouncer/)"
echo "  - Log files (/var/log/pgbouncer/)"
echo "  - Run files (/var/run/pgbouncer/)"
echo ""
log_warning "THIS ACTION CANNOT BE UNDONE!"
echo ""
read -p "Are you sure you want to proceed? (y/N): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Cleanup cancelled."
    exit 0
fi

echo ""

#-------------------------------------------------------------------------------
# Stop Service
#-------------------------------------------------------------------------------
log_info "Stopping PgBouncer service..."
systemctl stop pgbouncer 2>/dev/null || true
systemctl disable pgbouncer 2>/dev/null || true
log_success "Service stopped"

#-------------------------------------------------------------------------------
# Remove Package
#-------------------------------------------------------------------------------
log_info "Removing PgBouncer package..."
dnf remove -y pgbouncer 2>/dev/null || yum remove -y pgbouncer 2>/dev/null || true
log_success "Package removed"

#-------------------------------------------------------------------------------
# Remove Configuration
#-------------------------------------------------------------------------------
log_info "Removing configuration files..."
rm -rf /etc/pgbouncer
log_success "Configuration removed"

#-------------------------------------------------------------------------------
# Remove Logs
#-------------------------------------------------------------------------------
log_info "Removing log files..."
rm -rf /var/log/pgbouncer
log_success "Logs removed"

#-------------------------------------------------------------------------------
# Remove Runtime Files
#-------------------------------------------------------------------------------
log_info "Removing runtime files..."
rm -rf /var/run/pgbouncer
rm -f /etc/tmpfiles.d/pgbouncer.conf
log_success "Runtime files removed"

#-------------------------------------------------------------------------------
# Verify
#-------------------------------------------------------------------------------
log_info "Verifying cleanup..."
echo ""

if rpm -q pgbouncer &>/dev/null; then
    log_error "PgBouncer package still installed!"
else
    log_success "PgBouncer package: removed"
fi

if [[ -d /etc/pgbouncer ]]; then
    log_error "/etc/pgbouncer still exists!"
else
    log_success "/etc/pgbouncer: removed"
fi

if systemctl is-active --quiet pgbouncer 2>/dev/null; then
    log_error "PgBouncer service still running!"
else
    log_success "PgBouncer service: stopped"
fi

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
echo ""
echo "==============================================================================="
echo "                    CLEANUP COMPLETE"
echo "==============================================================================="
echo ""
echo "PgBouncer has been completely removed."
echo ""
echo "To reinstall, run:"
echo "  ./pgbouncer_setup.sh <backend_ip>"
echo ""
echo "==============================================================================="
