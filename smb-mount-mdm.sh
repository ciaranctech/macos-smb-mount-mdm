#!/bin/bash
# shellcheck shell=bash

################################################################################
# smb-mount-mdm.sh
# Version: 1.0.0
#
# Enterprise-ready SMB share mount script for macOS (Jamf/Intune friendly)
# - Non-interactive by default (MDM-safe behavior)
# - Optional interactive mode for user-driven runs
# - Optional UI customization (Desktop link, Finder sidebar, Dock)
# - Deterministic exit codes and structured result summary
#
# Author: Ciaran C / Claw workflow
################################################################################

set -u
set -o pipefail

#######################################
# VERSION
#######################################
SCRIPT_NAME="smb-mount-mdm"
SCRIPT_VERSION="1.0.0"

#######################################
# CONFIGURATION (edit for your tenant)
#######################################
ANF_HOST="anf01.contoso.com"
SHARE_NAME="jamf-share"
DOMAIN="contoso"
DISPLAY_NAME="Company Share"
DESKTOP_LINK_NAME="Company Share"
MOUNT_POINT="/Volumes/${DISPLAY_NAME}"

# mysides locations
MYSIDES_TARGET="/usr/local/bin/mysides"
MYSIDES_ALT_TARGET="/opt/homebrew/bin/mysides"
JAMF_DOWNLOADS="/Library/Application Support/JAMF/Downloads"
MYSIDES_PKG="${JAMF_DOWNLOADS}/mysides.pkg"
MYSIDES_CACHED_BIN="${JAMF_DOWNLOADS}/mysides"
MYSIDES_PKG_URL="https://github.com/mosen/mysides/releases/download/v1.0.1/mysides-1.0.1.pkg"
MYSIDES_TMP_PKG="/private/tmp/mysides-1.0.1.pkg"

# Behavior flags
INTERACTIVE_MODE="false"           # true|false (default false for MDM)
ENABLE_UI_CUSTOMIZATIONS="true"    # true|false
POST_MOUNT_MAX_WAIT=20              # seconds

# Logging
LOG_DIR="/Library/Application Support/Script Logs/${SCRIPT_NAME}"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"

#######################################
# EXIT CODES
#######################################
E_SUCCESS=0
E_NO_GUI_USER=10
E_USER_CONTEXT=11
E_MYSIDES_INSTALL=20
E_NO_CREDENTIALS=30
E_MOUNT_FAILED=31
E_MOUNT_MISMATCH=32

#######################################
# RUNTIME STATE
#######################################
RESULT_MOUNT="skip"
RESULT_DESKTOP="skip"
RESULT_SIDEBAR="skip"
RESULT_DOCK="skip"

#######################################
# LOGGING
#######################################
timestamp() { /bin/date "+%Y-%m-%d %H:%M:%S"; }

log()   { echo "$(timestamp) [INFO]  $1" | /usr/bin/tee -a "$LOG_FILE"; }
warn()  { echo "$(timestamp) [WARN]  $1" | /usr/bin/tee -a "$LOG_FILE"; }
error() { echo "$(timestamp) [ERROR] $1" | /usr/bin/tee -a "$LOG_FILE" >&2; }

finalize() {
  local exit_code="$1"
  log "RESULT: mount=${RESULT_MOUNT} desktop=${RESULT_DESKTOP} sidebar=${RESULT_SIDEBAR} dock=${RESULT_DOCK} exit=${exit_code} version=${SCRIPT_VERSION}"
  log "===================== Script finished ====================="
  exit "$exit_code"
}

#######################################
# LOG PREP
#######################################
/bin/mkdir -p "$LOG_DIR"
/usr/bin/touch "$LOG_FILE"
/usr/sbin/chown root:wheel "$LOG_FILE"
/bin/chmod 644 "$LOG_FILE"
log "==================== Script started ===================="
log "Script: ${SCRIPT_NAME} v${SCRIPT_VERSION}"

#######################################
# USER CONTEXT
#######################################
LOGGED_IN_USER=$(/usr/bin/stat -f "%Su" /dev/console)
if [[ -z "$LOGGED_IN_USER" || "$LOGGED_IN_USER" == "root" ]]; then
  warn "No GUI user detected (console user is '${LOGGED_IN_USER:-none}')."
  if [[ "$ENABLE_UI_CUSTOMIZATIONS" == "true" || "$INTERACTIVE_MODE" == "true" ]]; then
    error "This mode requires a logged-in GUI user."
    finalize "$E_NO_GUI_USER"
  fi
