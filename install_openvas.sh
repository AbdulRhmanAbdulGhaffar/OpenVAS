#!/usr/bin/env bash
# =============================================================
# OpenVAS (Greenbone CE) Smart Installer - keeps port 9392
# - Fixes Kali sources, installs GVM, waits for feed lock (smart)
# - Generates/sets admin password, enables services, opens UFW port
# Author: adapted for AbdulRhman
# Usage: sudo bash install_openvas_smart.sh
# =============================================================
set -euo pipefail
IFS=$'\n\t'

# CONFIG
LOCK_FILE="/var/lib/gvm/feed-update.lock"
LOCK_WAIT_TIMEOUT_MIN=30   # total minutes to wait for other feed-sync to finish
LOCK_POLL_INTERVAL=5       # seconds between checks
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG="/tmp/gvm_install_${TIMESTAMP}.log"
SETUP_OUT="/tmp/gvm_setup_output_${TIMESTAMP}.log"
SUMMARY="/root/openvas_install_summary_${TIMESTAMP}.txt"

exec > >(tee -a "$LOG") 2>&1

trap 'echo "ERROR: Installer failed. See $LOG"; exit 1' ERR

echo "============================================================"
echo "OpenVAS Smart Installer (keeping port 9392) - $(date)"
echo "Log: $LOG"
echo "Setup capture: $SETUP_OUT"
echo "Summary will be written to: $SUMMARY"
echo "============================================================"

# Helper
step() { echo; echo "---- $1"; echo; }

# 1) Fix Kali sources.list to official mirror (safe overwrite)
step "1) Ensuring official Kali mirror in /etc/apt/sources.list"
sudo bash -c 'cat > /etc/apt/sources.list <<EOF
deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
EOF'
sudo apt clean
# ensure TLS packages for apt
sudo apt update --fix-missing -y || sudo apt update --fix-missing -y
sudo apt install -y apt-transport-https ca-certificates gnupg curl || true

# 2) Update & upgrade
step "2) Update and upgrade system packages"
sudo apt update --fix-missing -y
sudo apt full-upgrade -y
sudo apt autoremove -y

# 3) Install gvm with retry
step "3) Install gvm (Greenbone Community Edition)"
if ! sudo apt install -y gvm; then
  echo "First attempt to install gvm failed — running apt update --fix-missing and retrying"
  sudo apt update --fix-missing -y
  sudo apt install -y gvm
fi
echo "gvm package install attempted."

# 4) Run gvm-setup (capture output)
step "4) Running gvm-setup (captures output to $SETUP_OUT). This may take several minutes."
# gvm-setup sometimes prints prompts; capture everything
if sudo gvm-setup 2>&1 | tee "$SETUP_OUT"; then
  echo "gvm-setup completed."
else
  echo "gvm-setup returned non-zero. Continuing to attempt fixes and sync."
fi

# 5) Determine admin password or create one and apply to gvmd
step "5) Detect or create admin password"
ADMIN_PASS=""
# Try to extract from captured output and some known log paths
for f in "$SETUP_OUT" /var/log/gvm/setup.log /var/log/openvas/setup.log /var/log/gvm/gvmd.log; do
  if [ -f "$f" ]; then
    candidate=$(grep -iE "admin( user)? (password|pwd)|password for user 'admin'|generated.*password.*admin" "$f" -m1 || true)
    if [ -n "$candidate" ]; then
      token=$(echo "$candidate" | sed -E 's/.*[:=]\s*//' | awk '{print $1}')
      if [ -n "$token" ]; then ADMIN_PASS="$token" && break; fi
    fi
  fi
done

# If not found, generate a secure random password and apply
if [ -z "${ADMIN_PASS:-}" ]; then
  echo "No admin password found in logs; generating a secure password."
  ADMIN_PASS=$(tr -dc 'A-Za-z0-9@%_-+' </dev/urandom | head -c 20)
  # Apply to gvmd (if gvmd ready), else create admin user
  if sudo runuser -u _gvm -- gvmd --get-users >/dev/null 2>&1; then
    sudo runuser -u _gvm -- gvmd --user=admin --new-password="${ADMIN_PASS}" 2>/dev/null || {
      echo "Setting admin password failed — attempting to create admin user"
      sudo runuser -u _gvm -- gvmd --create-user=admin --password="${ADMIN_PASS}" 2>/dev/null || true
    }
  else
    echo "gvmd not available yet; admin password will be set later if needed."
  fi
