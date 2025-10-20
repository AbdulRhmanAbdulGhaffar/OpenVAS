#!/usr/bin/env bash
# 🧹 Full Uninstall Script for OpenVAS / Greenbone (GVM)
# Author: AbdulRhman AbdulGhaffar
# Description: Safely removes all GVM/OpenVAS components, configs, DBs & logs.

set -euo pipefail
LOGFILE="/var/log/gvm_uninstall.log"
DATE=$(date '+%Y-%m-%d_%H-%M-%S')

echo "🧹 Starting full GVM/OpenVAS removal process..."
echo "📄 Log file: $LOGFILE"
sleep 1

log() {
  echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"
}

log "1️⃣ Stopping all running GVM services..."
sudo gvm-stop >/dev/null 2>&1 || true
sudo systemctl stop gvmd gsad ospd-openvas >/dev/null 2>&1 || true

log "2️⃣ Removing all related packages..."
sudo apt purge --auto-remove -y gvm openvas* greenbone* ospd* libgvm* postgresql-*-pg-gvm >> "$LOGFILE" 2>&1 || true

log "3️⃣ Deleting configuration and data directories..."
sudo rm -rf /var/lib/gvm /var/lib/openvas /var/log/gvm /etc/gvm /etc/openvas /usr/local/var/lib/gvm /usr/local/var/lib/openvas >> "$LOGFILE" 2>&1 || true

log "4️⃣ Dropping PostgreSQL database and role (if exist)..."
sudo -u postgres psql -c "DROP DATABASE IF EXISTS gvmd;" >> "$LOGFILE" 2>&1 || true
sudo -u postgres psql -c "DROP ROLE IF EXISTS gvm;" >> "$LOGFILE" 2>&1 || true

log "5️⃣ Cleaning orphaned packages and cache..."
sudo apt autoremove -y >> "$LOGFILE" 2>&1
sudo apt autoclean -y >> "$LOGFILE" 2>&1

log "6️⃣ Checking for leftovers..."
dpkg -l | grep -E 'gvm|openvas' && log "⚠️ Some remnants found!" || log "✅ No remnants detected."

log "7️⃣ All done! GVM/OpenVAS completely removed 🎯"
log "🪄 You can now reinstall cleanly using:"
log "   sudo ./install_gvm.sh --remote --port 443"

echo
echo "✨ Completed at $DATE"
echo "📘 Logs saved to $LOGFILE"