fi

USER_ID=""
USER_HOME=""
DESKTOP_PATH=""
DESKTOP_LINK_PATH=""

if [[ -n "$LOGGED_IN_USER" && "$LOGGED_IN_USER" != "root" ]]; then
  USER_ID=$(/usr/bin/id -u "$LOGGED_IN_USER" 2>/dev/null || true)
  USER_HOME=$(/usr/bin/dscl . -read "/Users/${LOGGED_IN_USER}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
  DESKTOP_PATH="${USER_HOME}/Desktop"
  DESKTOP_LINK_PATH="${DESKTOP_PATH}/${DESKTOP_LINK_NAME}"

  if [[ -z "$USER_ID" || -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
    error "Failed to resolve user context for '${LOGGED_IN_USER}'."
    finalize "$E_USER_CONTEXT"
  fi

  log "Logged-in user: ${LOGGED_IN_USER} (uid ${USER_ID})"
  log "User home: ${USER_HOME}"
fi

run_as_user() {
  /bin/launchctl asuser "$USER_ID" /usr/bin/sudo -u "$LOGGED_IN_USER" "$@"
}

#######################################
# ARG PARSING
#######################################
for arg in "$@"; do
  case "$arg" in
    --interactive) INTERACTIVE_MODE="true" ;;
    --non-interactive) INTERACTIVE_MODE="false" ;;
    --no-ui) ENABLE_UI_CUSTOMIZATIONS="false" ;;
    --ui) ENABLE_UI_CUSTOMIZATIONS="true" ;;
  esac
done

log "Mode: interactive=${INTERACTIVE_MODE}, ui_customizations=${ENABLE_UI_CUSTOMIZATIONS}"

#######################################
# HELPERS
#######################################
find_mysides() {
  if [[ -x "$MYSIDES_TARGET" ]]; then echo "$MYSIDES_TARGET"; return 0; fi
  if [[ -x "$MYSIDES_ALT_TARGET" ]]; then echo "$MYSIDES_ALT_TARGET"; return 0; fi
  return 1
}

install_mysides() {
  local current
  current="$(find_mysides || true)"
  if [[ -n "$current" ]]; then
    log "mysides present at ${current}"
    return 0
  fi

  log "mysides not found; attempting installation."
  /bin/mkdir -p "/usr/local/bin"

  if [[ -f "$MYSIDES_PKG" ]]; then
    log "Installing mysides from Jamf-cached package: ${MYSIDES_PKG}"
    /usr/sbin/installer -pkg "$MYSIDES_PKG" -target / >/dev/null 2>&1 || return 1
  elif [[ -f "$MYSIDES_CACHED_BIN" ]]; then
    log "Installing mysides from Jamf-cached binary: ${MYSIDES_CACHED_BIN}"
    /bin/cp "$MYSIDES_CACHED_BIN" "$MYSIDES_TARGET" || return 1
    /usr/sbin/chown root:wheel "$MYSIDES_TARGET"
    /bin/chmod 755 "$MYSIDES_TARGET"
  else
    warn "No mysides package/binary found under Jamf Downloads; attempting direct package download."
    /bin/rm -f "$MYSIDES_TMP_PKG"
    if ! /usr/bin/curl -fL --connect-timeout 10 --retry 2 --retry-delay 1 -o "$MYSIDES_TMP_PKG" "$MYSIDES_PKG_URL" >/dev/null 2>&1; then
      warn "Direct mysides package download failed."
      return 1
    fi

    if ! /usr/sbin/installer -pkg "$MYSIDES_TMP_PKG" -target / >/dev/null 2>&1; then
      warn "mysides package install from downloaded pkg failed."
      /bin/rm -f "$MYSIDES_TMP_PKG"
      return 1
    fi
    /bin/rm -f "$MYSIDES_TMP_PKG"
  fi

  current="$(find_mysides || true)"
  [[ -n "$current" ]]
}

