#!/bin/bash

# =============================================================================
# Greenbone Community Edition (GVM) Professional Installation Script for Kali Linux
#
# Description: This script automates the installation and configuration of GVM 
#              on Kali Linux based on the official documentation, with the 
#              following custom configurations:
#              1. Enables remote access to the web UI (from any IP).
#              2. Sets static credentials (admin/admin).
#              3. Enables GVM services to start automatically on boot.
#              4. Opens the default port (9392) in the UFW firewall.
#
# Author: Gemini
# Version: 2.3 (Explicit PostgreSQL version install)
# =============================================================================

# --- Color Definitions ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Main Function ---
main() {
    check_root
    prepare_system
    install_gvm
    ensure_postgres_running
    configure_gvm
    configure_remote_access
    increase_service_timeout
    enable_and_restart_services
    set_static_credentials
    configure_firewall
    final_summary
}

# --- Check for Root Privileges ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}Error: This script must be run as root.${NC}"
        echo -e "${YELLOW}Please use: sudo ./install_gvm.sh${NC}"
        exit 1
    fi
    # Exit immediately if a command exits with a non-zero status.
    set -e
}

# --- Prepare System ---
prepare_system() {
    echo -e "${GREEN}==> [Step 1/10] Performing a full system upgrade...${NC}"
    echo -e "${YELLOW}This process may take a while.${NC}"
    apt update
    apt full-upgrade -y
    echo -e "${GREEN}System updated successfully.${NC}"
}

# --- Install GVM ---
install_gvm() {
    echo -e "\n${GREEN}==> [Step 2/10] Installing GVM and PostgreSQL packages...${NC}"
    # Explicitly install the specific PostgreSQL version and common files
    # to prevent issues with missing binaries like 'initdb'.
    apt install gvm postgresql-16 postgresql-client-16 postgresql-common -y
    echo -e "${GREEN}GVM and PostgreSQL packages installed successfully.${NC}"
}

# --- Ensure PostgreSQL is Initialized and Running ---
ensure_postgres_running() {
    echo -e "\n${GREEN}==> [Step 3/10] Preparing PostgreSQL database...${NC}"
    # Ensure the service is enabled and started
    systemctl enable postgresql.service
    systemctl start postgresql.service

    # On some fresh systems, the cluster needs to be created
    # We check for the existence of the main config file
    if [ ! -f /etc/postgresql/16/main/postgresql.conf ]; then
        echo -e "${YELLOW}PostgreSQL cluster not found. Initializing new cluster...${NC}"
        pg_createcluster 16 main --start
        echo -e "${GREEN}Cluster created and started.${NC}"
    fi
    
    # Wait for a few seconds to ensure the socket is available
    echo -e "${YELLOW}Waiting for PostgreSQL to become fully active...${NC}"
    sleep 5
    
    # Final check
    if ! systemctl is-active --quiet postgresql.service; then
        echo -e "${RED}Error: PostgreSQL service failed to start!${NC}"
        echo -e "${YELLOW}Please check with 'systemctl status postgresql.service'${NC}"
        exit 1
    fi
    echo -e "${GREEN}PostgreSQL is running successfully.${NC}"
}


# --- Initial GVM Configuration ---
configure_gvm() {
    echo -e "\n${GREEN}==> [Step 4/10] Running initial GVM setup...${NC}"
    echo -e "${YELLOW}This process syncs the feeds and can take a very long time. Please be patient.${NC}"
    # Now run gvm-setup, which should find a working PostgreSQL instance
    gvm-setup
    echo -e "${GREEN}Initial setup completed.${NC}"
}

# --- Configure Remote Access ---
configure_remote_access() {
    echo -e "\n${GREEN}==> [Step 5/10] Configuring remote access...${NC}"
    local gsad_service_file="/usr/lib/systemd/system/gsad.service"
    if [ -f "$gsad_service_file" ]; then
        # Change listen address from localhost to any
        sed -i 's/--listen=127.0.0.1/--listen=0.0.0.0/' "$gsad_service_file"
        echo -e "${GREEN}gsad service file modified successfully.${NC}"
    else
        echo -e "${RED}Error: gsad.service file not found!${NC}"
        exit 1
    fi
}

# --- Increase GVMD Service Timeout ---
increase_service_timeout() {
    echo -e "\n${GREEN}==> [Step 6/10] Increasing gvmd service startup timeout...${NC}"
    local override_dir="/etc/systemd/system/gvmd.service.d"
    mkdir -p "$override_dir"
    cat > "${override_dir}/override.conf" << EOF
[Service]
# Allow gvmd more time to start, especially on slower systems or first run
TimeoutStartSec=600
EOF
    echo -e "${GREEN}Timeout increased to 10 minutes.${NC}"
}


