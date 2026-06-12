#!/usr/bin/env bash
# QS-Shell post-update hook.
#
# Called by qs-shell-apply-update.sh after every successful shell update, with
# the repo root as $1. Installs/refreshes the companion pieces that live
# OUTSIDE the bar config dir — helper scripts and systemd user units — so a
# bar update is complete on its own and never needs a manual install.sh re-run.
#
# Idempotent and defensive: a missing source file is skipped, a failing step
# warns the caller via exit code but must never break the already-applied
# update. Opt-in components (Claude backend) are refreshed only if present.
set -uo pipefail

repo="${1:-${QS_SHELL_REPO:-$HOME/.local/share/quickshell-dots}}"
bin="$HOME/.local/bin"
qsbin="$HOME/.config/quickshell/bin"
units="$HOME/.config/systemd/user"

# install via temp + rename: the target gets a NEW inode, so replacing a script
# that is currently executing (e.g. the apply script calling us) is safe.
put() { # src dst mode
  local src="$1" dst="$2" mode="$3" t
  [ -f "$src" ] || return 0
  t="$(mktemp "$dst.XXXXXX")" || return 1
  cp "$src" "$t" && chmod "$mode" "$t" && mv -f "$t" "$dst" || { rm -f "$t"; return 1; }
}

rc=0
mkdir -p "$bin" "$qsbin" "$units"

# ── ArchUpdater security gate + weekly blacklist refresh ───────
put "$repo/scripts/qs-arch-security-gate.sh" "$bin/qs-arch-security-gate.sh" 755 || rc=1
if put "$repo/scripts/qs-aur-blacklist-fetch.sh" "$bin/qs-aur-blacklist-fetch.sh" 755; then
  put "$repo/systemd/qs-aur-blacklist-fetch.service" "$units/qs-aur-blacklist-fetch.service" 644 || rc=1
  put "$repo/systemd/qs-aur-blacklist-fetch.timer"   "$units/qs-aur-blacklist-fetch.timer"   644 || rc=1
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user enable --now qs-aur-blacklist-fetch.timer >/dev/null 2>&1 || true
  # prime the list once so the gate is armed right away (keep an existing list)
  [ -s "$HOME/.local/share/qs-aur-blacklist.txt" ] || \
    "$bin/qs-aur-blacklist-fetch.sh" >/dev/null 2>&1 || true
else
  rc=1
fi

# ── keep the updater itself current (check + apply + this hook) ─
put "$repo/scripts/qs-shell-check-update.sh" "$qsbin/qs-shell-check-update.sh" 755 || rc=1
put "$repo/scripts/qs-shell-apply-update.sh" "$qsbin/qs-shell-apply-update.sh" 755 || rc=1
put "$repo/systemd/qs-shell-update-check.service" "$units/qs-shell-update-check.service" 644 || rc=1
put "$repo/systemd/qs-shell-update-check.timer"   "$units/qs-shell-update-check.timer"   644 || rc=1

# Re-arm both timers so refreshed unit files take effect now. Plain
# enable --now is a no-op on an already-active timer, and a daemon-reload
# alone can leave a monotonic timer "elapsed" with no next trigger.
systemctl --user daemon-reload >/dev/null 2>&1 || true
systemctl --user enable --now qs-shell-update-check.timer >/dev/null 2>&1 || true
systemctl --user try-restart qs-shell-update-check.timer qs-aur-blacklist-fetch.timer >/dev/null 2>&1 || true

# ── opt-in components: refresh only if the user installed them ──
if [ -x "$bin/claude-usage" ]; then
  put "$repo/scripts/claude-usage" "$bin/claude-usage" 755 || rc=1
fi

exit "$rc"