else
  echo "Found admin password in setup output (hidden). Applying to gvmd to ensure it is set."
  sudo runuser -u _gvm -- gvmd --user=admin --new-password="${ADMIN_PASS}" >/dev/null 2>&1 || true
fi

# 6) Run gvm-check-setup (do not abort on warnings)
step "6) Run gvm-check-setup to detect issues"
sudo gvm-check-setup || echo "gvm-check-setup reported issues or warnings. Check above logs."

# 7) Configure gsad to listen on 0.0.0.0:9392 (safe)
step "7) Configure gsad service to listen on 0.0.0.0 and keep port 9392"
GSAD_UNIT_CANDIDATES=(
  "/usr/lib/systemd/system/gsad.service"
  "/lib/systemd/system/gsad.service"
  "/etc/systemd/system/gsad.service"
)
GSAD_UNIT=""
for p in "${GSAD_UNIT_CANDIDATES[@]}"; do
  if [ -f "$p" ]; then GSAD_UNIT="$p" && break; fi
done

if [ -n "$GSAD_UNIT" ]; then
  echo "Found gsad unit: $GSAD_UNIT (backup saved)"
  sudo cp "$GSAD_UNIT" "${GSAD_UNIT}.bak_${TIMESTAMP}"
  # replace --listen argument; leave port untouched
  sudo sed -i -E "s/--listen=127(\\.0\\.0\\.1)?/--listen=0.0.0.0/g" "$GSAD_UNIT" || true
  sudo systemctl daemon-reload
  sudo systemctl restart gsad || echo "Warning: could not restart gsad. Check service status."
else
  echo "gsad systemd unit not found in common locations. Manual fix may be required."
fi

# 8) Enable GVM services at boot if present
step "8) Enable GVM services at boot"
SERVICES=(gsad gvmd ospd-openvas)
for svc in "${SERVICES[@]}"; do
  if systemctl list-unit-files | grep -q "^${svc}"; then
    sudo systemctl enable "$svc" || echo "Warning: could not enable $svc"
  fi
done

# 9) Open UFW port 9392 if UFW is present and active
step "9) Open firewall on port 9392 (UFW)"
if command -v ufw >/dev/null 2>&1; then
  if ! sudo ufw status | grep -qi "inactive"; then
    sudo ufw allow 9392/tcp || echo "Warning: ufw allow 9392 failed"
  else
    echo "UFW inactive; skipping UFW rule."
  fi
else
  echo "UFW not installed; skipping firewall automation."
fi

# 10) Smart wait for feed-update.lock (another feed-sync running) - with timeout
step "10) Waiting for other feed-sync processes (if any) to finish (timeout: ${LOCK_WAIT_TIMEOUT_MIN} minutes)"
wait_seconds=$(( LOCK_WAIT_TIMEOUT_MIN * 60 ))
elapsed=0
if [ -f "$LOCK_FILE" ]; then
  echo "Detected lock file $LOCK_FILE. Will wait up to ${LOCK_WAIT_TIMEOUT_MIN} minutes for it to be released."
else
  echo "No lock file detected; proceeding to run feed-sync."
fi

while [ -f "$LOCK_FILE" ] && [ $elapsed -lt $wait_seconds ]; do
  # show who holds it (if possible)
  if command -v lsof >/dev/null 2>&1; then
    lsof "$LOCK_FILE" || true
  fi
  sleep "$LOCK_POLL_INTERVAL"
  elapsed=$(( elapsed + LOCK_POLL_INTERVAL ))
done

