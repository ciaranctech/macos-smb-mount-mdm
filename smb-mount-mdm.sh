#!/bin/bash
# shellcheck shell=bash
 
################################################################################
# smb-mount-mdm.sh
# Version: 2.1.0
#
# SMB mount script for macOS (Jamf/Intune friendly)
# - Supports separate SMB username (does not assume local macOS username)
# - Saves SMB username/password to login keychain and reuses them
# - Optional bootstrap creds for initial non-interactive enrollment/testing
# - Optional Desktop link, Finder sidebar, Dock item
#
# Notes:
# - SMB mount target uses //host/share (share/export name required).
# - For Azure NetApp Files SMB, set SHARE_NAME to the SMB share/export name.
#
################################################################################
 
set -u
set -o pipefail
 
#######################################
# VERSION
#######################################
SCRIPT_NAME="smb-mount-mdm"
SCRIPT_VERSION="2.1.0"
 
#######################################
# CONFIGURATION
#######################################
ANF_HOST="anf01.contoso.com"
SHARE_NAME="jamf-share"      # SMB share/export name (required for //host/share)
DOMAIN="contoso"             # Optional. Leave empty for local SMB users/workgroup.
DISPLAY_NAME="Company Share"
DESKTOP_LINK_NAME="Company Share"
MOUNT_POINT="/Volumes/${DISPLAY_NAME}"
 
# Keychain service names
KEYCHAIN_USER_SERVICE="com.company.smb.username.${ANF_HOST}.${SHARE_NAME}"
 
# mysides locations
MYSIDES_TARGET="/usr/local/bin/mysides"
MYSIDES_ALT_TARGET="/opt/homebrew/bin/mysides"
JAMF_DOWNLOADS="/Library/Application Support/JAMF/Downloads"
MYSIDES_PKG="${JAMF_DOWNLOADS}/mysides.pkg"
MYSIDES_CACHED_BIN="${JAMF_DOWNLOADS}/mysides"
MYSIDES_PKG_URL="https://github.com/mosen/mysides/releases/download/v1.0.1/mysides-1.0.1.pkg"
MYSIDES_TMP_PKG="/private/tmp/mysides-1.0.1.pkg"
 
# Behavior flags
INTERACTIVE_MODE="false"
ENABLE_UI_CUSTOMIZATIONS="true"
POST_MOUNT_MAX_WAIT=20

# Optional bootstrap credentials (for first-run non-interactive onboarding/testing)
# Prefer keychain reuse after first successful run.
CLI_SMB_USERNAME=""
CLI_SMB_PASSWORD=""
CLI_SMB_DOMAIN=""
 
# Logging
LOG_DIR="/Library/Application Support/Script Logs/${SCRIPT_NAME}"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
 
#######################################
# EXIT CODES
#######################################
E_SUCCESS=0
E_NO_GUI_USER=10
E_USER_CONTEXT=11
E_INVALID_ARGS=12
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
 
LOGGED_IN_USER=""
USER_ID=""
USER_HOME=""
DESKTOP_PATH=""
DESKTOP_LINK_PATH=""
LOGIN_KEYCHAIN=""
MYSIDES_BIN=""
SMB_USERNAME=""
SMB_PASSWORD=""
MOUNT_OUTPUT=""
MOUNT_EXIT=0
 
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
# ARG PARSING
#######################################
for arg in "$@"; do
  case "$arg" in
    --interactive) INTERACTIVE_MODE="true" ;;
    --non-interactive) INTERACTIVE_MODE="false" ;;
    --no-ui) ENABLE_UI_CUSTOMIZATIONS="false" ;;
    --ui) ENABLE_UI_CUSTOMIZATIONS="true" ;;
    --smb-user=*) CLI_SMB_USERNAME="${arg#*=}" ;;
    --smb-pass=*) CLI_SMB_PASSWORD="${arg#*=}" ;;
    --smb-domain=*) CLI_SMB_DOMAIN="${arg#*=}" ;;
  esac
done

if [[ -n "$CLI_SMB_DOMAIN" ]]; then
  DOMAIN="$CLI_SMB_DOMAIN"
fi

