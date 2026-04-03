# macos-smb-mount-mdm

Enterprise-ready macOS SMB mounting script for MDM deployments (Jamf Pro and Intune), with optional user-facing UX customization (Desktop shortcut, Finder sidebar, Dock entry).

## Version

Current release: **v2.1.0**

---

## Overview

This project provides a deterministic and security-conscious SMB mount workflow for managed macOS devices.

Key goals:
- **MDM-safe defaults** (non-interactive by default)
- **Clear exit codes** for policy/reporting pipelines
- **Idempotent behavior** for repeated policy runs
- **Security-conscious logging** (credential-aware output sanitization)
- **Optional GUI customization** only when required

---

## Important SMB Targeting Note

SMB mounts require a **share/export path** in the form:

`//host/share`

For Azure NetApp Files SMB, configure:
- `ANF_HOST` = SMB endpoint/FQDN
- `SHARE_NAME` = SMB share/export name (not just the Azure volume resource label)

---

## Features

- Mounts an SMB share to a defined mount point.
- Validates mounted resource matches expected **host/share + mountpoint**.
- Supports SMB credential identity separate from local macOS username.
- Stores/reuses SMB username + password in the logged-in user’s **login keychain**.
- Optional bootstrap credentials for first non-interactive run.
- Optional interactive prompt mode for user-assisted runs.
- Optional Finder/Dock/Desktop customization.
- Finder sidebar entry uses a properly URL-encoded `file://` path (handles spaces in volume names).
- Automatic `mysides` installation support:
  - existing binary (`/usr/local/bin` or `/opt/homebrew/bin`)
  - Jamf cached package/binary
  - direct package fallback download when cache is unavailable
- Structured log output + final one-line result summary.

---

## Prerequisites

- macOS managed endpoint
- Root execution context (typical MDM script execution)
- Network path reachable to SMB server
- Logged-in GUI user for interactive mode and/or UI customization

---

## Configuration

Edit these values in `smb-mount-mdm.sh`:

- `ANF_HOST`
- `SHARE_NAME` (SMB share/export name)
- `DOMAIN` (optional; leave empty for local/workgroup auth)
- `DISPLAY_NAME`
- `DESKTOP_LINK_NAME`
- `MOUNT_POINT`

Behavior defaults:
- `INTERACTIVE_MODE="false"`
- `ENABLE_UI_CUSTOMIZATIONS="true"`

---

## CLI Arguments

- `--interactive`
- `--non-interactive`
- `--ui`
- `--no-ui`
- `--smb-user=<username>`
- `--smb-pass=<password>`
- `--smb-domain=<domain>`

> `--smb-user` and `--smb-pass` must be provided together.

---

## Usage Modes

### 1) Non-interactive MDM mode (recommended default)

```bash
sudo bash smb-mount-mdm.sh --non-interactive --no-ui
```

### 2) Non-interactive bootstrap with explicit credentials (first run)

```bash
sudo bash smb-mount-mdm.sh --non-interactive --no-ui --smb-user="admin" --smb-pass="apple"
```

After successful first run, credentials are saved to keychain and reused on subsequent runs.

### 3) Interactive user-assisted mode

```bash
sudo bash smb-mount-mdm.sh --interactive --ui
```

---

## Jamf Pro Deployment

1. Upload script to Jamf Pro.
2. Create policy with:
   - Trigger: Recurring Check-in or Self Service
   - Execution Frequency: Once per computer (initial) or Ongoing (remediation)
3. Recommended arguments:
   - Fleet automation: `--non-interactive --no-ui`
   - First-run bootstrap: `--non-interactive --no-ui --smb-user=<user> --smb-pass=<pass>`
   - User-initiated: `--interactive --ui`

---

## Intune Deployment

1. Add script via Devices → macOS → Shell scripts.
2. Run script as root.
3. For automated runs, use:
   - `--non-interactive --no-ui`
4. If bootstrapping credentials in non-interactive flow, provide:
   - `--smb-user=<user> --smb-pass=<pass>`

---

## Logging

Logs are written to:

`/Library/Application Support/Script Logs/smb-mount-mdm/smb-mount-mdm.log`

Final summary line format:

```text
RESULT: mount=<ok|fail|skip> desktop=<ok|warn|skip> sidebar=<ok|warn|skip> dock=<ok|warn|skip> exit=<code> version=<x.x.x>
```

---

## Exit Codes

- `0` success
- `10` no GUI user for required interactive/UI mode
- `11` user context resolution failed
- `12` invalid arguments
- `20` mysides installation/check failed
- `30` credentials unavailable (non-interactive or user cancelled)
- `31` mount attempt failed
- `32` mounted resource mismatch verification failed

---

## Security Notes

- Passwords are not logged.
- Mount error output is sanitized before logging.
- Script avoids destructive Desktop operations.
- macOS may show a keychain permission/update prompt when an existing SMB keychain item is updated (`security ... -U`).
- Default recommendation remains non-interactive MDM flow with optional one-time bootstrap credentials.

---

## Version History

| Version | Date       | Notes |
|--------:|------------|-------|
| v2.1.0  | 2026-04-03 | Added separate SMB identity support, bootstrap creds flags, optional domain override, explicit login-keychain handling, non-interactive mount behavior (`-N`), host/share verification hardening, sanitized mount error logging, and URL-encoded Finder sidebar path handling. |
| v1.0.0  | 2026-04-01 | Initial enterprise-ready release with deterministic exit codes, safer Desktop handling, improved mount verification, and robust `mysides` installation fallback support. |

---

## License

Internal use / company-managed deployment.
