#!/usr/bin/env bash
# Quickshell Rise — uninstaller (version-agnostic; removes whatever is installed)
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/HANCORE-linux/quickshell-dots/main/uninstall.sh)
set -euo pipefail

DEST="$HOME/.config/quickshell/bar"

c_g=$'\e[32m'; c_y=$'\e[33m'; c_0=$'\e[0m'
info() { printf "%s==>%s %s\n" "$c_g" "$c_0" "$*"; }
warn() { printf "%s!!%s %s\n"  "$c_y" "$c_0" "$*"; }

# 0. ownership guard — refuse to touch ANYTHING if a config dir exists that we
# did not install (install.sh writes .qsrise). Checked before any removal so a
# foreign install aborts cleanly instead of losing helpers/units/lists first.
if [[ -d "$DEST" && ! -e "$DEST/.qsrise" ]]; then
  warn "$DEST was not installed by Quickshell Rise (no .qsrise marker) — leaving everything untouched."
  exit 1
fi

# 1. stop the running bar
# stop existing bar (supports both -c bar and -p $DEST modes)
pkill -f "qs.*-c bar" 2>/dev/null && info "Stopped the bar" || true
pkill -f "quickshell -p $DEST" 2>/dev/null && info "Stopped the bar" || true

# 1b. remove the Claude usage backend, if it was installed (idempotent).
# Covers the current OAuth backend and any older split cookie/calc install.
unitdir="$HOME/.config/systemd/user"
bindir="$HOME/.local/bin"
if compgen -G "$unitdir/claude-usage*" >/dev/null 2>&1 || compgen -G "$bindir/claude-usage*" >/dev/null 2>&1; then
  # stop + disable timers AND services (covers a oneshot run that's mid-flight)
  systemctl --user disable --now \
    claude-usage.timer claude-usage-cookie.timer claude-usage-calc.timer >/dev/null 2>&1 || true
  systemctl --user stop \
    claude-usage.service claude-usage-cookie.service claude-usage-calc.service >/dev/null 2>&1 || true
  rm -f "$unitdir"/claude-usage.service       "$unitdir"/claude-usage.timer \
        "$unitdir"/claude-usage-calc.service   "$unitdir"/claude-usage-calc.timer \
        "$unitdir"/claude-usage-cookie.service "$unitdir"/claude-usage-cookie.timer
  rm -f "$bindir"/claude-usage "$bindir"/claude-usage-calc "$bindir"/claude-usage-cookie
  rm -f "$HOME/.cache/claude-usage.json" "$HOME/.cache/claude-usage-api.json" \
        "$HOME/.cache/claude-usage-skip" "$HOME/.cache/claude-usage-notified" \
        "$HOME/.cache/claude-usage-calibration.json"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed 'claude-usage*' >/dev/null 2>&1 || true   # clear any ghost state
  # belt-and-suspenders: kill any lingering process (there shouldn't be one)
  pkill -f "$bindir/claude-usage" 2>/dev/null || true
  info "Removed Claude usage backend (script, timer, cache; nothing left running)"
fi

# 1b2. remove the Codex usage backend, if it was installed (idempotent).
# Pairs with the AI usage widget's Codex side (install_codex_backend in install.sh).
if compgen -G "$unitdir/codex-usage*" >/dev/null 2>&1 || compgen -G "$bindir/codex-usage*" >/dev/null 2>&1; then
  systemctl --user disable --now codex-usage.timer >/dev/null 2>&1 || true
  systemctl --user stop codex-usage.service >/dev/null 2>&1 || true
  rm -f "$unitdir"/codex-usage.service "$unitdir"/codex-usage.timer
  rm -f "$bindir"/codex-usage
  rm -f "$HOME/.cache/codex-usage.json"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed 'codex-usage*' >/dev/null 2>&1 || true   # clear any ghost state
  pkill -f "$bindir/codex-usage" 2>/dev/null || true
  info "Removed Codex usage backend (script, timer, cache; nothing left running)"
fi

# 1b3. remove the OpenCode usage backend, if it was installed (idempotent).
if compgen -G "$unitdir/opencode-usage*" >/dev/null 2>&1 || compgen -G "$bindir/opencode-usage*" >/dev/null 2>&1; then
  systemctl --user disable --now opencode-usage.timer >/dev/null 2>&1 || true
  systemctl --user stop opencode-usage.service >/dev/null 2>&1 || true
  rm -f "$unitdir"/opencode-usage.service "$unitdir"/opencode-usage.timer
  rm -f "$bindir"/opencode-usage
  rm -f "$HOME/.cache/opencode-usage.json"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed 'opencode-usage*' >/dev/null 2>&1 || true
  pkill -f "$bindir/opencode-usage" 2>/dev/null || true
  info "Removed OpenCode usage backend (script, timer, cache; nothing left running)"
fi