if [[ ( -n "$CLI_SMB_USERNAME" && -z "$CLI_SMB_PASSWORD" ) || ( -z "$CLI_SMB_USERNAME" && -n "$CLI_SMB_PASSWORD" ) ]]; then
  error "Invalid arguments: --smb-user and --smb-pass must be provided together."
  finalize "$E_INVALID_ARGS"
fi
 
log "Mode: interactive=${INTERACTIVE_MODE}, ui_customizations=${ENABLE_UI_CUSTOMIZATIONS}, bootstrap_user_supplied=$([[ -n "$CLI_SMB_USERNAME" ]] && echo true || echo false), domain_set=$([[ -n "$DOMAIN" ]] && echo true || echo false)"
 
#######################################
# USER CONTEXT
#######################################
LOGGED_IN_USER=$(/usr/bin/stat -f "%Su" /dev/console)
 
if [[ -z "$LOGGED_IN_USER" || "$LOGGED_IN_USER" == "root" ]]; then
  warn "No GUI user detected (console user is '${LOGGED_IN_USER:-none}')."
  if [[ "$INTERACTIVE_MODE" == "true" || "$ENABLE_UI_CUSTOMIZATIONS" == "true" ]]; then
    error "Interactive mode and UI customization require a logged-in GUI user."
    finalize "$E_NO_GUI_USER"
  fi
fi
 
