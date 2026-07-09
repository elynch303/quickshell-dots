#!/usr/bin/env bash
# QS-Shell apply update.
#
# Topology: the live bar dir is a *copy* of versions/<V>/ from the deploy clone
# at ~/.local/share/quickshell-dots by default (override with QS_SHELL_REPO).
# Updating = read the checked state, verify the immutable target commit, deploy
# exactly that commit's version payload, restart the bar.
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
[ "$DEST" != "/" ] && DEST="${DEST%/}"
STATE_DIR="$HOME/.cache/qs-shell"
STATE="$STATE_DIR/update-available.json"
SCHEMA_VERSION=2
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

# State contract: never delete the state file; "up to date" is behind:0 (atomic).
clear_state() {
  local t
  t="$(mktemp -p "$STATE_DIR")" || return 0
  if printf '{"schemaVersion": %d, "behind": 0, "checked": "%s"}\n' "$SCHEMA_VERSION" "$(date -Is)" > "$t" \
      && mv "$t" "$STATE"; then
    return 0
  fi
  rm -f "$t"
}

is_commit_hash() {
  [[ "$1" =~ ^[0-9a-f]{40}$ || "$1" =~ ^[0-9a-f]{64}$ ]]
}

read_pending_state() {
  local parsed
  [ -r "$STATE" ] || fail "No pending shell update state."
  parsed="$(jq -r --argjson schema "$SCHEMA_VERSION" '
    if .schemaVersion == $schema
       and ((.behind // 0) > 0)
       and (.repository | type == "string")
       and (.upstreamRef | type == "string")
       and (.baseCommit | type == "string")
       and (.targetCommit | type == "string")
       and (.version | type == "string")
    then [.repository, .upstreamRef, .baseCommit, .targetCommit, .version] | @tsv
    else empty end
  ' "$STATE" 2>/dev/null)" || fail "Could not read shell update state."
  [ -n "$parsed" ] || fail "Shell update state is missing immutable target data."
  IFS=$'\t' read -r state_repo state_upstream state_base state_target state_version <<< "$parsed"
  is_commit_hash "$state_base" || fail "Stored base commit is invalid."
  is_commit_hash "$state_target" || fail "Stored target commit is invalid."
}

bar_pids() {
  local cfg="$DEST/shell.qml"
  qs list --all 2>/dev/null | awk -v cfg="$cfg" '
    $1 == "Process" && $2 == "ID:" { pid = $3 }
    /^[[:space:]]*Config path:/ {
      path = $0
      sub(/^[[:space:]]*Config path:[[:space:]]*/, "", path)
      gsub(/^"|"$/, "", path)
      if (path == cfg && pid != "") print pid
      pid = ""
    }
  ' || true
}

stop_registered_bars() {
  local rounds="${1:-60}" stable="${2:-5}"
  local pids pid quiet=0

  # Crash-relaunched Quickshell instances can respawn after a TERM. Rescan on
  # every pass and require a short stable-empty window before trusting that the
  # old bar is gone.
  for _ in $(seq 1 "$rounds"); do
    pids="$(bar_pids | sort -u)"
    if [ -z "$pids" ]; then
      quiet=$((quiet + 1))
      [ "$quiet" -ge "$stable" ] && return 0
    else
      quiet=0
      for pid in $pids; do
        kill -TERM "$pid" 2>/dev/null || true
      done
    fi
    sleep 0.1
  done

  [ -z "$(bar_pids | sort -u)" ]
}

legacy_bar_running() {
  pgrep -f 'qs.* -c bar([[:space:]]|$)' >/dev/null 2>&1 || \
    pgrep -f "quickshell -p $DEST" >/dev/null 2>&1
}

stop_legacy_bars() {
  # Legacy fallback for installs too old to show up in `qs list`, and a backup
  # if Quickshell's registry misses an instance.
  pkill -f 'qs.* -c bar([[:space:]]|$)' 2>/dev/null || true
  pkill -f "quickshell -p $DEST" 2>/dev/null || true
  for _ in $(seq 1 50); do
    legacy_bar_running || return 0
    sleep 0.1
  done

  ! legacy_bar_running
}

stop_bar_instances() {
  local rc=0

  stop_registered_bars 60 5 || true
  stop_legacy_bars || rc=1
  # One final registry pass catches a crash-relaunch that appeared while the
  # legacy command-line fallback was waiting.
  stop_registered_bars 30 5 || rc=1
  return "$rc"
}

ver="V1"
[ -f "$DEST/.qsrise" ] && ver="$(tr -d '[:space:]' < "$DEST/.qsrise")"
[ -n "$ver" ] || ver="V1"

[ -d "$REPO/.git" ] || fail "Repo not found at $REPO"
cd "$REPO"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "Repo is not a valid git checkout."
head_commit="$(git rev-parse 'HEAD^{commit}' 2>/dev/null)" || fail "Repo HEAD is not a commit."
read_pending_state
[ "$state_repo" = "$repo_root" ] || fail "Pending update belongs to a different repo."
[ "$state_version" = "$ver" ] || fail "Pending update targets '$state_version', but installed version is '$ver'."

current_base="$head_commit"
if [ -f "$DEST/.qsrise-commit" ]; then
  deployed_commit="$(tr -d '[:space:]' < "$DEST/.qsrise-commit" 2>/dev/null || true)"
  if is_commit_hash "$deployed_commit" && git cat-file -e "$deployed_commit^{commit}" 2>/dev/null; then
    current_base="$deployed_commit"
  fi
fi
[ "$current_base" = "$state_base" ] || fail "Pending update is stale — refresh the shell update check first."

# 1. Don't disturb a repo the user is mid-edit in.
[ -z "$(git status --porcelain)" ] || \
  fail "Repo has uncommitted changes — commit or stash in $REPO first."

# 2. Refresh refs, then prove that the stored immutable target is still a valid
#    commit from the expected upstream. Never install the moving branch tip.
git fetch --quiet origin || fail "Could not reach origin (offline?)."
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" \
  || fail "No upstream tracking branch in $REPO."
[ "$upstream" = "$state_upstream" ] || fail "Upstream changed since check — refresh first."
git cat-file -e "$state_base^{commit}" 2>/dev/null || fail "Stored base commit is not available locally."
git cat-file -e "$state_target^{commit}" 2>/dev/null || fail "Stored target commit is not available locally."
git merge-base --is-ancestor "$state_base" "$state_target" 2>/dev/null || \
  fail "Stored target is not a fast-forward from the checked base."
git merge-base --is-ancestor "$state_target" "$state_upstream" 2>/dev/null || \
  fail "Stored target is no longer reachable from $state_upstream."
git cat-file -e "$state_target:versions/$ver" 2>/dev/null || \
  fail "Version '$ver' missing at stored target commit."

# Sweep any stage dir orphaned by a previously hard-killed run (SIGKILL / power
# loss skips the EXIT trap). Safe here: the flock above guarantees no other apply
# is mid-run, and provenance has already been validated.
rm -rf "$(dirname "$DEST")"/.qs-stage.* 2>/dev/null || true

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
companion=""
cleanup() {
  [ -n "${stage:-}" ] && rm -rf "$stage" 2>/dev/null || true
  [ -n "${companion:-}" ] && rm -rf "$companion" 2>/dev/null || true
}
trap cleanup EXIT
git archive "$state_target:versions/$ver" | tar -x -C "$stage" || \
  fail "Could not stage version '$ver' from stored target commit."
if [ -f "$backup/quotes.txt" ]; then
  cp -p "$backup/quotes.txt" "$stage/quotes.txt"
fi
printf '%s\n' "$ver" > "$stage/.qsrise"
printf '%s\n' "$state_target" > "$stage/.qsrise-commit"

companion_paths=()
for p in scripts systemd; do
  if git cat-file -e "$state_target:$p" 2>/dev/null; then
    companion_paths+=("$p")
  fi
done
if [ "${#companion_paths[@]}" -gt 0 ]; then
  companion="$(mktemp -d -p "$STATE_DIR" companion.XXXXXX)" || fail "Could not create companion stage."
  git archive "$state_target" "${companion_paths[@]}" | tar -x -C "$companion" || \
    fail "Could not stage companion files from stored target commit."
fi

# Stop the bar before swapping, and WAIT for it to actually exit (don't trust a
# fixed sleep). Prefer Quickshell's registered config path over command-line
# matching: after IPC/crash recovery, the same bar can show up as
# `/usr/bin/quickshell`, not `qs -c bar`.
if [ -z "${QS_SHELL_NO_RESTART:-}" ]; then
  stop_bar_instances || fail "Could not stop the old bar instance safely."
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
stage=""
trap - ERR
rm -rf "$old" 2>/dev/null || true

# 5. Mark up-to-date via an atomic state write (never delete).
clear_state

# 5b. Companion pieces (helper scripts, systemd units): refresh them from the
#     same stored target commit so a bar update is complete on its own — no
#     manual install.sh re-run. Best-effort: a hiccup here never blocks the
#     already-applied update.
if [ -n "$companion" ] && [ -f "$companion/scripts/qs-shell-post-update.sh" ]; then
  bash "$companion/scripts/qs-shell-post-update.sh" "$companion" >/dev/null 2>&1 || \
    note "Shell update" "Companion refresh incomplete — re-run install.sh if a widget misses its helper."
fi

# 6. Relaunch exactly how the user runs it. The Wayland session env is inherited
#    via the chain bar → setsid → this script (so only ever call apply from the
#    session, never from the timer). 9>&- closes the flock fd so the new bar does
#    NOT inherit the lock — otherwise it would hold it for its whole lifetime and
#    every future update would fail with "already running" (flock is on the OFD).
if [ -z "${QS_SHELL_NO_RESTART:-}" ]; then
  setsid qs -n -d -c bar >/dev/null 2>&1 9>&- < /dev/null &
fi

note "Shell updated" "Now on reviewed '$ver' at ${state_target:0:12}. Backup kept at $backup"
