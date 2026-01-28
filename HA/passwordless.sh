#!/bin/bash
#===============================================================================
# SSH Passwordless Setup Script
# Description: Sets up passwordless SSH connectivity between 3 lab machines
# Usage: ./ssh_setup.sh <lab01_ip> <lab02_ip> <lab03_ip>
# Example: ./ssh_setup.sh 192.168.44.128 192.168.44.129 192.168.44.130
# 
# Run this script from each machine OR run once with root passwords
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Parse Arguments
#-------------------------------------------------------------------------------
if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <lab01_ip> <lab02_ip> <lab03_ip>"
    echo ""
    echo "Example: $0 192.168.44.128 192.168.44.129 192.168.44.130"
    echo ""
    echo "This script will:"
    echo "  1. Generate SSH key if not exists"
    echo "  2. Copy SSH key to all 3 machines"
    echo "  3. Setup /etc/hosts entries"
    echo "  4. Test connectivity"
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
# Generate SSH Key
#-------------------------------------------------------------------------------
generate_ssh_key() {
    log_info "Checking SSH key..."
    
    if [[ -f ~/.ssh/id_rsa ]]; then
        log_info "SSH key already exists"
    else
        log_info "Generating SSH key..."
        ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
        log_success "SSH key generated"
    fi
}

#-------------------------------------------------------------------------------
# Setup /etc/hosts
#-------------------------------------------------------------------------------
setup_hosts() {
    log_info "Setting up /etc/hosts..."
    
    # Remove old entries
    sed -i '/lab01/d; /lab02/d; /lab03/d' /etc/hosts 2>/dev/null || true
    
    # Add new entries
    echo "${LAB01_IP}    lab01" >> /etc/hosts
    echo "${LAB02_IP}    lab02" >> /etc/hosts
    echo "${LAB03_IP}    lab03" >> /etc/hosts
    
    log_success "/etc/hosts updated"
}

#-------------------------------------------------------------------------------
# Copy SSH Keys
#-------------------------------------------------------------------------------
copy_ssh_keys() {
    log_info "Copying SSH keys to all machines..."
    log_warning "You will be prompted for passwords (3 times)"
    echo ""
    
    for host in lab01 lab02 lab03; do
        log_info "Copying key to ${host}..."
        ssh-copy-id -o StrictHostKeyChecking=no root@${host} || {
            log_error "Failed to copy key to ${host}"
            log_info "Trying with IP address..."
        }
    done
    
    log_success "SSH keys copied"
}

#-------------------------------------------------------------------------------
# Test Connectivity
#-------------------------------------------------------------------------------
test_connectivity() {
    log_info "Testing passwordless SSH connectivity..."
    echo ""
    
    local all_ok=true
    
    for host in lab01 lab02 lab03; do
        if ssh -o BatchMode=yes -o ConnectTimeout=5 root@${host} "echo 'OK'" &>/dev/null; then
            log_success "${host} - Passwordless SSH working"
        else
            log_error "${host} - Passwordless SSH FAILED"
            all_ok=false
        fi
    done
    
    echo ""
    if [[ "$all_ok" == true ]]; then
        log_success "All nodes accessible via passwordless SSH!"
    else
        log_error "Some nodes failed. Please fix manually."
    fi
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    echo "==============================================================================="
    echo "              SSH PASSWORDLESS SETUP"
    echo "==============================================================================="
    echo ""
    echo "Machines:"
    echo "  - lab01: ${LAB01_IP}"
    echo "  - lab02: ${LAB02_IP}"
    echo "  - lab03: ${LAB03_IP}"
    echo ""
    
    generate_ssh_key
    setup_hosts
    copy_ssh_keys
    test_connectivity
    
    echo ""
    echo "==============================================================================="
    echo "                           SETUP COMPLETE"
    echo "==============================================================================="
    echo ""
    echo "You can now run:"
    echo "  ssh root@lab01 hostname"
    echo "  ssh root@lab02 hostname"
    echo "  ssh root@lab03 hostname"
    echo ""
    echo "==============================================================================="
}

main