is_expected_share_mounted() {
  /sbin/mount | /usr/bin/grep -E "on ${MOUNT_POINT//\//\\/} \(smbfs" >/dev/null 2>&1 || return 1
  /sbin/mount | /usr/bin/grep -i "//.*@${ANF_HOST}/${SHARE_NAME} on ${MOUNT_POINT}" >/dev/null 2>&1 || return 1
  return 0
}

wait_for_mount_readiness() {
  local i
  for ((i=1; i<=POST_MOUNT_MAX_WAIT; i++)); do
    if is_expected_share_mounted; then
      return 0
    fi
    /bin/sleep 1
  done
  return 1
}

prompt_for_password() {
  run_as_user /usr/bin/osascript <<'EOF'
tell application "System Events"
  activate
  try
    set userPass to text returned of (display dialog "Enter your network password to connect to the company file share:" default answer "" with hidden answer buttons {"Cancel", "Connect"} default button "Connect" with icon caution)
    return userPass
  on error number -128
    return ""
  end try
end tell
EOF
}

store_password_in_keychain() {
  local user_pass="$1"
  # Protocol code for SMB is 'smb ' (four-char code). Keep path scoped to share.
  run_as_user /usr/bin/security add-internet-password \
    -a "$LOGGED_IN_USER" \
    -s "$ANF_HOST" \
    -r "smb " \
    -p "/${SHARE_NAME}" \
    -w "$user_pass" \
    -U >/dev/null 2>&1 || return 1
  return 0
}

mount_with_cached_credentials() {
  local smb_url="//${DOMAIN};${LOGGED_IN_USER}@${ANF_HOST}/${SHARE_NAME}"
  /sbin/mount_smbfs "$smb_url" "$MOUNT_POINT" >/dev/null 2>&1
}

url_encode_password() {
  local raw="$1"
  RAW_PASS="$raw" /usr/bin/python3 - <<'PY'
import os, urllib.parse
print(urllib.parse.quote(os.environ["RAW_PASS"], safe=""))
PY
}

mount_with_password_fallback() {
  local user_pass="$1"
  local encoded
  local smb_url
  encoded="$(url_encode_password "$user_pass")"
  smb_url="//${DOMAIN};${LOGGED_IN_USER}:${encoded}@${ANF_HOST}/${SHARE_NAME}"
  /sbin/mount_smbfs "$smb_url" "$MOUNT_POINT" >/dev/null 2>&1
}

safe_create_mountpoint() {
  if [[ ! -d "$MOUNT_POINT" ]]; then
    /bin/mkdir -p "$MOUNT_POINT"
  fi
}

create_desktop_link() {
  if [[ "$ENABLE_UI_CUSTOMIZATIONS" != "true" ]]; then
    RESULT_DESKTOP="skip"
    return 0
  fi

  if [[ ! -d "$DESKTOP_PATH" ]]; then
    warn "Desktop path missing: ${DESKTOP_PATH}"
    RESULT_DESKTOP="warn"
    return 1
  fi

  if [[ -L "$DESKTOP_LINK_PATH" ]]; then
    /bin/rm "$DESKTOP_LINK_PATH" || true
  elif [[ -e "$DESKTOP_LINK_PATH" ]]; then
    warn "Desktop item exists and is not a symlink; leaving untouched: ${DESKTOP_LINK_PATH}"
    RESULT_DESKTOP="warn"
    return 1
  fi

  /bin/ln -s "$MOUNT_POINT" "$DESKTOP_LINK_PATH" && /usr/sbin/chown -h "$LOGGED_IN_USER" "$DESKTOP_LINK_PATH"
  if [[ $? -eq 0 ]]; then
    RESULT_DESKTOP="ok"
    return 0
  fi

  RESULT_DESKTOP="warn"
  return 1
}

configure_finder_sidebar() {
  local mysides_bin="$1"
  if [[ "$ENABLE_UI_CUSTOMIZATIONS" != "true" ]]; then
    RESULT_SIDEBAR="skip"
    return 0
  fi

  if [[ -z "$mysides_bin" || ! -x "$mysides_bin" ]]; then
    warn "mysides unavailable; skipping Finder sidebar."
    RESULT_SIDEBAR="warn"
    return 1
  fi

  run_as_user "$mysides_bin" remove "$DISPLAY_NAME" >/dev/null 2>&1 || true
  run_as_user "$mysides_bin" add "$DISPLAY_NAME" "file://${MOUNT_POINT}" >/dev/null 2>&1

  if [[ $? -eq 0 ]]; then
    RESULT_SIDEBAR="ok"
    return 0
  fi

  RESULT_SIDEBAR="warn"
  return 1
}

