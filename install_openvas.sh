#!/bin/bash

# GVM (Greenbone Vulnerability Manager) Professional Installer for Kali Linux
# This script automates the installation and configuration process.
#
# What it does:
# 1. Checks for root privileges.
# 2. Updates and upgrades the system.
# 3. Installs the GVM package.
# 4. Runs the initial gvm-setup.
# 5. Configures the web interface (GSA) to be accessible from any IP address.
# 6. Sets the admin user's password to 'admin'.
# 7. Enables GVM services to start automatically on boot.
# 8. Verifies the installation.

# --- Color Codes for Output ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Step 1: Check for Root Privileges ---
echo -e "${GREEN}[*] Checking for root privileges...${NC}"
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[!] Error: This script must be run as root. Please use 'sudo ./install_gvm.sh'.${NC}"
  exit 1
fi
echo -e "${GREEN}[+] Privileges check passed.${NC}\n"

# --- Step 2: Update System ---
echo -e "${GREEN}[*] Updating package lists and performing a full system upgrade...${NC}"
apt update && apt full-upgrade -y
if [ $? -ne 0 ]; then
    echo -e "${RED}[!] Error: Failed to update the system. Please check your network connection and repositories.${NC}"
    exit 1
fi
echo -e "${GREEN}[+] System updated successfully.${NC}\n"

# --- Step 3: Install GVM ---
echo -e "${GREEN}[*] Installing Greenbone Vulnerability Manager (gvm)...${NC}"
apt install gvm -y
if [ $? -ne 0 ]; then
    echo -e "${RED}[!] Error: Failed to install GVM package.${NC}"
    exit 1
fi
echo -e "${GREEN}[+] GVM package installed successfully.${NC}\n"

# --- Step 4: Initial GVM Setup ---
echo -e "${YELLOW}[*] Running initial GVM setup. This process will take a considerable amount of time to sync the feeds...${NC}"
gvm-setup
if [ $? -ne 0 ]; then
    echo -e "${RED}[!] Error: gvm-setup failed. Please check the output for errors.${NC}"
    exit 1
fi
echo -e "${GREEN}[+] Initial GVM setup completed.${NC}\n"

# --- Step 5: Configure Remote Access ---
GSA_SERVICE_FILE="/usr/lib/systemd/system/gsad.service"
echo -e "${GREEN}[*] Configuring Greenbone Security Assistant (GSA) for remote access...${NC}"
if [ -f "$GSA_SERVICE_FILE" ]; then
    sed -i 's/--listen=127.0.0.1/--listen=0.0.0.0/' "$GSA_SERVICE_FILE"
    echo -e "${GREEN}[+] GSA configured to listen on all interfaces (0.0.0.0).${NC}\n"
else
    echo -e "${RED}[!] Error: GSA service file not found at $GSA_SERVICE_FILE. Cannot configure remote access.${NC}"
fi

# --- Step 6: Set Admin Password ---
echo -e "${YELLOW}[*] Setting the 'admin' user password to 'admin'...${NC}"
# The command must be run as the _gvm user to have permissions
sudo -u _gvm gvmd --user=admin --new-password=admin
if [ $? -ne 0 ]; then
    echo -e "${RED}[!] Error: Failed to set the admin password. The user may not exist yet.${NC}"
    echo -e "${YELLOW}[*] Note: The password can be set manually later.${NC}"
fi
echo -e "${GREEN}[+] Admin password has been set.${NC}\n"

# --- Step 7: Enable and Start Services on Boot ---
echo -e "${GREEN}[*] Reloading systemd, enabling and starting GVM services...${NC}"
systemctl daemon-reload
systemctl enable gvmd ospd-openvas gsad
systemctl restart gvmd ospd-openvas gsad
echo -e "${GREEN}[+] GVM services have been enabled and started.${NC}\n"

# --- Step 8: Verify Installation ---
echo -e "${YELLOW}[*] Running gvm-check-setup to verify the installation. Please review the output carefully.${NC}"
gvm-check-setup
echo -e "${GREEN}[+] Verification script finished.${NC}\n"

# --- Final Instructions ---
IP_ADDR=$(hostname -I | awk '{print $1}')
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}      GVM Installation & Configuration Complete!      ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "\n"
echo -e "You can now access the Greenbone web interface at:"
echo -e "URL:      ${YELLOW}https://${IP_ADDR}:9392${NC}"
echo -e "\n"
echo -e "Credentials:"
echo -e "Username: ${YELLOW}admin${NC}"
echo -e "Password: ${YELLOW}admin${NC}"
echo -e "\n"
echo -e "${RED}[!] SECURITY WARNING:${NC}"
echo -e "${YELLOW}The password 'admin' is highly insecure. It is STRONGLY recommended to change it immediately after your first login for security purposes.${NC}"
echo -e "\n"
echo -e "It may take some time for the feeds to fully sync. You can check the status in the web UI under 'Administration' -> 'Feed Status'."
echo -e "If you encounter issues, run 'sudo gvm-check-setup' again for diagnostics."
echo -e "\n"
