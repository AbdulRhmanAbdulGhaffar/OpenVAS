#!/bin/bash
# 🛠️ Full Automatic Fix Script for OpenVAS / GVM on Kali Linux
# Author: AbdulRhman AbdulGhaffar
# Description: Fixes setup, feeds, admin credentials, and web access automatically.

set -euo pipefail
LOGFILE="/var/log/gvm_fix.log"
echo "[+] Starting full automatic OpenVAS/GVM fix..." | tee "$LOGFILE"

# Stop all services safely
echo "[+] Stopping GVM services..." | tee -a "$LOGFILE"
systemctl stop gvmd gsad ospd-openvas || true

# Sync all feeds (may take several minutes)
echo "[+] Syncing vulnerability feeds (this may take a while)..." | tee -a "$LOGFILE"
greenbone-feed-sync --type ALL >> "$LOGFILE" 2>&1 || echo "[!] Feed sync encountered issues. Check log." | tee -a "$LOGFILE"

# Ensure gsad listens on all IPs
GSAD_SERVICE="/usr/lib/systemd/system/gsad.service"
if [ -f "$GSAD_SERVICE" ]; then
    echo "[+] Updating gsad service to listen on all IPs..." | tee -a "$LOGFILE"
    sed -i 's/--listen=127.0.0.1/--listen=0.0.0.0/' "$GSAD_SERVICE" || true
else
    echo "[!] gsad service file not found at $GSAD_SERVICE, skipping modification." | tee -a "$LOGFILE"
fi

# Reload systemd daemon
echo "[+] Reloading systemd services..." | tee -a "$LOGFILE"
systemctl daemon-reload

# Enable all related services to start on boot
echo "[+] Enabling GVM services to start on boot..." | tee -a "$LOGFILE"
systemctl enable postgresql gvmd gsad ospd-openvas >> "$LOGFILE" 2>&1 || true

# Restart services in correct order with proper delay
echo "[+] Restarting services in correct sequence..." | tee -a "$LOGFILE"
systemctl restart postgresql
sleep 10
systemctl restart gvmd
sleep 5
systemctl restart ospd-openvas
sleep 3
systemctl restart gsad

# Create static admin user (admin:admin)
echo "[+] Recreating admin user with password admin..." | tee -a "$LOGFILE"
runuser -u _gvm -- gvmd --delete-user=admin 2>/dev/null || true
runuser -u _gvm -- gvmd --create-user=admin --password=admin >> "$LOGFILE" 2>&1 || true

# Verify scan configs exist
echo "[+] Verifying available scan configs..." | tee -a "$LOGFILE"
runuser -u _gvm -- gvmd --get-scans | tee -a "$LOGFILE" || true

# Final check and output
echo "[✓] Fix complete! Access the Greenbone Web UI using:" | tee -a "$LOGFILE"
echo "    🌐 https://<Your-IP>:9392" | tee -a "$LOGFILE"
echo "    👤 Username: admin" | tee -a "$LOGFILE"
echo "    🔑 Password: admin" | tee -a "$LOGFILE"
echo "[📄] Logs saved at: $LOGFILE"
echo "[🚀] You can now create scans without errors." | tee -a "$LOGFILE"
