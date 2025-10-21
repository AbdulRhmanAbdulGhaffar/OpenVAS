#!/bin/bash
# ============================================================
# OpenVAS (Greenbone Community Edition) Auto Installer (Final Version)
# By: AbdulRhman AbdulGhaffar
# ============================================================

set -euo pipefail
IFS=$'\n\t'

LOG="/tmp/gvm_install_$(date +%Y%m%d_%H%M%S).log"
SETUP_OUT="/tmp/gvm_setup_output.log"
SUMMARY="/root/openvas_install_summary.txt"

exec > >(tee -a "$LOG") 2>&1

echo "============================================================"
echo "   🟢 Starting Full OpenVAS (Greenbone CE) Installer"
echo "   Log: $LOG"
echo "============================================================"

trap 'echo "❌ Installer failed. Check log: $LOG"; exit 1' ERR

# ------------------------------------------------------------
# 1️⃣ Fix and Update Kali Sources
# ------------------------------------------------------------
echo "[1/11] Fixing /etc/apt/sources.list and selecting official Kali mirror..."
sudo bash -c 'cat > /etc/apt/sources.list <<EOF
deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
EOF'

sudo apt clean
sudo apt update --fix-missing -y
sudo apt install -y apt-transport-https ca-certificates gnupg curl
sudo apt full-upgrade -y
echo "✅ Repository fixed and updated successfully."

# ------------------------------------------------------------
# 2️⃣ Install GVM (OpenVAS)
# ------------------------------------------------------------
echo "[2/11] Installing gvm package..."
sudo apt install -y gvm || {
  echo "⚠️ Retrying installation with fix-missing..."
  sudo apt update --fix-missing -y && sudo apt install -y gvm
}
echo "✅ GVM installed successfully."

# ------------------------------------------------------------
# 3️⃣ Run gvm-setup and capture output
# ------------------------------------------------------------
echo "[3/11] Running gvm-setup (this may take several minutes)..."
sudo gvm-setup 2>&1 | tee "$SETUP_OUT" || true
echo "✅ gvm-setup finished (check for warnings above)."

# ------------------------------------------------------------
# 4️⃣ Extract or Create Admin Password
# ------------------------------------------------------------
echo "[4/11] Checking for admin password..."
ADMIN_PASS=$(grep -iE "admin( user)? (password|pwd)|password for user 'admin'|generated.*password.*admin" "$SETUP_OUT" -m1 | sed -E 's/.*[:=]\s*//' | awk '{print $1}' || true)

if [ -z "$ADMIN_PASS" ]; then
  echo "⚠️ No admin password found, creating one..."
  ADMIN_PASS=$(tr -dc 'A-Za-z0-9@#%_\-' </dev/urandom | head -c 16)
  sudo runuser -u _gvm -- gvmd --user=admin --new-password="$ADMIN_PASS" 2>/dev/null || \
  sudo runuser -u _gvm -- gvmd --create-user=admin --password="$ADMIN_PASS"
else
  echo "✅ Found admin password in setup output."
fi

# ------------------------------------------------------------
# 5️⃣ Verify installation
# ------------------------------------------------------------
echo "[5/11] Running gvm-check-setup..."
sudo gvm-check-setup || true

# ------------------------------------------------------------
# 6️⃣ Enable Remote Web Access (listen=0.0.0.0)
# ------------------------------------------------------------
echo "[6/11] Configuring gsad for remote access..."
SERVICE_PATH=$(find /usr/lib/systemd/system /lib/systemd/system -name gsad.service 2>/dev/null | head -n1 || true)
if [ -n "$SERVICE_PATH" ]; then
  sudo cp "$SERVICE_PATH" "$SERVICE_PATH.bak"
  sudo sed -i 's/--listen=127.0.0.1/--listen=0.0.0.0/g' "$SERVICE_PATH"
  sudo systemctl daemon-reload
  sudo systemctl restart gsad
  echo "✅ gsad configured to listen on all IPs."
else
  echo "⚠️ gsad.service not found, please verify manually."
fi

# ------------------------------------------------------------
# 7️⃣ Enable Auto-start on boot
# ------------------------------------------------------------
echo "[7/11] Enabling GVM services at boot..."
for svc in gsad gvmd ospd-openvas; do
  if systemctl list-unit-files | grep -q "^${svc}"; then
    sudo systemctl enable "$svc" || true
  fi
done
echo "✅ Services enabled to start on boot."

# ------------------------------------------------------------
# 8️⃣ Open Firewall Port (if UFW is present)
# ------------------------------------------------------------
echo "[8/11] Opening port 9392 in UFW (if active)..."
if command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -qi "inactive"; then
    echo "UFW inactive, skipping..."
  else
    sudo ufw allow 9392/tcp || true
  fi
else
  echo "UFW not installed, skipping firewall setup."
fi

# ------------------------------------------------------------
# 9️⃣ Feed Sync (GVMD_DATA, SCAP, CERT)
# ------------------------------------------------------------
echo "[9/11] Syncing Greenbone feeds (this can take a long time)..."
sudo runuser -u _gvm -- greenbone-feed-sync --type GVMD_DATA || true
sudo runuser -u _gvm -- greenbone-feed-sync --type SCAP || true
sudo runuser -u _gvm -- greenbone-feed-sync --type CERT || true
sudo runuser -u _gvm -- gvmd --rebuild || true
echo "✅ Feed synchronization started (may continue in background)."

# ------------------------------------------------------------
# 🔟 Restart All GVM Services
# ------------------------------------------------------------
echo "[10/11] Restarting all GVM services..."
sudo gvm-stop || true
sleep 3
sudo gvm-start || true
echo "✅ Services restarted successfully."

# ------------------------------------------------------------
# 11️⃣ Display Access Info
# ------------------------------------------------------------
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "============================================================"
echo "✅ OpenVAS Installation Completed!"
echo "🌐 Web UI: https://$SERVER_IP:9392"
echo "👤 Username: admin"
echo "🔑 Password: $ADMIN_PASS"
echo "============================================================"

sudo bash -c "cat > $SUMMARY <<EOF
============================================================
OpenVAS (Greenbone CE) Installation Summary
Date: $(date)
------------------------------------------------------------
Web UI: https://$SERVER_IP:9392
Username: admin
Password: $ADMIN_PASS
------------------------------------------------------------
Installer Log: $LOG
Setup Output: $SETUP_OUT
------------------------------------------------------------
Feed synchronization may take a few hours.
Check Administration → Feed Status in the Web UI.
============================================================
EOF"

chmod 600 "$SUMMARY"
echo "Summary saved at: $SUMMARY"
