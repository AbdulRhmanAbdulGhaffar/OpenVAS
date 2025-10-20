#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Install & configure Greenbone Community Edition (GVM / OpenVAS) on Kali Linux
# Author: Generated for AbdulRhman AbdulGhaffar
# Usage: sudo bash install_gvm.sh [--remote] [--port PORT] [--non-interactive]
# Example: sudo bash install_gvm.sh --remote --port 443 --non-interactive
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

LOGFILE="/var/log/gvm_install.log"
CRED_FILE="/root/gvm_admin_credentials.txt"
GSAD_SERVICE="/usr/lib/systemd/system/gsad.service"  # location used in guide, may vary
REMOTE_ACCESS=false
REMOTE_PORT=9392
NON_INTERACTIVE=false

# Helper: log
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

# Parse args (simple)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) REMOTE_ACCESS=true; shift ;;
    --port) REMOTE_PORT="$2"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    -h|--help) echo "Usage: sudo bash install_gvm.sh [--remote] [--port PORT] [--non-interactive]"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

check_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}

safe_write_creds() {
  local user=$1
  local pass=$2
  umask 177
  cat > "$CRED_FILE" <<EOF
GVM admin credentials (created on $(date -u +"%Y-%m-%d %H:%M:%S UTC"))

Username: $user
Password: $pass

File location: $CRED_FILE
EOF
  chmod 600 "$CRED_FILE"
  log "Admin credentials saved to $CRED_FILE (permissions 600)"
}

generate_password() {
  # 16-char random password
  tr -dc 'A-Za-z0-9!@%_-+=' < /dev/urandom | head -c 16 || echo "GvmPassw0rd!"
}

update_system() {
  log "Updating APT and upgrading packages..."
  apt update >> "$LOGFILE" 2>&1
  apt -y upgrade >> "$LOGFILE" 2>&1 || log "Upgrade returned non-zero (check $LOGFILE)"
}

install_gvm_package() {
  log "Installing gvm package (OpenVAS/GVM)..."
  apt -y install gvm >> "$LOGFILE" 2>&1
}

run_gvm_setup() {
  log "Running gvm-setup (this may take several minutes). Output is logged to $LOGFILE"
  if $NON_INTERACTIVE ; then
    # Try to run with yes pipe; note gvm-setup may require TTY for some prompts
    yes "" | gvm-setup >> "$LOGFILE" 2>&1 || log "gvm-setup exited with non-zero (check $LOGFILE)"
  else
    gvm-setup | tee -a "$LOGFILE"
  fi
  # Attempt to parse credentials from the log (common pattern)
  if grep -q -i "Admin user created" "$LOGFILE" 2>/dev/null || grep -q -i "created user" "$LOGFILE" 2>/dev/null; then
    # try to extract lines containing "user" and "password" near each other
    creds=$(grep -iE "admin|user|password" "$LOGFILE" -n | tail -n 30 || true)
    log "Attempting to extract admin credentials from gvm-setup output..."
    echo "$creds" | tee -a "$LOGFILE"
    # best-effort parse: look for "username" and "password" words
    user=$(echo "$creds" | grep -iE "username|user" | head -n1 | awk -F: '{print $2}' | tr -d ' ' || true)
    pass=$(echo "$creds" | grep -iE "password" | head -n1 | awk -F: '{print $2}' | tr -d ' ' || true)
    if [[ -n "$user" && -n "$pass" ]]; then
      safe_write_creds "$user" "$pass"
      return 0
    fi
  fi
  return 1
}

ensure_admin_user() {
  # If we couldn't grab credentials, create a new admin user for GVM
  local user_check
  user_check=$(runuser -u _gvm -- gvmd --get-users 2>/dev/null || true)
  if echo "$user_check" | grep -q -i "admin"; then
    log "Admin user already exists. Listing users:"
    echo "$user_check" | tee -a "$LOGFILE"
    return 0
  fi
  NEW_ADMIN="admin"
  NEW_PASS=$(generate_password)
  log "Creating admin user '$NEW_ADMIN' with a generated password."
  runuser -u _gvm -- gvmd --create-user="$NEW_ADMIN" --password="$NEW_PASS" >> "$LOGFILE" 2>&1
  safe_write_creds "$NEW_ADMIN" "$NEW_PASS"
}

sync_feeds() {
  log "Syncing Greenbone feeds (this can take a long time depending on network & CPU)"
  greenbone-feed-sync --type GVMD_DATA >> "$LOGFILE" 2>&1 || log "GVMD_DATA sync failed"
  greenbone-feed-sync --type SCAP >> "$LOGFILE" 2>&1 || log "SCAP sync failed"
  greenbone-feed-sync --type CERT >> "$LOGFILE" 2>&1 || log "CERT sync failed"
  log "Feed sync commands finished. Check $LOGFILE for details."
}

configure_gsad_remote() {
  if [[ ! -f "$GSAD_SERVICE" ]]; then
    log "Warning: gsad service file not found at $GSAD_SERVICE. Trying common alternative locations..."
    if [[ -f "/lib/systemd/system/gsad.service" ]]; then
      GSAD_SERVICE="/lib/systemd/system/gsad.service"
    elif [[ -f "/etc/systemd/system/gsad.service" ]]; then
      GSAD_SERVICE="/etc/systemd/system/gsad.service"
    else
      log "gsad.service location not found. Skipping automatic remote configure. You can edit the service file manually."
      return 1
    fi
  fi
  log "Backing up original gsad.service to ${GSAD_SERVICE}.bak"
  cp "$GSAD_SERVICE" "${GSAD_SERVICE}.bak"
  log "Modifying gsad ExecStart to listen on 0.0.0.0 port ${REMOTE_PORT}"
  # Replace listen argument while preserving other flags
  sed -i -E "s@(ExecStart=.*--listen=)[^ ]+@\\10.0.0.0@" "$GSAD_SERVICE" || true
  # Change port value if present; otherwise append --port
  if grep -q -- "--port=" "$GSAD_SERVICE"; then
    sed -i -E "s@(--port=)[0-9]+@\\1${REMOTE_PORT}@" "$GSAD_SERVICE" || true
  else
    # append port to ExecStart line
    sed -i -E "s@(ExecStart=.*)@\\1 --port=${REMOTE_PORT}@" "$GSAD_SERVICE" || true
  fi
  systemctl daemon-reload
  systemctl restart gsad || log "Failed to restart gsad; check $LOGFILE and 'journalctl -u gsad -b'"
  log "gsad service modified and restarted (if restart succeeded)."
}

final_checks() {
  log "Running gvm-check-setup to verify installation; output appended to $LOGFILE"
  gvm-check-setup >> "$LOGFILE" 2>&1 || log "gvm-check-setup returned non-zero; inspect $LOGFILE"
  log "Installation script finished. Admin credentials (if created) are in $CRED_FILE"
  log "Tip: Open the web UI at https://<SERVER-IP>:${REMOTE_PORT} (or https://127.0.0.1:${REMOTE_PORT} if local)"
}

main() {
  check_root
  log "Start GVM install script"
  update_system
  install_gvm_package

  if run_gvm_setup ; then
    log "gvm-setup appears to have produced credentials (saved)."
  else
    log "gvm-setup did not yield parseable credentials. Will ensure admin user exists."
    ensure_admin_user
  fi

  sync_feeds

  if $REMOTE_ACCESS ; then
    configure_gsad_remote || log "configure_gsad_remote failed or was skipped"
  fi

  final_checks
}

main "$@"
