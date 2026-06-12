#!/usr/bin/env bash
# QS-Shell update check (writes a state file the bar watches; no apply here).
#
# Topology of THIS setup: the live bar dir is a *copy* of versions/<V>/ from the
# SEPARATE git repo at ~/Projects/Quickshell-Dots. We never run git in the live
# dir — we compare the repo's tracking branch against origin, scoped to the
# installed version's directory.
#
# State contract: ~/.cache/qs-shell/update-available.json ALWAYS exists.
#   "up to date" = {"behind": 0}.  Pending   = {"behind": N, "version", "summary", "checked"}.
# The bar's FileView only ever reads a complete file via atomic replace and never
# depends on delete-detection.
set -euo pipefail

REPO="${QS_SHELL_REPO:-$HOME/.local/share/quickshell-dots}"
DEST="${QS_SHELL_DEST:-$HOME/.config/quickshell/bar}"
STATE_DIR="$HOME/.cache/qs-shell"
STATE="$STATE_DIR/update-available.json"
mkdir -p "$STATE_DIR"

# jq is required (and a hard dependency in install.sh). Warn once rather than
# failing silently under `set -e` after a successful fetch.
if ! command -v jq >/dev/null 2>&1; then
  notify-send -a "QS-Shell" "Shell update check disabled" "jq is not installed." 2>/dev/null || true
  exit 0
fi

# Never leak the temp state file on any error path.
STATE_TMP=""
trap '[ -n "$STATE_TMP" ] && rm -f "$STATE_TMP"' EXIT

write_state() {                       # $1 = complete JSON; atomic replace
  STATE_TMP="$(mktemp -p "$STATE_DIR")"
  printf '%s\n' "$1" > "$STATE_TMP"
  mv "$STATE_TMP" "$STATE"
  STATE_TMP=""
}
clear_state() { write_state "$(jq -nc --arg c "$(date -Is)" '{behind: 0, checked: $c}')"; }

# Installed version (.qsrise marker; this install predates it → fall back to V1).
ver="V1"
[ -f "$DEST/.qsrise" ] && ver="$(tr -d '[:space:]' < "$DEST/.qsrise")"
[ -n "$ver" ] || ver="V1"

# No repo ⇒ an update is impossible ⇒ clear any stale badge. (Unlike the offline
# case below, where keeping the last known state is correct.)
if [ ! -d "$REPO/.git" ]; then clear_state; exit 0; fi
cd "$REPO"

# Offline-tolerant: a failed fetch must NOT touch the existing state.
git fetch --quiet origin 2>/dev/null || exit 0

# No upstream ⇒ nothing to compare ⇒ clear stale badge.
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" \
  || { clear_state; exit 0; }

# Commits the upstream is ahead by that change THIS version's directory.
behind="$(git rev-list --count "HEAD..$upstream" -- "versions/$ver/" 2>/dev/null || echo 0)"
if [ "${behind:-0}" -eq 0 ]; then
  clear_state
  exit 0
fi

# Short changelog. `git log --max-count` (no `head` in the pipe) — so a large
# commit count can't SIGPIPE git and trip pipefail before the state is written.
summary="$(git log --max-count=8 --format='%s' "HEAD..$upstream" -- "versions/$ver/" | jq -R . | jq -s .)"

write_state "$(jq -nc \
  --argjson behind  "$behind" \
  --arg     version "$ver" \
  --argjson summary "$summary" \
  --arg     checked "$(date -Is)" \
  '{behind: $behind, version: $version, summary: $summary, checked: $checked}')"