if [[ -n "$LOGGED_IN_USER" && "$LOGGED_IN_USER" != "root" ]]; then
  USER_ID=$(/usr/bin/id -u "$LOGGED_IN_USER" 2>/dev/null || true)
  USER_HOME=$(/usr/bin/dscl . -read "/Users/${LOGGED_IN_USER}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
  DESKTOP_PATH="${USER_HOME}/Desktop"
  DESKTOP_LINK_PATH="${DESKTOP_PATH}/${DESKTOP_LINK_NAME}"
  LOGIN_KEYCHAIN="${USER_HOME}/Library/Keychains/login.keychain-db"
  if [[ ! -f "$LOGIN_KEYCHAIN" && -f "${USER_HOME}/Library/Keychains/login.keychain" ]]; then
    LOGIN_KEYCHAIN="${USER_HOME}/Library/Keychains/login.keychain"
  fi
 
  if [[ -z "$USER_ID" || -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
    error "Failed to resolve user context for '${LOGGED_IN_USER}'."
    finalize "$E_USER_CONTEXT"
  fi
 
  log "Logged-in user: ${LOGGED_IN_USER} (uid ${USER_ID})"
  log "User home: ${USER_HOME}"
  log "Login keychain: ${LOGIN_KEYCHAIN}"
fi
 
run_as_user() {
  /bin/launchctl asuser "$USER_ID" /usr/bin/sudo -u "$LOGGED_IN_USER" "$@"
}

run_security_as_user() {
  # Prefer launchctl-asuser for GUI session context; fallback to direct sudo -u for SSH/non-GUI cases.
  if [[ -n "$USER_ID" ]]; then
    /bin/launchctl asuser "$USER_ID" /usr/bin/sudo -u "$LOGGED_IN_USER" /usr/bin/security "$@" && return 0
  fi
  /usr/bin/sudo -u "$LOGGED_IN_USER" /usr/bin/security "$@"
}
 
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
    log "mysides already present at ${current}"
    return 0
  fi
 
  log "mysides not found; attempting installation."
  /bin/mkdir -p "/usr/local/bin"
 
  if [[ -f "$MYSIDES_PKG" ]]; then
    log "Installing mysides from cached package: ${MYSIDES_PKG}"
    /usr/sbin/installer -pkg "$MYSIDES_PKG" -target / >/dev/null 2>&1 || return 1
  elif [[ -f "$MYSIDES_CACHED_BIN" ]]; then
    log "Installing mysides from cached binary: ${MYSIDES_CACHED_BIN}"
    /bin/cp "$MYSIDES_CACHED_BIN" "$MYSIDES_TARGET" || return 1
    /usr/sbin/chown root:wheel "$MYSIDES_TARGET"
    /bin/chmod 755 "$MYSIDES_TARGET"
  else
    warn "No cached mysides found; attempting download."
    /bin/rm -f "$MYSIDES_TMP_PKG"
    if ! /usr/bin/curl -fL --connect-timeout 10 --retry 2 --retry-delay 1 -o "$MYSIDES_TMP_PKG" "$MYSIDES_PKG_URL" >/dev/null 2>&1; then
      return 1
    fi
    if ! /usr/sbin/installer -pkg "$MYSIDES_TMP_PKG" -target / >/dev/null 2>&1; then
      /bin/rm -f "$MYSIDES_TMP_PKG"
      return 1
    fi
    /bin/rm -f "$MYSIDES_TMP_PKG"
  fi
 
  current="$(find_mysides || true)"
  [[ -n "$current" ]]
}
 
url_encode() {
  local raw="$1"
  RAW_VALUE="$raw" /usr/bin/python3 - <<'PY'
import os, urllib.parse
print(urllib.parse.quote(os.environ["RAW_VALUE"], safe=""))
PY
}
 
safe_create_mountpoint() {
  if [[ ! -d "$MOUNT_POINT" ]]; then
    /bin/mkdir -p "$MOUNT_POINT"
  fi

  # Allow user-context mount_smbfs runs to mount cleanly at the target path.
  if [[ -n "$LOGGED_IN_USER" && "$LOGGED_IN_USER" != "root" ]]; then
    /usr/sbin/chown "$LOGGED_IN_USER":staff "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
}

sanitize_mount_output() {
  # Redact potential credential material in mount_smbfs stderr.
  printf '%s' "$1" | /usr/bin/sed -E 's#//([^/@]+;)?[^:@/]+:[^@/]+@#//\1***:***@#g'
}

path_to_file_url() {
  local path="$1"
  RAW_PATH="$path" /usr/bin/python3 - <<'PY'
import os, urllib.parse
p = os.environ['RAW_PATH']
print('file://' + urllib.parse.quote(p, safe='/'))
PY
}

smb_user_principal() {
  local smb_user="$1"
  if [[ -n "$DOMAIN" ]]; then
    printf '%s;%s' "$DOMAIN" "$smb_user"
  else
    printf '%s' "$smb_user"
  fi
}
 
cleanup_stale_mountpoint() {
  if [[ -d "$MOUNT_POINT" ]]; then
    if ! /sbin/mount | /usr/bin/grep -Fq " on ${MOUNT_POINT} "; then
      /bin/rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
    fi
  fi
}
 
is_expected_share_mounted() {
  local mount_line
  local expected_target
  mount_line="$(/sbin/mount | /usr/bin/grep -E " on ${MOUNT_POINT//\//\\/} \(smbfs" | /usr/bin/head -n 1 || true)"
  if [[ -z "$mount_line" ]]; then
    return 1
  fi

  expected_target="@${ANF_HOST}/${SHARE_NAME} on ${MOUNT_POINT}"
  printf '%s\n' "$mount_line" | /usr/bin/grep -iFq "$expected_target"
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
 
#######################################
# KEYCHAIN FUNCTIONS
#######################################
get_saved_smb_username() {
  if [[ -z "$LOGGED_IN_USER" || "$LOGGED_IN_USER" == "root" || -z "$LOGIN_KEYCHAIN" || ! -f "$LOGIN_KEYCHAIN" ]]; then
    return 1
  fi
 
  run_security_as_user find-generic-password \
    -s "$KEYCHAIN_USER_SERVICE" \
    -a "$LOGGED_IN_USER" \
    -w \
    "$LOGIN_KEYCHAIN" 2>/dev/null || return 1
}

get_saved_smb_password() {
  local smb_user="$1"

  if [[ -z "$LOGGED_IN_USER" || "$LOGGED_IN_USER" == "root" || -z "$LOGIN_KEYCHAIN" || ! -f "$LOGIN_KEYCHAIN" ]]; then
    return 1
  fi

  run_security_as_user find-internet-password \
    -a "$smb_user" \
    -s "$ANF_HOST" \
    -r "smb " \
    -p "/${SHARE_NAME}" \
    -w \
    "$LOGIN_KEYCHAIN" 2>/dev/null || return 1
}
 
save_smb_username() {
  local smb_user="$1"

  if [[ -z "$LOGGED_IN_USER" || "$LOGGED_IN_USER" == "root" || -z "$LOGIN_KEYCHAIN" || ! -f "$LOGIN_KEYCHAIN" ]]; then
    return 1
  fi
 
  run_security_as_user add-generic-password \
    -a "$LOGGED_IN_USER" \
    -s "$KEYCHAIN_USER_SERVICE" \
    -w "$smb_user" \
    -U \
    "$LOGIN_KEYCHAIN" >/dev/null 2>&1
}
 
save_smb_password() {
  local smb_user="$1"
  local smb_pass="$2"

  if [[ -z "$LOGGED_IN_USER" || "$LOGGED_IN_USER" == "root" || -z "$LOGIN_KEYCHAIN" || ! -f "$LOGIN_KEYCHAIN" ]]; then
    return 1
  fi
 
  run_security_as_user add-internet-password \
    -a "$smb_user" \
    -s "$ANF_HOST" \
    -r "smb " \
    -p "/${SHARE_NAME}" \
    -w "$smb_pass" \
    -U \
    "$LOGIN_KEYCHAIN" >/dev/null 2>&1
}
 
#######################################
# PROMPTS
#######################################
prompt_for_credentials() {
  run_as_user /usr/bin/osascript <<'EOF'
tell application "System Events"
  activate
  try
    set smbUser to text returned of (display dialog "Enter your network username:" default answer "" buttons {"Cancel", "Next"} default button "Next" with icon note)
    if smbUser is "" then
      return "||"
    end if
 
    set smbPass to text returned of (display dialog "Enter your network password:" default answer "" with hidden answer buttons {"Cancel", "Connect"} default button "Connect" with icon caution)
    return smbUser & "||" & smbPass
  on error number -128
    return "||"
  end try
end tell
EOF
}
 
#######################################
# MOUNT FUNCTIONS
#######################################
build_smb_url_with_password() {
  local smb_user="$1"
  local smb_pass="$2"
  local encoded_user encoded_pass principal

  encoded_user="$(url_encode "$smb_user")"
  encoded_pass="$(url_encode "$smb_pass")"

  if [[ -n "$DOMAIN" ]]; then
    principal="${DOMAIN};${encoded_user}"
  else
    principal="$encoded_user"
  fi

  printf '//%s:%s@%s/%s' "$principal" "$encoded_pass" "$ANF_HOST" "$SHARE_NAME"
}
 
perform_mount() {
  local smb_url="$1"

  if [[ -n "$LOGGED_IN_USER" && "$LOGGED_IN_USER" != "root" ]]; then
    MOUNT_OUTPUT="$(run_as_user /sbin/mount_smbfs -N "$smb_url" "$MOUNT_POINT" 2>&1)"
    MOUNT_EXIT=$?
  else
    MOUNT_OUTPUT=$(/sbin/mount_smbfs -N "$smb_url" "$MOUNT_POINT" 2>&1)
    MOUNT_EXIT=$?
  fi

  return "$MOUNT_EXIT"
}

mount_with_password() {
  local smb_user="$1"
  local smb_pass="$2"
  local smb_url
 
  smb_url="$(build_smb_url_with_password "$smb_user" "$smb_pass")"
  log "Attempting mount with provided credentials for SMB user '${smb_user}'"
 
  perform_mount "$smb_url"
  return "$MOUNT_EXIT"
}
 
#######################################
# UI CUSTOMIZATION FUNCTIONS
#######################################
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
  local sidebar_url
 
  if [[ "$ENABLE_UI_CUSTOMIZATIONS" != "true" ]]; then
    RESULT_SIDEBAR="skip"
    return 0
  fi
 
  if [[ -z "$mysides_bin" || ! -x "$mysides_bin" ]]; then
    warn "mysides unavailable; skipping Finder sidebar."
    RESULT_SIDEBAR="warn"
    return 1
  fi

  sidebar_url="$(path_to_file_url "$MOUNT_POINT")"
 
  run_as_user "$mysides_bin" remove "$DISPLAY_NAME" >/dev/null 2>&1 || true
  run_as_user "$mysides_bin" add "$DISPLAY_NAME" "$sidebar_url" >/dev/null 2>&1
 
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
  log "Using mysides binary: ${MYSIDES_BIN:-not-found}"
fi
 
cleanup_stale_mountpoint
safe_create_mountpoint
 
if is_expected_share_mounted; then
  log "Share already mounted at ${MOUNT_POINT}"
  RESULT_MOUNT="ok"
else
  if [[ -n "$CLI_SMB_USERNAME" && -n "$CLI_SMB_PASSWORD" ]]; then
    log "Bootstrap credentials supplied; skipping saved-credential attempt for this run."
  else
    SMB_USERNAME="$(get_saved_smb_username || true)"

    if [[ -n "$SMB_USERNAME" ]]; then
      SMB_PASSWORD="$(get_saved_smb_password "$SMB_USERNAME" || true)"
      if [[ -n "$SMB_PASSWORD" ]]; then
        log "Found saved SMB credentials in keychain for local user '${LOGGED_IN_USER}'."
        if mount_with_password "$SMB_USERNAME" "$SMB_PASSWORD"; then
          if wait_for_mount_readiness; then
            RESULT_MOUNT="ok"
            log "Mounted successfully using stored keychain credentials."
          else
            warn "Mount command returned success but mount was not confirmed."
          fi
        else
          warn "Stored credential mount failed."
          warn "mount_smbfs output (sanitized): $(sanitize_mount_output "$MOUNT_OUTPUT")"
        fi
      else
        log "Saved SMB username exists but no reusable password was found in keychain."
      fi
      unset SMB_PASSWORD
    else
      log "No saved SMB username found in keychain."
    fi
  fi
 
  if [[ "$RESULT_MOUNT" != "ok" ]]; then
    if [[ -n "$CLI_SMB_USERNAME" && -n "$CLI_SMB_PASSWORD" ]]; then
      SMB_USERNAME="$CLI_SMB_USERNAME"
      SMB_PASSWORD="$CLI_SMB_PASSWORD"
      log "Using bootstrap credentials supplied via arguments for SMB user '${SMB_USERNAME}'."
    else
      if [[ "$INTERACTIVE_MODE" != "true" ]]; then
        error "No usable saved credentials and interactive mode is disabled."
        RESULT_MOUNT="fail"
        finalize "$E_NO_CREDENTIALS"
      fi

      if [[ -z "$LOGGED_IN_USER" || "$LOGGED_IN_USER" == "root" ]]; then
        error "Interactive prompt requested but no GUI user is available."
        RESULT_MOUNT="fail"
        finalize "$E_NO_GUI_USER"
      fi

      CREDS="$(prompt_for_credentials)"
      SMB_USERNAME="${CREDS%%||*}"
      SMB_PASSWORD="${CREDS#*||}"

      if [[ -z "$SMB_USERNAME" || "$SMB_USERNAME" == "$CREDS" || -z "$SMB_PASSWORD" ]]; then
        warn "User cancelled or entered incomplete credentials."
        RESULT_MOUNT="fail"
        finalize "$E_NO_CREDENTIALS"
      fi
    fi

    if mount_with_password "$SMB_USERNAME" "$SMB_PASSWORD"; then
      if wait_for_mount_readiness; then
        RESULT_MOUNT="ok"
        log "Mounted successfully using supplied credentials."

        if save_smb_username "$SMB_USERNAME"; then
          log "Saved SMB username to keychain."
        else
          warn "Could not save SMB username to keychain."
        fi

        if save_smb_password "$SMB_USERNAME" "$SMB_PASSWORD"; then
          log "Saved SMB password to keychain."
        else
          warn "Could not save SMB password to keychain."
        fi
      else
        error "Mount command succeeded but mount verification failed."
        RESULT_MOUNT="fail"
        unset SMB_PASSWORD
        finalize "$E_MOUNT_MISMATCH"
      fi
    else
      error "Credential-based mount attempt failed."
      warn "mount_smbfs output (sanitized): $(sanitize_mount_output "$MOUNT_OUTPUT")"
      RESULT_MOUNT="fail"
      unset SMB_PASSWORD
      finalize "$E_MOUNT_FAILED"
    fi

    unset SMB_PASSWORD
  fi
fi
 
if ! is_expected_share_mounted; then
  error "Mounted target verification failed: expected SMB mount not confirmed at ${MOUNT_POINT}"
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