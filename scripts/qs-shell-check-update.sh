#!/usr/bin/env bash
# QS-Shell update check (writes a state file the bar watches; no apply here).
#
# Topology of THIS setup: the live bar dir is a *copy* of versions/<V>/ from the
# deploy clone at ~/.local/share/quickshell-dots by default (override with
# QS_SHELL_REPO). We never run git in the live dir — we compare the deploy
# repo's tracking branch against origin, scoped to the installed version.
#
# State contract: ~/.cache/qs-shell/update-available.json ALWAYS exists.
#   "up to date" = {"schemaVersion": 2, "behind": 0}.
#   Pending includes immutable provenance: repository, upstreamRef, baseCommit,
#   targetCommit, version, summary and checked.
# The bar's FileView only ever reads a complete file via atomic replace and never
# depends on delete-detection.
set -euo pipefail

REPO="${QS_SHELL_REPO:-$HOME/.local/share/quickshell-dots}"
DEST="${QS_SHELL_DEST:-$HOME/.config/quickshell/bar}"
STATE_DIR="$HOME/.cache/qs-shell"
STATE="$STATE_DIR/update-available.json"
SCHEMA_VERSION=2
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
clear_state() {
  write_state "$(jq -nc \
    --argjson schema "$SCHEMA_VERSION" \
    --arg c "$(date -Is)" \
    '{schemaVersion: $schema, behind: 0, checked: $c}')"
}

is_commit_hash() {
  [[ "$1" =~ ^[0-9a-f]{40}$ || "$1" =~ ^[0-9a-f]{64}$ ]]
}

# Installed version (.qsrise marker; this install predates it → fall back to V1).
ver="V1"
[ -f "$DEST/.qsrise" ] && ver="$(tr -d '[:space:]' < "$DEST/.qsrise")"
[ -n "$ver" ] || ver="V1"

# No repo ⇒ an update is impossible ⇒ clear any stale badge. (Unlike the offline
# case below, where keeping the last known state is correct.)
if [ ! -d "$REPO/.git" ]; then clear_state; exit 0; fi
cd "$REPO"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || { clear_state; exit 0; }
head_commit="$(git rev-parse 'HEAD^{commit}' 2>/dev/null)" || { clear_state; exit 0; }

# Prefer the commit marker written into the deployed bar. The deploy clone's
# working tree may intentionally remain behind a reviewed update; the marker is
# the source of truth for what the user is currently running.
base_commit="$head_commit"
if [ -f "$DEST/.qsrise-commit" ]; then
  deployed_commit="$(tr -d '[:space:]' < "$DEST/.qsrise-commit" 2>/dev/null || true)"
  if is_commit_hash "$deployed_commit" && git cat-file -e "$deployed_commit^{commit}" 2>/dev/null; then
    base_commit="$deployed_commit"
  fi
fi

# Offline-tolerant: a failed fetch must NOT touch the existing state.
git fetch --quiet origin 2>/dev/null || exit 0

# No upstream ⇒ nothing to compare ⇒ clear stale badge.
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" \
  || { clear_state; exit 0; }
target_commit="$(git rev-parse "$upstream^{commit}" 2>/dev/null)" || exit 0
is_commit_hash "$target_commit" || exit 0
git merge-base --is-ancestor "$base_commit" "$target_commit" 2>/dev/null || exit 0

# Commits the upstream is ahead by that change the deployable payload: THIS
# version's directory, or the companion pieces the post-update hook ships
# (helper scripts / systemd units). Docs-only commits stay badge-free.
payload=("versions/$ver/" "scripts/" "systemd/")
behind="$(git rev-list --count "$base_commit..$target_commit" -- "${payload[@]}" 2>/dev/null || echo 0)"
if [ "${behind:-0}" -eq 0 ]; then
  clear_state
  exit 0
fi

# Short changelog. `git log --max-count` (no `head` in the pipe) — so a large
# commit count can't SIGPIPE git and trip pipefail before the state is written.
summary="$(git log --max-count=8 --format='%s' "$base_commit..$target_commit" -- "${payload[@]}" | jq -R . | jq -s .)"

write_state "$(jq -nc \
  --argjson schema  "$SCHEMA_VERSION" \
  --argjson behind  "$behind" \
  --arg     repository "$repo_root" \
  --arg     upstreamRef "$upstream" \
  --arg     baseCommit "$base_commit" \
  --arg     targetCommit "$target_commit" \
  --arg     version "$ver" \
  --argjson summary "$summary" \
  --arg     checked "$(date -Is)" \
  '{schemaVersion: $schema, behind: $behind, repository: $repository,
    upstreamRef: $upstreamRef, baseCommit: $baseCommit, targetCommit: $targetCommit,
    version: $version, summary: $summary, checked: $checked}')"
