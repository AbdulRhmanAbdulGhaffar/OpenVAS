#!/bin/bash
# ============================================================
# OpenVAS (Greenbone Community Edition) Automated Installer
# All-in-one: install, setup, enable remote access, feed sync, set admin password
# Author: adapted for you
# Usage: sudo bash install_openvas_complete.sh
# ============================================================

set -euo pipefail
IFS=$'\n\t'

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG="/tmp/gvm_install_${TIMESTAMP}.log"
SETUP_OUT="/tmp/gvm_setup_output_${TIMESTAMP}.log"
SUMMARY="/root/openvas_install_summary_${TIMESTAMP}.txt"

exec > >(tee -a "$LOG") 2>&1

echo "============================================================"
echo " OpenVAS (Greenbone CE) automatic installer"
echo " Log: $LOG"
echo " Setup capture: $SETUP_OUT"
echo " Summary will be written to: $SUMMARY"
echo "============================================================"

trap 'echo "ERROR: Installer failed. See $LOG"; exit 1' ERR

# Helper: print step header
step() { echo; echo "---- $1"; echo; }

# 1) Update & upgrade system
step "1) Update & upgrade system"
apt update -y && apt full-upgrade -y
# 2) Install gvm
step "2) Install gvm (Greenbone Community Edition)"
apt install -y gvm

# 3) Run gvm-setup (capture output)
step "3) Running gvm-setup (this may take several minutes; output captured)"
# sometimes gvm-setup prompts or prints; capture all output
if sudo gvm-setup 2>&1 | tee "$SETUP_OUT"; then
  echo "gvm-setup completed (exit 0)."
else
  echo "gvm-setup returned non-zero exit code — continuing to try to fix common issues."
fi

# 4) Try to locate admin password inside setup output or logs; generate and set if not found
step "4) Determine or set admin password"
ADMIN_PASS=""
# Try multiple common patterns in setup capture & expected logs
for f in "$SETUP_OUT" /var/log/gvm/setup.log /var/log/openvas/setup.log /var/log/gvm/gvmd.log; do
  if [ -f "$f" ]; then
    candidate=$(grep -iE "admin( user)? (password|pwd)|password for user 'admin'|generated.*password.*admin" "$f" -m1 || true)
    if [ -n "$candidate" ]; then
      # extract last token after colon/equals
      token=$(echo "$candidate" | sed -E 's/.*[:=]-?[[:space:]]*//I' | awk '{print $NF}')
      if [ -n "$token" ]; then
        ADMIN_PASS="$token"
        break
      fi
    fi
  fi
done

# If no pass found, create a strong random password and set it in gvmd
if [ -z "${ADMIN_PASS:-}" ]; then
  echo "No admin password found in logs; creating a strong password and applying it to the manager."
  ADMIN_PASS="$(tr -dc 'A-Za-z0-9@%_-' </dev/urandom | head -c 20)"
  # ensure gvmd user exists and set password
  if sudo runuser -u _gvm -- gvmd --get-users >/dev/null 2>&1; then
    echo "Setting admin password in gvmd to the generated value."
    sudo runuser -u _gvm -- gvmd --user=admin --new-password="${ADMIN_PASS}" || {
      echo "gvmd password set failed — trying to create admin user then set password"
      sudo runuser -u _gvm -- gvmd --create-user=admin --password="${ADMIN_PASS}" || true
    }
  else
    echo "Warning: gvmd command not available or _gvm user not ready; admin password will need manual reset later."
  fi
else
  echo "Found admin password: (hidden) — applying to gvmd to ensure sync."
  # attempt to apply it to be sure
  sudo runuser -u _gvm -- gvmd --user=admin --new-password="${ADMIN_PASS}" >/dev/null 2>&1 || true
fi

# 5) Ensure gsad listens on 0.0.0.0:9392 (safe edit)
step "5) Configure gsad service to listen on 0.0.0.0:9392"
GSAD_UNIT_CANDIDATES=(
  "/usr/lib/systemd/system/gsad.service"
  "/lib/systemd/system/gsad.service"
  "/etc/systemd/system/gsad.service"
)
GSAD_UNIT=""
for p in "${GSAD_UNIT_CANDIDATES[@]}"; do
  if [ -f "$p" ]; then
    GSAD_UNIT="$p"
    break
  fi
done

if [ -n "$GSAD_UNIT" ]; then
  echo "Found gsad unit: $GSAD_UNIT"
  sudo cp "$GSAD_UNIT" "${GSAD_UNIT}.bak_${TIMESTAMP}"
  # Try to find ExecStart line and adjust listen arg. Also handle cases where ExecStart contains full path to gsad
  sudo sed -i -E "s/--listen=127(\\.0\\.0\\.1)?/--listen=0.0.0.0/g" "$GSAD_UNIT" || true
  # keep port 9392 (do not force 443)
  sudo systemctl daemon-reload
  sudo systemctl restart gsad || echo "Warning: restart of gsad failed; check 'systemctl status gsad'"
  echo "Edited and restarted gsad (backup saved)."
