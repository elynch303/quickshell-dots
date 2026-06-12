#!/usr/bin/env bash
# QS-Shell apply update.
#
# Topology: the live bar dir is a *copy* of versions/<V>/ from the SEPARATE git
# repo at ~/Projects/Quickshell-Dots. Updating = pull that repo, redeploy the
# installed version into the live dir, restart the bar.
#
# MUST be launched DETACHED from the bar (the QML button uses `setsid`), because
# this script restarts the bar.
#
# Safety contract:
#   - single-flight (flock): no concurrent applies
#   - refuses on a dirty or diverged repo (the repo is the user's workspace)
#   - ALWAYS backs up the live dir first (it may hold un-synced live edits)
#   - atomic same-filesystem rename swap with automatic rollback: $DEST always
#     holds the old OR the new tree in full, and any failure leaves a running bar
#   - persisted settings (slot order / splits) live in ~/.cache and are untouched
set -euo pipefail

REPO="${QS_SHELL_REPO:-$HOME/.local/share/quickshell-dots}"
DEST="${QS_SHELL_DEST:-$HOME/.config/quickshell/bar}"
STATE_DIR="$HOME/.cache/qs-shell"
STATE="$STATE_DIR/update-available.json"
# Backups live in STATE_HOME (durable), NOT in ~/.cache — caches get tmpfs-mounted
# or wiped by hygiene tools, and the backup is the rollback's last-resort restore.
BACKUP_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/qs-shell/backups"
mkdir -p "$STATE_DIR"

note() { notify-send -a "QS-Shell" "$@" 2>/dev/null || true; }
fail() { note -u critical "Shell update failed" "$1"; exit 1; }

# Single-flight: a second click (the panel lingers ~120ms while closing) must not
# start a concurrent rm/rename on $DEST.
exec 9>"$STATE_DIR/apply.lock"
if ! flock -n 9; then
  note "Shell update" "An update is already running."
  exit 0
fi

# Sweep any stage dir orphaned by a previously hard-killed run (SIGKILL / power
# loss skips the EXIT trap). Safe here: the flock above guarantees no other apply
# is mid-run, so no live stage can be hit.
rm -rf "$(dirname "$DEST")"/.qs-stage.* 2>/dev/null || true

# State contract: never delete the state file; "up to date" is behind:0 (atomic).
clear_state() {
  local t
  t="$(mktemp -p "$STATE_DIR")" || return 0
  printf '{"behind": 0, "checked": "%s"}\n' "$(date -Is)" > "$t" && mv "$t" "$STATE" || rm -f "$t"
}

ver="V1"
[ -f "$DEST/.qsrise" ] && ver="$(tr -d '[:space:]' < "$DEST/.qsrise")"
[ -n "$ver" ] || ver="V1"

[ -d "$REPO/.git" ] || fail "Repo not found at $REPO"
cd "$REPO"

# 1. Don't disturb a repo the user is mid-edit in.
[ -z "$(git status --porcelain)" ] || \
  fail "Repo has uncommitted changes — commit or stash in $REPO first."

# 2. Fast-forward only. Diverged local commits must never be lost.
git fetch --quiet origin || fail "Could not reach origin (offline?)."
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" \
  || fail "No upstream tracking branch in $REPO."
if ! git merge-base --is-ancestor HEAD "$upstream"; then
  fail "Local branch diverged from $upstream — resolve manually (git status in $REPO)."
fi
git pull --ff-only --quiet || fail "git pull failed in $REPO."

[ -d "$REPO/versions/$ver" ] || fail "Version '$ver' missing in repo after pull."

# 3. Always back up the live dir before overwriting (protects un-synced edits).
mkdir -p "$BACKUP_ROOT"
ts="$(date +%Y%m%d-%H%M%S)"
backup="$BACKUP_ROOT/bar.$ts"
cp -a "$DEST" "$backup"
# keep only the 3 most recent backups
ls -1dt "$BACKUP_ROOT"/bar.* 2>/dev/null | tail -n +4 | xargs -r rm -rf

# 4. Stage in $DEST's OWN parent directory — same filesystem by construction, so
#    the swap is guaranteed an atomic rename (never a cross-FS copy that could be
#    interrupted mid-write, regardless of how ~/.cache or ~/.local are mounted).
#    The bar watches the `bar` config dir specifically, so a sibling .qs-stage.*
#    dir is ignored. Clean the stage on any exit.
stage="$(mktemp -d -p "$(dirname "$DEST")" .qs-stage.XXXXXX)"
trap 'rm -rf "$stage" 2>/dev/null || true' EXIT
cp -r "$REPO/versions/$ver/." "$stage/"
printf '%s\n' "$ver" > "$stage/.qsrise"

# Stop the bar before swapping, and WAIT for it to actually exit (don't trust a
# fixed sleep). NB: pkill -x qs matches ALL qs instances (fine on this single-bar
# system).
if [ -z "${QS_SHELL_NO_RESTART:-}" ]; then
  pkill -x qs 2>/dev/null || true
  for _ in $(seq 1 30); do pgrep -x qs >/dev/null 2>&1 || break; sleep 0.1; done
fi

# Atomic swap with rollback. At every instant $DEST holds either the old or the
# new tree in full; any failure restores a working bar and notifies.
old="$DEST.old.$ts"
rollback() {
  local msg
  if [ ! -e "$DEST" ]; then            # old tree was moved aside, swap-in failed → restore
    if [ -d "$old" ]; then
      mv "$old" "$DEST" 2>/dev/null || cp -a "$backup" "$DEST" 2>/dev/null || true
    else
      cp -a "$backup" "$DEST" 2>/dev/null || true
    fi
    msg="Deploy failed — previous version restored."
  else                                 # $DEST never changed (the aside-move itself failed)
    msg="Update aborted before any change — bar restarted unchanged."
  fi
  rm -rf "$old" 2>/dev/null || true
  # 9>&- : do NOT leak the flock fd into the relaunched bar, or it holds the lock
  # for its whole lifetime and blocks every future update (see normal path below).
  if [ -z "${QS_SHELL_NO_RESTART:-}" ]; then
    setsid qs -n -d -c bar >/dev/null 2>&1 9>&- < /dev/null &
  fi
  note -u critical "Shell update failed" "$msg"
}
trap 'rollback' ERR

mv "$DEST" "$old"        # atomic rename (same FS)
mv "$stage" "$DEST"      # atomic rename (same FS)
trap - ERR
rm -rf "$old" 2>/dev/null || true
trap - EXIT              # $stage was renamed into place; nothing left to clean

# 5. Mark up-to-date via an atomic state write (never delete).
clear_state

# 6. Relaunch exactly how the user runs it. The Wayland session env is inherited
#    via the chain bar → setsid → this script (so only ever call apply from the
#    session, never from the timer). 9>&- closes the flock fd so the new bar does
#    NOT inherit the lock — otherwise it would hold it for its whole lifetime and
#    every future update would fail with "already running" (flock is on the OFD).
if [ -z "${QS_SHELL_NO_RESTART:-}" ]; then
  setsid qs -n -d -c bar >/dev/null 2>&1 9>&- < /dev/null &
fi

note "Shell updated" "Now on the latest '$ver'. Backup kept at $backup"