if [ -f "$LOCK_FILE" ]; then
  echo "Lock file still exists after ${LOCK_WAIT_TIMEOUT_MIN} minutes. Attempting to stop feed sync processes and remove lock (use with caution)."
  # Try polite termination of common feed-sync processes
  sudo pkill -f greenbone-feed-sync || true
  sudo pkill -f feed-update || true
  sleep 3
  if [ -f "$LOCK_FILE" ]; then
    echo "Removing stale lock file $LOCK_FILE"
    sudo rm -f "$LOCK_FILE" || true
  fi
else
  echo "No lock file present or it was released while waiting."
fi

# 11) Run feed synchronizations (as _gvm)
step "11) Running feed syncs (GVMD_DATA, SCAP, CERT) as _gvm (may take long)"
# Run each sync and continue on error (we capture success flags)
sync_ok=true
if ! sudo runuser -u _gvm -- greenbone-feed-sync --type GVMD_DATA; then
  echo "GVMD_DATA sync returned non-zero. Continue."
  sync_ok=false
fi
if ! sudo runuser -u _gvm -- greenbone-feed-sync --type SCAP; then
  echo "SCAP sync returned non-zero. Continue."
  sync_ok=false
fi
if ! sudo runuser -u _gvm -- greenbone-feed-sync --type CERT; then
  echo "CERT sync returned non-zero. Continue."
  sync_ok=false
fi

# Rebuild gvmd storage (safe)
echo "Rebuilding gvmd data structures (gvmd --rebuild) as _gvm"
sudo runuser -u _gvm -- gvmd --rebuild || echo "gvmd --rebuild returned non-zero (may be normal)."

# Optional feed update wrapper if available
if command -v gvm-feed-update >/dev/null 2>&1; then
  sudo gvm-feed-update || true
fi

# 12) Restart GVM cleanly
step "12) Restarting GVM services (gvm-stop / gvm-start)"
sudo gvm-stop || true
sleep 3
sudo gvm-start || true
sleep 5

# 13) Final status & summary
step "13) Final summary"

SERVER_IP=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++){ if ($i !~ /^127\\./) { print $i; exit } }}' || true)
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7; exit}' || true)
fi
if [ -z "$SERVER_IP" ]; then SERVER_IP="127.0.0.1"; fi

FEED_STATUS_MSG="unknown"
if $sync_ok; then FEED_STATUS_MSG="sync commands ran (check UI Feed Status for 'Current')"; else FEED_STATUS_MSG="one or more syncs failed/partially succeeded (check logs and UI Feed Status)"; fi

cat > "$SUMMARY" <<EOF
OpenVAS (Greenbone CE) Smart Installer Summary - ${TIMESTAMP}

Web UI:
  URL: https://${SERVER_IP}:9392
  Username: admin
  Password: ${ADMIN_PASS:-(not-detected)}

Feed synchronization:
  Status: ${FEED_STATUS_MSG}

Logs:
  Installer log: ${LOG}
  gvm-setup capture: ${SETUP_OUT}

Notes:
 - Feed syncs can take a long time; wait until Administration -> Feed Status shows 'Current' before creating scans.
 - If you see "default Scan Config is not available" in the UI, feeds haven't finished syncing.
 - To manually check feed lock owner: sudo lsof /var/lib/gvm/feed-update.lock
 - To manually sync feeds later (as _gvm):
     sudo runuser -u _gvm -- greenbone-feed-sync --type GVMD_DATA
     sudo runuser -u _gvm -- greenbone-feed-sync --type SCAP
     sudo runuser -u _gvm -- greenbone-feed-sync --type CERT
 - To reset admin password manually:
     sudo runuser -u _gvm -- gvmd --user=admin --new-password='YourNewStrongPasswordHere'
EOF

chmod 600 "$SUMMARY"

echo "============================================================"
echo "Installation finished. See summary: $SUMMARY"
echo
echo "Web UI: https://${SERVER_IP}:9392"
echo "Username: admin"
echo "Password: ${ADMIN_PASS:-(not-detected)}"
echo
echo "Feed sync state: ${FEED_STATUS_MSG}"
echo "Installer log: $LOG"
echo "gvm-setup capture: $SETUP_OUT"
echo "============================================================"

exit 0
