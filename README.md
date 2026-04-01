# macos-smb-mount-mdm

Enterprise-ready macOS SMB mounting script for MDM deployments (Jamf Pro and Intune), with optional user-facing UX customization (Desktop shortcut, Finder sidebar, Dock entry).

## Version

Current release: **v1.0.0**

---

## Overview

This project provides a safer and more deterministic SMB mount workflow for managed macOS devices.

Key goals:
- **MDM-safe defaults** (non-interactive by default)
- **Clear exit codes** for policy/reporting pipelines
- **Idempotent behavior** for repeated policy runs
- **Security-conscious logging** (no credential logging)
- **Optional GUI customization** only when a GUI user is present

---

## Features

- Mounts an SMB share to a defined mount point.
- Validates that the mounted resource matches expected host/share (not just mountpoint).
- Defaults to cached/SSO credential attempt first.
- Optional interactive password fallback (`--interactive`) for Self Service/helpdesk scenarios.
- Optional Finder/Dock/Desktop customization.
- Structured log output + final one-line result summary.

---

## Prerequisites

- macOS managed endpoint
- Root execution context (typical MDM script execution)
- Network path reachable to your SMB server
- Optional for Finder sidebar automation:
  - `mysides` binary in:
    - `/usr/local/bin/mysides` or `/opt/homebrew/bin/mysides`
  - or Jamf-cached installer/binary:
    - `/Library/Application Support/JAMF/Downloads/mysides.pkg`
    - `/Library/Application Support/JAMF/Downloads/mysides`

---

## Configuration

Edit these values in `smb-mount-mdm.sh`:

- `ANF_HOST`
- `SHARE_NAME`
- `DOMAIN`
- `DISPLAY_NAME`
- `DESKTOP_LINK_NAME`
- `MOUNT_POINT`

Behavior flags:
- `INTERACTIVE_MODE="false"` (default)
- `ENABLE_UI_CUSTOMIZATIONS="true"` (default)

---

## Usage Modes

### 1) Non-interactive MDM mode (recommended default)

```bash
sudo bash smb-mount-mdm.sh --non-interactive --no-ui
```

Use for:
- Automated remediation
- Repeating scheduled policies
- Enrollment-stage checks where GUI may not be available

### 2) Interactive user-assisted mode

```bash
sudo bash smb-mount-mdm.sh --interactive --ui
```

Use for:
- Self Service workflows
- Helpdesk-assisted runs where user can enter credentials

---

## Jamf Pro Deployment

1. Upload script to Jamf Pro.
2. Create policy with:
   - Trigger: Recurring Check-in or Self Service
   - Execution Frequency: Once per computer (for initial) or Ongoing (for remediation)
3. If using Finder sidebar support, ensure `mysides` is installed/cached before script step.
4. Recommended arguments:
   - Fleet automation: `--non-interactive --no-ui`
   - User-initiated: `--interactive --ui`

---

## Intune Deployment

1. Add script via Devices → macOS → Shell scripts.
2. Run script as root.
3. For fully automated runs, use non-interactive flags:
   - `--non-interactive --no-ui`
4. Use interactive mode only when user session + UI prompt flow is expected.

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
- `20` mysides installation/check failed
- `30` credentials unavailable (non-interactive or user cancelled)
- `31` mount attempt failed
- `32` mounted resource mismatch verification failed

---

## Security Notes

- Script does **not** log passwords.
- Script avoids destructive `rm -rf` behavior on user Desktop path.
- Interactive fallback may still require credential material for SMB URL auth path due to platform tooling behavior.
- Prefer enterprise SSO/cached credentials for true zero-touch operation.

---

## Testing Evidence

### Functional validation completed locally
- Syntax and script flow validated.
- Idempotency and safety logic reviewed.

### Remote VM validation
- Target provided: `192.168.8.27`
- SSH authentication with provided credentials (`admin/admin`) was **not successful** from this environment.
- Because of that, full remote execution evidence is pending access confirmation.

Recommended quick test commands on VM once credentials/access are confirmed:

```bash
sudo bash smb-mount-mdm.sh --non-interactive --no-ui
echo $?
log show --last 5m --predicate 'process == "bash"' --style compact
cat "/Library/Application Support/Script Logs/smb-mount-mdm/smb-mount-mdm.log"
```

---

## Troubleshooting

- **Exit 30**: no valid credentials in non-interactive mode
  - Verify SSO/keychain state or use `--interactive` in user-driven flow.
- **Exit 31/32**: mount failed/mismatch
  - Verify DNS, share permissions, SMB path values, network reachability.
- **Sidebar skipped/warn**
  - Verify `mysides` availability and GUI user session.

---

## Version History

| Version | Date       | Notes |
|--------:|------------|-------|
| v1.0.0  | 2026-04-01 | Initial enterprise-ready release with non-interactive default, deterministic exit codes, safer Desktop handling, and improved mount verification. |

---

## License

Internal use / company-managed deployment.