# 1c. remove the shell self-updater, if installed (idempotent).
qsbindir="$HOME/.config/quickshell/bin"
if compgen -G "$unitdir/qs-shell-update-check.*" >/dev/null 2>&1 || [[ -e "$qsbindir/qs-shell-check-update.sh" ]]; then
  systemctl --user disable --now qs-shell-update-check.timer >/dev/null 2>&1 || true
  systemctl --user stop qs-shell-update-check.service >/dev/null 2>&1 || true
  rm -f "$unitdir"/qs-shell-update-check.service "$unitdir"/qs-shell-update-check.timer
  rm -f "$qsbindir"/qs-shell-check-update.sh "$qsbindir"/qs-shell-apply-update.sh
  rm -rf "$HOME/.cache/qs-shell" "$HOME/.local/share/quickshell-dots" \
         "${XDG_STATE_HOME:-$HOME/.local/state}/qs-shell"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed 'qs-shell-update-check*' >/dev/null 2>&1 || true
  info "Removed shell self-updater (scripts, timer, cache, updater clone)"
fi

# 1c.1 remove the theme update checker, if installed (idempotent).
if [[ -e "$qsbindir/qs-theme-update-check.sh" || -e "$qsbindir/qs-theme-apply-update.sh" || -e "$HOME/.cache/qs-theme-updates.json" ]]; then
  rm -f "$qsbindir"/qs-theme-update-check.sh \
        "$qsbindir"/qs-theme-apply-update.sh \
        "$HOME/.cache/qs-theme-updates.json" \
        "$HOME/.cache/qs-theme-update.lock"
  info "Removed theme update helpers (scripts, cache, lock)"
fi

# 1d. remove the ArchUpdater security gate (script, fetch timer, list)
if [[ -f "$bindir/qs-arch-security-gate.sh" || -f "$bindir/qs-aur-blacklist-fetch.sh" ]]; then
  systemctl --user disable --now qs-aur-blacklist-fetch.timer >/dev/null 2>&1 || true
  systemctl --user stop qs-aur-blacklist-fetch.service >/dev/null 2>&1 || true
  rm -f "$unitdir"/qs-aur-blacklist-fetch.service "$unitdir"/qs-aur-blacklist-fetch.timer
  rm -f "$bindir"/qs-arch-security-gate.sh "$bindir"/qs-aur-blacklist-fetch.sh
  # generated artifacts (cache, regenerated by the fetcher) — safe to remove
  rm -f "$HOME/.local/share/qs-aur-blacklist.txt" \
        "$HOME/.local/share/qs-aur-blacklist.txt.meta.json" \
        "$HOME/.local/share/qs-aur-blacklist.txt.pending"
  # the supplement is user-editable (ad-hoc additions survive refreshes) — keep it
  if [[ -f "$HOME/.local/share/qs-aur-blacklist.local.txt" ]]; then
    info "Kept blacklist supplement (qs-aur-blacklist.local.txt) — delete it manually to purge"
  fi
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed 'qs-aur-blacklist-fetch*' >/dev/null 2>&1 || true
  info "Removed ArchUpdater security gate (script, fetch timer, list)"
fi

# 2. remove the post-boot hook (if the user installed it)
boot="$HOME/.config/omarchy/hooks/post-boot.d/quickshell-rise"
[[ -f "$boot" ]] && { rm -f "$boot"; info "Removed post-boot hook"; }

# 3. remove the theme hook we installed
hook="$HOME/.config/omarchy/hooks/theme-set.d/50-quickshell-bar.sh"
[[ -f "$hook" ]] && { rm -f "$hook"; info "Removed theme hook"; }

# 4. remove the config — restore the most recent backup if one exists
# (ownership already verified at the top: $DEST is ours, or does not exist)
restored=false
if [[ -d "$DEST" ]]; then
  rm -rf "$DEST"
  latest="$(ls -dt "$DEST".bak.* 2>/dev/null | head -1 || true)"
  if [[ -n "${latest:-}" ]]; then
    mv "$latest" "$DEST"
    info "Restored previous config from backup ($(basename "$latest"))"
    restored=true
  else
    info "Removed $DEST"
  fi
else
  warn "Nothing installed at $DEST"
fi

# 4b. remove saved bar settings (widget toggles, splits, slot order)
if compgen -G "$HOME/.cache/quickshell_*" >/dev/null 2>&1; then
  rm -f "$HOME/.cache/quickshell_widgets" "$HOME/.cache/quickshell_splits" \
        "$HOME/.cache/quickshell_barorder" "$HOME/.cache/quickshell_barsplits"
  info "Removed saved bar settings (widget toggles, splits, slot order)"
fi

# 4c. remove small runtime caches owned by this bar
rm -f "$HOME/.cache/qs-reactor-event" "$HOME/.cache/qs-rise-notifications.json"

# 5. restart the bar that was in use before install
if [[ "$restored" == true ]] && [[ -f "$DEST/shell.qml" ]]; then
  setsid quickshell -p "$DEST" >/dev/null 2>&1 & disown
  info "Restarted quickshell from backup"
else
  if command -v omarchy &>/dev/null; then
    omarchy restart waybar 2>/dev/null && info "Restarted waybar" || true
  else
    setsid waybar >/dev/null 2>&1 & disown 2>/dev/null || true
    info "Restarted waybar"
  fi
fi

info "Uninstalled.${c_0}  (older backups under ~/.config/quickshell/bar.bak.* are kept)"
