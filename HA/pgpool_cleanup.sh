#!/bin/bash
#===============================================================================
# Pgpool-II - Cleanup Script
# Description: Removes Pgpool-II completely for fresh testing
# Usage: ./pgpool_cleanup.sh
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
echo "                    PGPOOL-II CLEANUP"
echo "==============================================================================="
echo ""
echo "This will COMPLETELY REMOVE:"
echo "  - Pgpool-II service"
echo "  - Pgpool-II package"
echo "  - Configuration files (/etc/pgpool-II/)"
echo "  - Run files (/var/run/pgpool-II/)"
echo "  - Log files"
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
log_info "Stopping Pgpool-II service..."
systemctl stop pgpool 2>/dev/null || true
systemctl stop pgpool-II 2>/dev/null || true
systemctl disable pgpool 2>/dev/null || true
systemctl disable pgpool-II 2>/dev/null || true

# Kill any remaining processes
pkill -9 pgpool 2>/dev/null || true

log_success "Service stopped"

#-------------------------------------------------------------------------------
# Remove Package
#-------------------------------------------------------------------------------
log_info "Removing Pgpool-II package..."
dnf remove -y pgpool-II 2>/dev/null || true
dnf remove -y pgpool-II-release 2>/dev/null || true
yum remove -y pgpool-II 2>/dev/null || true
log_success "Package removed"

#-------------------------------------------------------------------------------
# Remove Configuration
#-------------------------------------------------------------------------------
log_info "Removing configuration files..."
rm -rf /etc/pgpool-II
rm -rf /etc/pgpool
log_success "Configuration removed"

#-------------------------------------------------------------------------------
# Remove Runtime Files
#-------------------------------------------------------------------------------
log_info "Removing runtime files..."
rm -rf /var/run/pgpool-II
rm -rf /var/run/pgpool
rm -rf /run/pgpool-II
rm -rf /run/pgpool
rm -f /etc/tmpfiles.d/pgpool-II.conf
rm -f /etc/tmpfiles.d/pgpool.conf
log_success "Runtime files removed"

#-------------------------------------------------------------------------------
# Remove Log Files
#-------------------------------------------------------------------------------
log_info "Removing log files..."
rm -rf /var/log/pgpool*
log_success "Log files removed"

#-------------------------------------------------------------------------------
# Remove PCP Files
#-------------------------------------------------------------------------------
log_info "Removing PCP and other files..."
rm -f /var/run/postgresql/.s.PGSQL.9999
rm -f /tmp/.s.PGSQL.9999
rm -f /tmp/.s.PGSQL.9898
log_success "PCP files removed"

#-------------------------------------------------------------------------------
# Verify
#-------------------------------------------------------------------------------
log_info "Verifying cleanup..."
echo ""

if rpm -q pgpool-II &>/dev/null; then
    log_error "Pgpool-II package still installed!"
else
    log_success "Pgpool-II package: removed"
fi

if [[ -d /etc/pgpool-II ]]; then
    log_error "/etc/pgpool-II still exists!"
else
    log_success "/etc/pgpool-II: removed"
fi

if pgrep -x pgpool &>/dev/null; then
    log_error "Pgpool process still running!"
else
    log_success "Pgpool process: stopped"
fi

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
echo ""
echo "==============================================================================="
echo "                    CLEANUP COMPLETE"
echo "==============================================================================="
echo ""
echo "Pgpool-II has been completely removed."
echo ""
echo "To reinstall, run:"
echo "  ./pgpool_setup.sh <primary_ip> <standby_ip>"
echo ""
echo "==============================================================================="
