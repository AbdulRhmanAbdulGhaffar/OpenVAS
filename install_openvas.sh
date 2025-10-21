#!/bin/bash
# ============================================================
# OpenVAS (Greenbone Community Edition) Automated Installer
# For Kali Linux
# Author: AbdulRhman AbdulGhaffar (adapted)
# Purpose: Install, configure, enable services on boot, and display access info
# Usage: sudo bash install_openvas.sh
# ============================================================

set -euo pipefail
IFS=$'\n\t'

LOG="/tmp/gvm_install_$(date +%Y%m%d_%H%M%S).log"
SETUP_OUT="/tmp/gvm_setup_output.log"

echo "============================================================"
echo "   🟢 Starting Greenbone Community Edition (OpenVAS) Setup"
echo "   Log: $LOG"
echo "============================================================"

exec > >(tee -a "$LOG") 2>&1

function abort {
  echo
  echo "❌ Installer aborted due to an error. Check the log: $LOG"
  exit 1
}
trap abort ERR

# 1) Update & upgrade system
echo "[1/8] Updating and upgrading system..."
apt update -y && apt full-upgrade -y
apt autoremove -y
echo "✅ System packages updated."

# 2) Install gvm (OpenVAS)
echo "[2/8] Installing gvm package..."
apt install -y gvm
echo "✅ gvm package installed."

# 3) Run gvm-setup and capture output
echo "[3/8] Running gvm-setup (this may take several minutes)..."
# run and capture both stdout and stderr to SETUP_OUT
if sudo gvm-setup 2>&1 | tee "$SETUP_OUT"; then
    echo "✅ gvm-setup finished."
else
    echo "⚠️ gvm-setup returned non-zero exit code. Check $SETUP_OUT and $LOG"
fi

# 4) Try to extract admin password from setup output (multiple common patterns)
echo "[4/8] Extracting admin password from setup output..."
ADMIN_PASS=""

# Common patterns to search (case-insensitive)
# Examples: "admin password: <pw>" or "Password for user 'admin': <pw>" or "generated password for admin: <pw>"
ADMIN_PASS=$(grep -iE "admin( user)? (password|pwd)|password for user 'admin'|generated password for admin" "$SETUP_OUT" -m 1 -n || true)
if [ -n "$ADMIN_PASS" ]; then
    # extract last token (works in most cases)
    ADMIN_PASS=$(echo "$ADMIN_PASS" | sed -E 's/.*[:=]-?[[:space:]]*//I' | awk '{print $NF}')
fi

# If previous failed, try more heuristics: look for "admin" near a word that looks like a password
if [ -z "$ADMIN_PASS" ]; then
    # search lines that mention admin and a word of length >=6 <=60 (simple heuristic)
    ADMIN_PASS=$(grep -i "admin" "$SETUP_OUT" | grep -oE "[A-Za-z0-9@#%_\-]{6,60}" | head -n1 || true)
fi

if [ -n "$ADMIN_PASS" ]; then
    echo "✅ Admin password detected."
else
    echo "⚠️ Admin password NOT detected automatically. Please inspect: $SETUP_OUT"
fi

# 5) Verify installation
echo "[5/8] Verifying installation with gvm-check-setup..."
# run the checker (it may print guidance); don't fail the whole script on warnings
if sudo gvm-check-setup; then
    echo "✅ gvm-check-setup reports OK."
else
    echo "⚠️ gvm-check-setup reported issues. Review the output above and $LOG"
fi

# 6) Enable remote access (listen on 0.0.0.0) but keep port 9392
echo "[6/8] Enabling remote access (listen=0.0.0.0) while keeping port 9392..."
GSAD_SERVICE_FILE="/usr/lib/systemd/system/gsad.service"
if [ -f "$GSAD_SERVICE_FILE" ]; then
    sudo cp "$GSAD_SERVICE_FILE" "${GSAD_SERVICE_FILE}.bak"
    sudo sed -i 's/--listen=127.0.0.1/--listen=0.0.0.0/g' "$GSAD_SERVICE_FILE" || true
    echo "✅ gsad.service updated and backup saved as ${GSAD_SERVICE_FILE}.bak"
else
    echo "⚠️ gsad.service not found at $GSAD_SERVICE_FILE — skipping automatic edit."
fi

# Reload systemd and restart gsad if present
echo "[7/8] Reloading systemd and restarting services..."
sudo systemctl daemon-reload || true
# restart gsad if exists
if systemctl list-unit-files | grep -q '^gsad'; then
    sudo systemctl restart gsad || echo "⚠️ Failed to restart gsad (check service name)."
fi

# Ensure key GVM services are enabled to start at boot if available:
SERVICES_TO_ENABLE=(gsad gvmd ospd-openvas)
for svc in "${SERVICES_TO_ENABLE[@]}"; do
    if systemctl list-unit-files | grep -q "^${svc}"; then
        echo "Enabling $svc to start on boot..."
        sudo systemctl enable "$svc" || echo "⚠️ Failed to enable $svc"
    else
        echo "Note: $svc service not present (skipping enable)."
    fi
done

# 8) Start all GVM services (gvm-start); tolerate non-fatal failures
echo "[8/8] Starting all Greenbone services..."
if sudo gvm-start; then
    echo "✅ gvm-start succeeded. Services should be running."
else
    echo "⚠️ gvm-start returned non-zero. Check service status and $LOG"
fi

# Final: determine server IP to display
SERVER_IP=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++){ if ($i !~ /^127\\./) { print $i; exit } }}' || true)
if [ -z "$SERVER_IP" ]; then
    # fallback to ip route method
    SERVER_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7; exit}' || true)
fi
if [ -z "$SERVER_IP" ]; then
    SERVER_IP="127.0.0.1"
fi

echo
echo "============================================================"
echo "✅ OpenVAS (Greenbone CE) Installation finished."
echo
echo "Access the web interface at:"
echo "    https://$SERVER_IP:9392"
echo
echo "Login credentials:"
echo "    Username: admin"
if [ -n "${ADMIN_PASS:-}" ]; then
    echo "    Password: $ADMIN_PASS"
else
    echo "    Password: (not detected) — check $SETUP_OUT or the gvm-setup output above"
fi
echo
echo "Notes:"
echo " - Services enabled to start on boot (if service units existed): ${SERVICES_TO_ENABLE[*]}"
echo " - If you prefer port 443 (system HTTPS), you must update gsad.service and ensure you have valid TLS certs and root privileges."
echo " - Feed sync may take time; to update feeds manually run:"
echo "       sudo greenbone-feed-sync --type GVMD_DATA"
echo " - Logs and setup output:"
echo "       Installer log: $LOG"
echo "       gvm-setup capture: $SETUP_OUT"
echo "============================================================"

exit 0
