#!/usr/bin/env bash
# Checked package scan for the Quickshell Arch updater.
#
# Writes an immutable-ish scan state for the official repo package set and emits
# the legacy QML stream:
#   S|pkg|old|new
#   A|pkg|old|new
#
# The official repo scan is intentionally checkupdates-only. pacman -Qu is not a
# fresh repository view and must not seed a later privileged pacman -Syu gate.
set -euo pipefail

STATE="${QS_ARCH_UPDATE_STATE:-$HOME/.cache/qs-arch-updates.json}"
SCHEMA_VERSION=1

fail() {
  printf 'qs-arch-update-check: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
command -v checkupdates >/dev/null 2>&1 || fail "checkupdates is required"

state_dir="$(dirname "$STATE")"
mkdir -p "$state_dir"
tmpdir="$(mktemp -d -p "${TMPDIR:-/tmp}" qs-arch-check.XXXXXX)" || fail "could not create temp dir"
trap 'rm -rf "$tmpdir"' EXIT

system_raw="$tmpdir/system.raw"
system_err="$tmpdir/system.err"
system_tsv="$tmpdir/system.tsv"
system_canon="$tmpdir/system.canon"
system_sorted="$tmpdir/system.sorted"
aur_raw="$tmpdir/aur.raw"
aur_tsv="$tmpdir/aur.tsv"
: > "$system_tsv"
: > "$aur_tsv"

rc=0
LC_ALL=C checkupdates >"$system_raw" 2>"$system_err" || rc=$?
case "$rc" in
  0|2) ;;
  *) fail "checkupdates failed" ;;
esac

while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  read -r name old arrow new rest <<< "$line"
  [ -n "${name:-}" ] && [ -n "${old:-}" ] && [ -n "${arrow:-}" ] && [ -n "${new:-}" ] && [ -z "${rest:-}" ] \
    || fail "malformed checkupdates output"
  [ "$arrow" = "->" ] || fail "malformed checkupdates output"
  case "$name" in *[!a-zA-Z0-9@._+-]*) fail "malformed checkupdates output" ;; esac
  printf '%s\t%s\t%s\n' "$name" "$old" "$new" >> "$system_tsv"
done < "$system_raw"

if [ "${QS_ARCH_SKIP_AUR:-0}" != "1" ]; then
  if command -v paru >/dev/null 2>&1; then
    timeout 30 paru -Qum >"$aur_raw" 2>/dev/null || true
  elif command -v yay >/dev/null 2>&1; then
    timeout 30 yay -Qum >"$aur_raw" 2>/dev/null || true
  else
    : > "$aur_raw"
  fi
  while read -r name old arrow new rest || [ -n "${name:-}" ]; do
    [ -n "${name:-}" ] || continue
    [ "$arrow" = "->" ] || continue
    [ -n "${new:-}" ] || continue
    case "$name" in *[!a-zA-Z0-9@._+-]*) continue ;; esac
    printf '%s\t%s\t%s\n' "$name" "$old" "$new" >> "$aur_tsv"
  done < "$aur_raw"
fi

awk -F '\t' '{print $1 "|" $2 "|" $3}' "$system_tsv" > "$system_canon"
LC_ALL=C sort "$system_canon" > "$system_sorted"
system_hash="$(sha256sum "$system_sorted" | awk '{print $1}')"
system_count="$(wc -l < "$system_tsv" | tr -d ' ')"
aur_count="$(wc -l < "$aur_tsv" | tr -d ' ')"
checked_epoch="$(date +%s)"
checked_iso="$(date -Is)"
scan_id="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
[ -n "$scan_id" ] || scan_id="${checked_epoch}-$$"

system_json="$(jq -Rn '[inputs | select(length > 0) | split("\t") | {name:.[0], oldVer:.[1], newVer:.[2], source:"system"}]' < "$system_tsv")"
aur_json="$(jq -Rn '[inputs | select(length > 0) | split("\t") | {name:.[0], oldVer:.[1], newVer:.[2], source:"aur"}]' < "$aur_tsv")"

state_tmp="$(mktemp -p "$state_dir" .qs-arch-updates.XXXXXX)" || fail "could not create state temp"
jq -nc \
  --argjson schema "$SCHEMA_VERSION" \
  --arg scanId "$scan_id" \
  --arg checked "$checked_iso" \
  --argjson checkedEpoch "$checked_epoch" \
  --arg systemHash "$system_hash" \
  --argjson systemCount "$system_count" \
  --argjson aurCount "$aur_count" \
  --argjson systemPackages "$system_json" \
  --argjson aurPackages "$aur_json" \
  '{
    schemaVersion: $schema,
    scanId: $scanId,
    checked: $checked,
    checkedEpoch: $checkedEpoch,
    systemHash: $systemHash,
    systemCount: $systemCount,
    aurCount: $aurCount,
    systemPackages: $systemPackages,
    aurPackages: $aurPackages
  }' > "$state_tmp" || {
    rm -f "$state_tmp"
    fail "could not write state"
  }
mv -f "$state_tmp" "$STATE"

printf 'M|%s|%s|%s|%s\n' "$scan_id" "$checked_epoch" "$system_hash" "$system_count"
awk -F '\t' '{printf "S|%s|%s|%s\n", $1, $2, $3}' "$system_tsv"
awk -F '\t' '{printf "A|%s|%s|%s\n", $1, $2, $3}' "$aur_tsv"
