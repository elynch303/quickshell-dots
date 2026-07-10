#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${CHECK:-$REPO_ROOT/scripts/qs-theme-update-check.sh}"
APPLY="${APPLY:-$REPO_ROOT/scripts/qs-theme-apply-update.sh}"
WORK="$(mktemp -d /tmp/qs-theme-update-test.XXXXXX)"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local want="$1" got="$2" msg="$3"
  [ "$want" = "$got" ] || fail "$msg: want '$want', got '$got'"
}

assert_contains() {
  local needle="$1" file="$2" msg="$3"
  grep -Fq "$needle" "$file" || fail "$msg: missing '$needle'"
}

init_fixture() {
  local root="$1" name="$2"
  local remote="$root/remote.git"
  local seed="$root/seed"
  local themes="$root/themes"
  mkdir -p "$themes"
  git init --bare "$remote" >/dev/null
  git init "$seed" >/dev/null
  git -C "$seed" config user.email test@example.invalid
  git -C "$seed" config user.name Test
  git -C "$seed" branch -M main
  printf 'base\n' > "$seed/base.txt"
  git -C "$seed" add base.txt
  git -C "$seed" commit -m initial >/dev/null
  git -C "$seed" remote add origin "$remote"
  git -C "$seed" push -u origin main >/dev/null 2>&1
  git --git-dir="$remote" symbolic-ref HEAD refs/heads/main
  git clone "$remote" "$themes/$name" >/dev/null 2>&1
}

run_check() {
  local root="$1" name="$2"
  printf '%s\n' "$name" > "$root/current-theme"
  QS_THEMES_DIR="$root/themes" \
  QS_THEME_STATE="$root/state.json" \
  QS_THEME_LOCK="$root/lock" \
  QS_CURRENT_FILE="$root/current-theme" \
  QS_THEME_TIMEOUT=3 \
  QS_THEME_FETCH_TIMEOUT=5 \
    "$CHECK"
}

run_apply() {
  local root="$1"
  shift
  QS_THEMES_DIR="$root/themes" \
  QS_THEME_STATE="$root/state.json" \
  QS_THEME_LOCK="$root/lock" \
  QS_THEME_FETCH_TIMEOUT=5 \
    "$APPLY" "$@"
}

forge_first_theme_clean() {
  local root="$1"
  jq '(.themes[0].state = "clean") | (.themes[0].reason = "") | (.themes[0].files = []) | (.localEdits = 0)' \
    "$root/state.json" > "$root/forged-state.json"
  mv "$root/forged-state.json" "$root/state.json"
}

test_clean_pinned_apply() {
  local root="$WORK/clean" name="demo"
  init_fixture "$root" "$name"
  printf 'v2\n' > "$root/seed/base.txt"
  git -C "$root/seed" commit -am update-v2 >/dev/null
  git -C "$root/seed" push origin main >/dev/null 2>&1

  run_check "$root" "$name"
  assert_eq clean "$(jq -r '.themes[0].state' "$root/state.json")" "clean fixture state"
  local target
  target="$(jq -r '.themes[0].targetCommit' "$root/state.json")"

  run_apply "$root" "$name" >/dev/null
  assert_eq "$target" "$(git -C "$root/themes/$name" rev-parse HEAD)" "apply installed saved target"
}

test_ignored_untracked_collision_blocks_check_and_apply() {
  local root="$WORK/ignored" name="demo"
  init_fixture "$root" "$name"
  printf 'local.tmp\n' > "$root/seed/.gitignore"
  git -C "$root/seed" add .gitignore
  git -C "$root/seed" commit -m ignore-local-tmp >/dev/null
  git -C "$root/seed" push origin main >/dev/null 2>&1
  git -C "$root/themes/$name" pull --ff-only >/dev/null 2>&1

  printf 'LOCAL-DATA\n' > "$root/themes/$name/local.tmp"
  printf 'UPSTREAM-DATA\n' > "$root/seed/local.tmp"
  git -C "$root/seed" add -f local.tmp
  git -C "$root/seed" commit -m track-ignored-file >/dev/null
  git -C "$root/seed" push origin main >/dev/null 2>&1

  run_check "$root" "$name"
  assert_eq local-edits "$(jq -r '.themes[0].state' "$root/state.json")" "ignored collision check state"
  assert_eq "untracked conflict" "$(jq -r '.themes[0].reason' "$root/state.json")" "ignored collision reason"

  forge_first_theme_clean "$root"

  if run_apply "$root" "$name" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded despite ignored untracked overwrite collision"
  fi
  assert_contains "untracked file would be overwritten" "$root/apply.err" "ignored collision apply error"
  assert_eq "LOCAL-DATA" "$(tr -d '\n' < "$root/themes/$name/local.tmp")" "ignored local file survived"
}