dock_contains_exact_path() {
  run_as_user /usr/bin/defaults read com.apple.dock persistent-others 2>/dev/null | /usr/bin/grep -Fq "file://${MOUNT_POINT}/"
}

configure_dock() {
  if [[ "$ENABLE_UI_CUSTOMIZATIONS" != "true" ]]; then
    RESULT_DOCK="skip"
    return 0
  fi

  if dock_contains_exact_path; then
    RESULT_DOCK="ok"
    return 0
  fi

  run_as_user /usr/bin/defaults write com.apple.dock persistent-others -array-add "
<dict>
<key>tile-data</key>
<dict>
<key>arrangement</key><integer>2</integer>
<key>displayas</key><integer>1</integer>
<key>file-data</key>
<dict>
<key>_CFURLString</key><string>file://${MOUNT_POINT}/</string>
<key>_CFURLStringType</key><integer>15</integer>
</dict>
<key>file-label</key><string>${DISPLAY_NAME}</string>
<key>showas</key><integer>1</integer>
</dict>
<key>tile-type</key><string>directory-tile</string>
</dict>" >/dev/null 2>&1

  if [[ $? -ne 0 ]]; then
    RESULT_DOCK="warn"
    return 1
  fi

  run_as_user /usr/bin/killall Dock >/dev/null 2>&1 || true
  RESULT_DOCK="ok"
  return 0
}

refresh_finder() {
  if [[ "$ENABLE_UI_CUSTOMIZATIONS" == "true" ]]; then
    run_as_user /usr/bin/killall Finder >/dev/null 2>&1 || true
  fi
}

#######################################
# MAIN
#######################################
if [[ "$ENABLE_UI_CUSTOMIZATIONS" == "true" ]]; then
  if ! install_mysides; then
    error "mysides installation/check failed."
    finalize "$E_MYSIDES_INSTALL"
  fi
  MYSIDES_BIN="$(find_mysides || true)"
  log "Using mysides: ${MYSIDES_BIN:-not-found}"
else
  MYSIDES_BIN=""
fi

safe_create_mountpoint

if is_expected_share_mounted; then
  log "Expected share already mounted at ${MOUNT_POINT}."
  RESULT_MOUNT="ok"
else
  log "Attempting mount with cached/SSO credentials first."
  if mount_with_cached_credentials && wait_for_mount_readiness; then
    RESULT_MOUNT="ok"
    log "Mounted successfully with cached/SSO credentials."
  else
    warn "Cached/SSO credential mount attempt failed."

    if [[ "$INTERACTIVE_MODE" != "true" ]]; then
      error "Non-interactive mode: no usable credentials available for mount."
      RESULT_MOUNT="fail"
      finalize "$E_NO_CREDENTIALS"
    fi

    USER_PASS="$(prompt_for_password)"
    if [[ -z "$USER_PASS" ]]; then
      warn "User cancelled password prompt."
      RESULT_MOUNT="fail"
      finalize "$E_NO_CREDENTIALS"
    fi

    if mount_with_password_fallback "$USER_PASS" && wait_for_mount_readiness; then
      RESULT_MOUNT="ok"
      store_password_in_keychain "$USER_PASS" || warn "Could not update login keychain entry."
      unset USER_PASS
      log "Mounted successfully via interactive fallback."
    else
      unset USER_PASS
      error "Interactive fallback mount failed."
      RESULT_MOUNT="fail"
      finalize "$E_MOUNT_FAILED"
    fi
  fi
fi

if ! is_expected_share_mounted; then
  error "Mounted target verification failed: expected host/share not confirmed."
  RESULT_MOUNT="fail"
  finalize "$E_MOUNT_MISMATCH"
fi

if [[ -n "$LOGGED_IN_USER" && "$LOGGED_IN_USER" != "root" ]]; then
  create_desktop_link || true
  configure_finder_sidebar "$MYSIDES_BIN" || true
  configure_dock || true
  refresh_finder
fi

finalize "$E_SUCCESS"