else
  echo "gsad systemd unit not found in expected locations. Skipping automatic edit — you may need to update the service manually."
fi

# 6) Enable services to start at boot if present
step "6) Enable GVM services to start on boot (if available)"
SERVICES=(gsad gvmd ospd-openvas ospd-openvas.service)
for svc in "${SERVICES[@]}"; do
  if systemctl list-unit-files | grep -q "^${svc}"; then
    sudo systemctl enable "$svc" || echo "Warning: could not enable $svc"
  fi
done

# 7) Open firewall (UFW) port 9392 if UFW is present
step "7) Open firewall port 9392 (if UFW present)"
if command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -qi "inactive"; then
    echo "UFW inactive — skipping UFW rules"
  else
    sudo ufw allow 9392/tcp || echo "Warning: ufw allow failed"
  fi
else
  echo "UFW not installed — skipping firewall changes (you may need to open port 9392 manually)."
fi

# 8) Start/Restart GVM services (tolerant)
step "8) Start GVM services"
sudo systemctl daemon-reload || true
sudo systemctl restart gvmd || true
sudo systemctl restart gsad || true
# try gvm-start (this starts all parts)
if command -v gvm-start >/dev/null 2>&1; then
  sudo gvm-start || echo "gvm-start returned non-zero (check services manually)."
else
  echo "gvm-start not found — services may already be running or managed by systemd."
fi

# 9) Feed syncs (run as _gvm). This may take a long time (minutes to hours).
step "9) Synchronize feeds (GVMD_DATA, SCAP, CERT) — this may take long"
# run as _gvm user; some setups require runuser -u _gvm --
if sudo runuser -u _gvm -- greenbone-feed-sync --type GVMD_DATA; then
  echo "GVMD_DATA sync OK"
else
  echo "GVMD_DATA sync returned non-zero (check network and logs)"
fi

sudo runuser -u _gvm -- greenbone-feed-sync --type SCAP || echo "SCAP sync issue"
sudo runuser -u _gvm -- greenbone-feed-sync --type CERT || echo "CERT sync issue"

# Rebuild/refresh gvmd feed data
echo "Rebuilding GVMD DB and updating manager data..."
sudo runuser -u _gvm -- gvmd --rebuild || echo "gvmd --rebuild returned non-zero (might be normal on some versions)"

# Try gvm-feed-update if available
if command -v gvm-feed-update >/dev/null 2>&1; then
  sudo gvm-feed-update || true
fi

# Run a final gvm-check-setup (do not abort on non-zero)
echo "Running gvm-check-setup (may print warnings)."
sudo gvm-check-setup || echo "gvm-check-setup printed issues — inspect output above and $LOG"

# 10) Final restart to ensure everything is loaded
step "10) Final restart of GVM services"
sudo gvm-stop || true
sleep 3
sudo gvm-start || true
sleep 5

# Determine server IP (first non-loopback IPv4)
SERVER_IP=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++){ if ($i !~ /^127\\./) { print $i; exit } }}' || true)
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7; exit}' || true)
fi
if [ -z "$SERVER_IP" ]; then
  SERVER_IP="127.0.0.1"
fi

# Summarize and write summary file
step "Finished — writing summary"
cat > "$SUMMARY" <<EOF
OpenVAS (Greenbone CE) installation summary - ${TIMESTAMP}

Access:
  URL: https://${SERVER_IP}:9392
  Username: admin
  Password: ${ADMIN_PASS:-(not detected)}

Logs:
  Installer log: ${LOG}
  gvm-setup captured output: ${SETUP_OUT}

Notes:
 - Feed synchronization commands were executed. Full feed sync can take a long time (minutes to hours)
   depending on your internet and CPU. Check Administration -> Feed Status in the web UI.
 - If you cannot reach https://${SERVER_IP}:9392:
     * Confirm gsad is listening: sudo ss -ltnp | grep 9392
     * Confirm firewall allows 9392
     * Confirm ExecStart path inside the gsad systemd unit is correct
 - To manually reset the admin password:
     sudo runuser -u _gvm -- gvmd --user=admin --new-password='YourNewPasswordHere'
EOF

chmod 600 "$SUMMARY"
echo "Summary saved to $SUMMARY"

# Print final info to user
echo
echo "============================================================"
echo "Installation completed (check above for warnings)."
echo
echo "Web UI: https://${SERVER_IP}:9392"
echo "Username: admin"
echo "Password: ${ADMIN_PASS:-(not detected)}"
echo
echo "A summary was written to: $SUMMARY"
echo "Installer log: $LOG"
echo "Setup capture: $SETUP_OUT"
echo
echo "Feed sync may still be in progress — wait until 'Feed Status' shows 'Current' in the UI before running scans."
echo "If you see 'default Scan Config is not available' in the UI, it means feed sync hasn't finished yet."
echo "============================================================"

exit 0
