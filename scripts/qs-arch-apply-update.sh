#!/usr/bin/env bash
# Privileged apply gate for the Quickshell Arch updater.
#
# Refuses to run pacman unless the displayed scan, persisted gate verdict and a
# fresh post-auth checkupdates scan all describe the same official repo package
# set. No package names are passed to pacman; the only success path is the full
# repository transaction: sudo pacman -Syu.
set -euo pipefail

STATE="${QS_ARCH_UPDATE_STATE:-$HOME/.cache/qs-arch-updates.json}"
GATE_STATE="${QS_ARCH_GATE_STATE:-$HOME/.cache/qs-arch-gate.json}"
MAX_AGE="${QS_ARCH_SCAN_MAX_AGE:-900}"
CHECK_HELPER="${QS_ARCH_CHECK_HELPER:-}"
GATE_HELPER="${QS_ARCH_GATE_HELPER:-}"
if [ -z "$CHECK_HELPER" ]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -x "$script_dir/qs-arch-update-check.sh" ]; then
    CHECK_HELPER="$script_dir/qs-arch-update-check.sh"
  else
    CHECK_HELPER="$HOME/.local/bin/qs-arch-update-check.sh"
  fi
fi
if [ -z "$GATE_HELPER" ]; then
  script_dir="${script_dir:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  if [ -x "$script_dir/qs-arch-security-gate.sh" ]; then
    GATE_HELPER="$script_dir/qs-arch-security-gate.sh"
  else
    GATE_HELPER="$HOME/.local/bin/qs-arch-security-gate.sh"
  fi
fi

fail() {
  notify-send -a "QS-Shell" -u critical "Arch update blocked" "$1" 2>/dev/null || true
  printf 'qs-arch-apply-update: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sudo >/dev/null 2>&1 || fail "sudo is required"
[ -x "$CHECK_HELPER" ] || fail "arch update check helper is missing"
[ -x "$GATE_HELPER" ] || fail "arch security gate helper is missing"
[ -r "$STATE" ] || fail "no checked package scan is available"
[ -r "$GATE_STATE" ] || fail "no package gate verdict is available"

expected_scan_id="${1:-}"
expected_system_hash="${2:-}"
expected_system_count="${3:-}"
expected_checked_epoch="${4:-}"
[ -n "$expected_scan_id" ] || fail "expected scan id is missing"
case "$expected_system_hash" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) fail "expected package hash is malformed" ;;
esac
case "$expected_system_count" in ''|*[!0-9]*) fail "expected package count is malformed" ;; esac
case "$expected_checked_epoch" in ''|*[!0-9]*) fail "expected scan timestamp is malformed" ;; esac

state_tsv="$(jq -er '
  select(.schemaVersion == 1)
  | select((.scanId // "") != "")
  | select((.systemHash // "") != "")
  | [
      .scanId,
      .systemHash,
      (.systemCount | tostring),
      (.checkedEpoch | tostring)
    ] | @tsv
' "$STATE" 2>/dev/null)" || fail "checked package scan is malformed"
IFS=$'\t' read -r scan_id system_hash system_count checked_epoch <<< "$state_tsv"

case "$system_count" in ''|*[!0-9]*) fail "checked package count is malformed" ;; esac
case "$checked_epoch" in ''|*[!0-9]*) fail "checked scan timestamp is malformed" ;; esac
[ "$system_count" -gt 0 ] || fail "no official repo packages are queued"
[ "$scan_id" = "$expected_scan_id" ] || fail "checked scan changed; refresh first"
[ "$system_hash" = "$expected_system_hash" ] || fail "checked package set changed; refresh first"
[ "$system_count" = "$expected_system_count" ] || fail "checked package count changed; refresh first"
[ "$checked_epoch" = "$expected_checked_epoch" ] || fail "checked scan timestamp changed; refresh first"

check_age() {
  local epoch="$1" label="$2" now age
  now="$(date +%s)"
  age=$((now - epoch))
  [ "$age" -ge 0 ] || fail "$label timestamp is from the future"
  [ "$age" -le "$MAX_AGE" ] || fail "$label is stale; refresh first"
}

validate_initial_gate() {
  jq -e \
    --arg scanId "$1" \
    --arg systemHash "$2" \
    --argjson systemCount "$3" '
      .schemaVersion == 1
      and .scanId == $scanId
      and .systemHash == $systemHash
      and .systemCount == $systemCount
      and .degraded == false
      and (.fail // 0) == 0
      and (.ok // 0) == $systemCount
    ' "$4" >/dev/null 2>&1
}

validate_final_gate() {
  jq -e \
    --arg scanId "$1" \
    --arg systemHash "$2" \
    --argjson systemCount "$3" '
      .schemaVersion == 1
      and .scanId == $scanId
      and .systemHash == $systemHash
      and .systemCount == $systemCount
      and .inputCount == $systemCount
      and .degraded == false
      and (.ok // 0) == $systemCount
      and (.warn // 0) == 0
      and (.fail // 0) == 0
    ' "$4" >/dev/null 2>&1
}

check_age "$checked_epoch" "checked package scan"

validate_initial_gate "$scan_id" "$system_hash" "$system_count" "$GATE_STATE" \
  || fail "package gate verdict does not match the checked scan"

sudo -v || fail "sudo authentication failed"
check_age "$checked_epoch" "checked package scan"

tmpdir="$(mktemp -d -p "${TMPDIR:-/tmp}" qs-arch-apply.XXXXXX)" || fail "could not create temp dir"
trap 'rm -rf "$tmpdir"' EXIT
rescan_state="$tmpdir/rescan.json"
rescan_gate_state="$tmpdir/rescan-gate.json"

QS_ARCH_UPDATE_STATE="$rescan_state" QS_ARCH_SKIP_AUR=1 "$CHECK_HELPER" >"$tmpdir/rescan.out" \
  || fail "fresh checkupdates scan failed"

rescan_tsv="$(jq -er '[.scanId, .systemHash, (.systemCount | tostring), (.checkedEpoch | tostring)] | @tsv' "$rescan_state" 2>/dev/null)" \
  || fail "fresh checkupdates scan state is malformed"
IFS=$'\t' read -r rescan_scan_id rescan_hash rescan_count rescan_checked_epoch <<< "$rescan_tsv"

[ "$rescan_hash" = "$system_hash" ] || fail "official repo package set changed; refresh first"
[ "$rescan_count" = "$system_count" ] || fail "official repo package count changed; refresh first"
check_age "$rescan_checked_epoch" "fresh package scan"

awk -F '|' 'NF >= 4 && $1 == "S" { print $2 "|system|" $3 "|" $4 }' "$tmpdir/rescan.out" \
  | QS_ARCH_UPDATE_STATE="$rescan_state" QS_ARCH_GATE_STATE="$rescan_gate_state" "$GATE_HELPER" >"$tmpdir/rescan-gate.out" \
  || fail "fresh package gate failed"

validate_final_gate "$rescan_scan_id" "$rescan_hash" "$rescan_count" "$rescan_gate_state" \
  || fail "fresh package gate blocked the upgrade"

check_age "$rescan_checked_epoch" "fresh package scan"

sudo pacman -Syu