test_ignored_file_blocks_incoming_subpath() {
  local root="$WORK/prefix-file" name="demo"
  init_fixture "$root" "$name"
  printf 'cache\n' > "$root/seed/.gitignore"
  git -C "$root/seed" add .gitignore
  git -C "$root/seed" commit -m ignore-cache >/dev/null
  git -C "$root/seed" push origin main >/dev/null 2>&1
  git -C "$root/themes/$name" pull --ff-only >/dev/null 2>&1

  printf 'LOCAL-DATA\n' > "$root/themes/$name/cache"
  mkdir -p "$root/seed/cache"
  printf 'UPSTREAM-DATA\n' > "$root/seed/cache/data"
  git -C "$root/seed" add -f cache/data
  git -C "$root/seed" commit -m track-cache-subpath >/dev/null
  git -C "$root/seed" push origin main >/dev/null 2>&1

  run_check "$root" "$name"
  assert_eq local-edits "$(jq -r '.themes[0].state' "$root/state.json")" "ignored file vs incoming subpath check state"
  assert_eq "untracked conflict" "$(jq -r '.themes[0].reason' "$root/state.json")" "ignored file vs incoming subpath reason"

  forge_first_theme_clean "$root"
  if run_apply "$root" "$name" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded despite ignored file vs incoming subpath collision"
  fi
  assert_contains "untracked file would be overwritten" "$root/apply.err" "ignored file vs incoming subpath apply error"
  [ -f "$root/themes/$name/cache" ] || fail "ignored local file was replaced by directory"
  assert_eq "LOCAL-DATA" "$(tr -d '\n' < "$root/themes/$name/cache")" "ignored local file content survived"
}

test_ignored_subpath_blocks_incoming_file() {
  local root="$WORK/prefix-subpath" name="demo"
  init_fixture "$root" "$name"
  printf 'cache\n' > "$root/seed/.gitignore"
  git -C "$root/seed" add .gitignore
  git -C "$root/seed" commit -m ignore-cache >/dev/null
  git -C "$root/seed" push origin main >/dev/null 2>&1
  git -C "$root/themes/$name" pull --ff-only >/dev/null 2>&1

  mkdir -p "$root/themes/$name/cache"
  printf 'LOCAL-DATA\n' > "$root/themes/$name/cache/data"
  printf 'UPSTREAM-DATA\n' > "$root/seed/cache"
  git -C "$root/seed" add -f cache
  git -C "$root/seed" commit -m track-cache-file >/dev/null
  git -C "$root/seed" push origin main >/dev/null 2>&1

  run_check "$root" "$name"
  assert_eq local-edits "$(jq -r '.themes[0].state' "$root/state.json")" "ignored subpath vs incoming file check state"
  assert_eq "untracked conflict" "$(jq -r '.themes[0].reason' "$root/state.json")" "ignored subpath vs incoming file reason"

  forge_first_theme_clean "$root"
  if run_apply "$root" "$name" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded despite ignored subpath vs incoming file collision"
  fi
  assert_contains "untracked file would be overwritten" "$root/apply.err" "ignored subpath vs incoming file apply error"
  [ -f "$root/themes/$name/cache/data" ] || fail "ignored local subpath was replaced by file"
  assert_eq "LOCAL-DATA" "$(tr -d '\n' < "$root/themes/$name/cache/data")" "ignored local subpath content survived"
}

test_apply_aborts_when_check_lock_is_held() {
  local root="$WORK/locked" name="demo"
  init_fixture "$root" "$name"
  printf 'v2\n' > "$root/seed/base.txt"
  git -C "$root/seed" commit -am update-v2 >/dev/null
  git -C "$root/seed" push origin main >/dev/null 2>&1
  run_check "$root" "$name"

  exec 8>"$root/lock"
  flock -n 8 || fail "could not hold test lock"
  set +e
  run_apply "$root" "$name" >"$root/locked.out" 2>"$root/locked.err"
  local rc=$?
  set -e
  flock -u 8

  assert_eq 75 "$rc" "apply lock-abort exit code"
  assert_contains "state is busy" "$root/locked.err" "apply lock-abort message"
}

test_clean_pinned_apply
test_ignored_untracked_collision_blocks_check_and_apply
test_ignored_file_blocks_incoming_subpath
test_ignored_subpath_blocks_incoming_file
test_apply_aborts_when_check_lock_is_held

printf 'qs-theme-update regression tests passed\n'
