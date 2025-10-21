#!/bin/bash

#================================================================================
# Script to install and configure Greenbone Community Edition (OpenVAS) on Kali Linux.
# Author: Gemini
# Description: This script automates the installation process based on the official
# documentation, enables remote access to the web UI, and displays the
# final credentials.
#================================================================================

# --- Style Functions ---
print_info() {
    echo -e "\n\e[1;34m[INFO]\e[0m $1"
}

print_success() {
    echo -e "\e[1;32m[SUCCESS]\e[0m $1"
}

print_error() {
    echo -e "\e[1;31m[ERROR]\e[0m $1" >&2
}

print_warning() {
    echo -e "\e[1;33m[WARNING]\e[0m $1"
}

# --- Pre-run Checks ---
# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
   print_error "This script must be run as root. Please use sudo."
   exit 1
fi

# --- Main Installation Logic ---
# Step 1: Update and Upgrade Kali Linux
print_info "Starting system update and full upgrade. This may take a while..."
apt-get update && apt-get dist-upgrade -y
if [ $? -ne 0 ]; then
    print_error "Failed to update or upgrade the system. Please check your network connection and repositories."
    exit 1
fi
print_success "System updated and upgraded successfully."

# Step 2: Install Greenbone Vulnerability Manager (GVM)
print_info "Installing GVM packages..."
apt-get install gvm -y
if [ $? -ne 0 ]; then
    print_error "Failed to install GVM packages."
    exit 1
fi
print_success "GVM packages installed successfully."

# Step 3: Run the setup and capture the admin password
print_info "Running gvm-setup. This will download feeds and configure the system. This is a long process..."
GVM_SETUP_LOG="/tmp/gvm-setup.log"
gvm-setup > "$GVM_SETUP_LOG" 2>&1

# Check if setup was successful by looking for the password line
if ! grep -q "User admin created with password" "$GVM_SETUP_LOG"; then
    print_error "gvm-setup failed. Please check the log for details: $GVM_SETUP_LOG"
    cat "$GVM_SETUP_LOG"
    exit 1
fi

ADMIN_PASSWORD=$(grep 'User admin created with password' "$GVM_SETUP_LOG" | awk '{print $NF}')
print_success "gvm-setup completed."

# Clean up the log file
rm "$GVM_SETUP_LOG"

# Step 4: Configure Remote Access to the Web Interface
GSAD_SERVICE_FILE="/lib/systemd/system/gsad.service"
print_info "Configuring remote access to the GSA web interface..."
if [ -f "$GSAD_SERVICE_FILE" ]; then
    # Change the listen address from 127.0.0.1 to 0.0.0.0
    sed -i 's/--listen=127.0.0.1/--listen=0.0.0.0/' "$GSAD_SERVICE_FILE"
    print_info "Reloading systemd daemon and restarting gsad service..."
    systemctl daemon-reload
    systemctl restart gsad.service
    print_success "Web interface configured for remote access."
else
    print_warning "Could not find gsad.service file at $GSAD_SERVICE_FILE. Skipping remote access configuration."
fi

# Step 5: Verify the installation
print_info "Running gvm-check-setup to verify the installation..."
gvm-check-setup

# Final Step: Display login credentials
print_info "Starting GVM services..."
gvm-start

SERVER_IP=$(hostname -I | awk '{print $1}')

if [ -z "$ADMIN_PASSWORD" ]; then
    print_error "Could not extract the admin password. Please run 'sudo gvm-setup' manually to check."
    exit 1
fi

echo
print_success "Installation and configuration complete!"
echo -e "\e[1m================================================================\e[0m"
echo -e "  \e[1;32mGreenbone Vulnerability Manager (OpenVAS) Login Details\e[0m"
echo -e "\e[1m================================================================\e[0m"
echo
echo -e "  \e[1;34mURL:\e[0m      \e[1;37mhttps://${SERVER_IP}:9392\e[0m"
echo -e "  \e[1;34mUsername:\e[0m \e[1;37madmin\e[0m"
echo -e "  \e[1;34mPassword:\e[0m \e[1;31m${ADMIN_PASSWORD}\e[0m"
echo
echo -e "\e[1m================================================================\e[0m"
print_warning "It may take some time for all services to start and for the feeds to be fully updated. If you can't log in, please wait a few minutes and try again."
echo