# --- Enable and Restart Services (Robust Method) ---
enable_and_restart_services() {
    echo -e "\n${GREEN}==> [Step 7/10] Enabling GVM services for autostart...${NC}"
    systemctl daemon-reload # Reload after creating timeout override
    systemctl enable gsad.service gvmd.service ospd-openvas.service notus-scanner.service
    echo -e "${GREEN}Services enabled successfully.${NC}"

    echo -e "\n${GREEN}==> [Step 8/10] Migrating database and restarting GVM services...${NC}"
    
    # Stop all services to ensure a clean start
    echo -e "${YELLOW}Stopping all GVM services...${NC}"
    systemctl stop gsad.service || true
    systemctl stop gvmd.service || true
    systemctl stop ospd-openvas.service || true
    systemctl stop notus-scanner.service || true

    # Run DB migration as a critical pre-start step
    echo -e "${GREEN}Running GVM database migration...${NC}"
    runuser -u _gvm -- gvmd --migrate || { echo -e "${RED}GVMD database migration failed!${NC}"; exit 1; }
    echo -e "${GREEN}Database migration successful.${NC}"

    # Start services in order
    echo -e "${GREEN}Starting scanner services (ospd-openvas, notus-scanner)...${NC}"
    systemctl start ospd-openvas.service
    systemctl start notus-scanner.service

    echo -e "${GREEN}Starting Greenbone Vulnerability Manager (gvmd)...${NC}"
    systemctl start gvmd.service

    # Wait for gvmd to be fully ready by polling it
    echo -e "${YELLOW}Waiting for GVMD to become responsive... (This may take a couple of minutes)${NC}"
    local counter=0
    local max_wait=600 # 10 minutes timeout to match systemd
    while ! runuser -u _gvm -- gvmd --get-users &>/dev/null; do
        sleep 2
        counter=$((counter+2))
        if [ $counter -ge $max_wait ]; then
            echo -e "\n${RED}Error: GVMD failed to start within the timeout period.${NC}"
            echo -e "${RED}Please run 'journalctl -xeu gvmd.service' for diagnostics.${NC}"
            exit 1
        fi
        echo -n "."
    done
    echo -e "\n${GREEN}GVMD is ready.${NC}"

    echo -e "${GREEN}Starting Greenbone Security Assistant (gsad)...${NC}"
    systemctl start gsad.service

    echo -e "${GREEN}All GVM services have been restarted successfully.${NC}"
}

# --- Set Static Password for Admin User ---
set_static_credentials() {
    echo -e "\n${GREEN}==> [Step 9/10] Setting a static password for the 'admin' user...${NC}"
    # This is run after services have been restarted to ensure gvmd is responsive.
    runuser -u _gvm -- gvmd --user=admin --new-password=admin
    echo -e "${GREEN}Password successfully set to 'admin'.${NC}"
}

# --- Configure Firewall ---
configure_firewall() {
    echo -e "\n${GREEN}==> [Step 10/10] Configuring the firewall (UFW)...${NC}"
    # Install UFW if it's not already installed
    if ! command -v ufw &> /dev/null; then
        echo -e "${YELLOW}UFW is not installed. Installing...${NC}"
        apt install ufw -y
    fi
    ufw allow 9392/tcp
    # Enable UFW and assume yes to the prompt
    echo "y" | ufw enable
    ufw status
    echo -e "${GREEN}Firewall configured to allow traffic on port 9392.${NC}"
}

# --- Final Summary ---
final_summary() {
    IP_ADDRESS=$(hostname -I | awk '{print $1}')
    echo -e "\n\n${GREEN}=====================================================================${NC}"
    echo -e "${GREEN}     🎉 GVM Installation and Setup Completed Successfully! 🎉          ${NC}"
    echo -e "${GREEN}=====================================================================${NC}"
    echo -e "\nYou can now access the Greenbone web interface:"
    echo -e "${YELLOW}Access URL: https://${IP_ADDRESS}:9392${NC}"
    echo -e "\nLogin Credentials:"
    echo -e "${YELLOW}Username: admin${NC}"
    echo -e "${YELLOW}Password: admin${NC}"
    echo -e "\n${RED}Important Note:${NC} After logging in for the first time, you may need to wait for"
    echo -e "the feeds to finish syncing and updating."
    echo -e "You can check the status on the 'Feed Status' page in the web UI."
    echo -e "\nTo check the installation status manually, you can run the following command:"
    echo -e "${YELLOW}sudo gvm-check-setup${NC}\n"
}

# --- Start Script Execution ---
main

