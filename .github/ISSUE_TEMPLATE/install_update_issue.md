---
name: Install or update issue
about: Installation, uninstall, autostart, shell updater, or rollback problem
title: "[Install/Update]: "
labels: bug, install
---

## What failed?

<!-- Example: The installer finishes, but `qs -c bar` does not start the bar. -->

## Command used

```bash
# Example:
curl -fsSL https://raw.githubusercontent.com/HANCORE-linux/quickshell-dots/main/install.sh | bash -s V1 --autostart
```

## Expected result

<!-- Example: Bar starts as config `bar`, existing Waybar stops, and update timer is installed. -->

## Actual result

<!-- Paste the exact error/output. -->

```text

```

## Environment

- Fresh install or update from existing install:
- Installed version: <!-- V1 / V2 / unknown -->
- Existing config at `~/.config/quickshell/bar`: <!-- yes/no -->
- `.qsrise` marker present: <!-- yes/no/unknown -->
- Autostart requested: <!-- yes/no -->

## Useful diagnostics

```bash
ls -la ~/.config/quickshell/bar
cat ~/.config/quickshell/bar/.qsrise-commit
cat ~/.cache/qs-shell/update-available.json
cat ~/.cache/qs-shell/apply-status.json
qs list --all
qs log -c bar --tail 120
journalctl --user -u qs-shell-update-check.service -n 100 --no-pager
systemctl --user status qs-shell-update-check.timer
systemctl --user status codex-usage.timer
```

## Rollback / uninstall notes

<!-- Example: uninstall removed the bar, but ~/.cache/codex-usage-activity.json remained. -->
