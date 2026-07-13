---
name: Bug report
about: Something in Quickshell Rise is broken or behaves incorrectly
title: "[Bug]: "
labels: bug
---

## What happened?

<!-- Example: The bar reloads, but the AI usage pill stays empty even though codex is running. -->

## What did you expect?

<!-- Example: The Codex usage pill should show the current Weekly limit and open the AI usage panel on click. -->

## Steps to reproduce

1.
2.
3.

## Affected area

<!-- Example: AI usage, theme picker, wallpaper picker, ArchUpdater, network widget, install script, shell updater. -->

## Environment

- Install method: <!-- curl installer / git clone / shell updater / manual -->
- Installed version: <!-- V1 / V2 / unknown -->
- Quickshell version: <!-- qs --version -->
- Omarchy version/setup: <!-- classic Omarchy / Omarchy 4 / custom Hyprland -->
- Hyprland session: <!-- Wayland monitor setup, if relevant -->

## Logs / diagnostics

Please paste relevant output:

```text
qs log -c bar --tail 120
```

If the issue is install/update related:

```bash
cat ~/.config/quickshell/bar/.qsrise-commit
cat ~/.cache/qs-shell/update-available.json
cat ~/.cache/qs-shell/apply-status.json
journalctl --user -u qs-shell-update-check.service -n 100 --no-pager
systemctl --user status qs-shell-update-check.timer
```

## Screenshots or screen recording

<!-- Drag files here if this is a visual/layout problem. -->

## Additional context

<!-- Any local edits, theme name, monitor scale, recently updated packages, or reproduction notes. -->
