#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${CHECK:-$REPO_ROOT/scripts/qs-arch-update-check.sh}"
GATE="${GATE:-$REPO_ROOT/scripts/qs-arch-security-gate.sh}"
APPLY="${APPLY:-$REPO_ROOT/scripts/qs-arch-apply-update.sh}"
WORK="$(mktemp -d /tmp/qs-arch-update-test.XXXXXX)"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_exists() {
  [ -e "$1" ] || fail "$2"
}

assert_file_absent() {
  [ ! -e "$1" ] || fail "$2"
}

assert_contains() {
  grep -Fq -- "$1" "$2" || fail "$3"
}

init_fixture() {
  local root="$1"
  mkdir -p "$root/bin" "$root/home" "$root/state"
  cat > "$root/bin/checkupdates" <<'SCRIPT'
#!/usr/bin/env bash
cat "$FAKE_CHECKUPDATES_FILE"
exit "${FAKE_CHECKUPDATES_RC:-0}"
SCRIPT
  cat > "$root/bin/sudo" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SUDO_LOG"
if [ "${1:-}" = "-v" ]; then
  if [ "${FAKE_SUDO_DELAY:-0}" != "0" ]; then
    sleep "$FAKE_SUDO_DELAY"
  fi
  exit "${FAKE_SUDO_VALIDATE_RC:-0}"
fi
if [ "${1:-}" = "pacman" ]; then
  shift
  exec pacman "$@"
fi
exit 127
SCRIPT
  cat > "$root/bin/pacman" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_PACMAN_LOG"
if [ "$*" = "-Syu" ]; then
  printf 'PACMAN-SYU\n' > "$FAKE_PACMAN_MARKER"
  exit 0
fi
exit 64
SCRIPT
  cat > "$root/bin/paru" <<'SCRIPT'
#!/usr/bin/env bash
if [ "${1:-}" = "-Qum" ]; then
  cat "${FAKE_AUR_FILE:-/dev/null}"
  exit 0
fi
exit 64
SCRIPT
  chmod +x "$root/bin/checkupdates" "$root/bin/sudo" "$root/bin/pacman" "$root/bin/paru"
  : > "$root/sudo.log"
  : > "$root/pacman.log"
  : > "$root/aur.out"
}

env_common() {
  local root="$1"
  shift
  PATH="$root/bin:$PATH" \
  HOME="$root/home" \
  XDG_STATE_HOME="$root/state" \
  QS_GATE_MIN=0 \
  QS_ARCH_CHECK_HELPER="$CHECK" \
  QS_ARCH_GATE_HELPER="$GATE" \
  QS_ARCH_SCAN_MAX_AGE="${QS_ARCH_SCAN_MAX_AGE:-900}" \
  FAKE_SUDO_LOG="$root/sudo.log" \
  FAKE_PACMAN_LOG="$root/pacman.log" \
  FAKE_PACMAN_MARKER="$root/pacman.marker" \
  FAKE_CHECKUPDATES_FILE="$root/checkupdates.out" \
  FAKE_AUR_FILE="$root/aur.out" \
  FAKE_SUDO_DELAY="${FAKE_SUDO_DELAY:-0}" \
  "$@"
}

run_check() {
  local root="$1"
  env_common "$root" "$CHECK" > "$root/check.out"
}

run_gate_from_check() {
  local root="$1"
  awk -F '|' 'NF >= 4 && ($1 == "S" || $1 == "A") { repo = ($1 == "A" ? "aur" : "system"); print $2 "|" repo "|" $3 "|" $4 }' "$root/check.out" \
    | env_common "$root" "$GATE" > "$root/gate.out"
}

run_apply() {
  local root="$1"
  shift
  env_common "$root" "$APPLY" "$@"
}

scan_args() {
  local root="$1"
  jq -r '.scanId, .systemHash, (.systemCount | tostring), (.checkedEpoch | tostring)' \
    "$root/home/.cache/qs-arch-updates.json"
}

run_apply_checked() {
  local root="$1"
  mapfile -t args < <(scan_args "$root")
  run_apply "$root" "${args[@]}"
}

prepare_checked_gate() {
  local root="$1" payload="$2"
  printf '%s\n' "$payload" > "$root/checkupdates.out"
  run_check "$root"
  run_gate_from_check "$root"
  jq -e '.schemaVersion == 1 and (.scanId | length > 0) and .systemCount > 0 and (.systemHash | length > 0)' \
    "$root/home/.cache/qs-arch-updates.json" >/dev/null
  jq -e '.schemaVersion == 1 and .degraded == false and .fail == 0 and .ok >= .systemCount' \
    "$root/home/.cache/qs-arch-gate.json" >/dev/null
}

test_success_runs_exact_full_upgrade() {
  local root="$WORK/success"
  init_fixture "$root"
  prepare_checked_gate "$root" $'linux 1.0 -> 1.1\nglibc 2.0 -> 2.1'

  printf 'linux 1.0 -> 1.1\nglibc 2.0 -> 2.1\n' > "$root/checkupdates.out"
  run_apply_checked "$root" >/dev/null

  assert_file_exists "$root/pacman.marker" "pacman -Syu was not executed"
  assert_contains "-v" "$root/sudo.log" "sudo -v was not called"
  assert_contains "pacman -Syu" "$root/sudo.log" "sudo pacman -Syu was not called"
  assert_contains "-Syu" "$root/pacman.log" "pacman did not receive exact -Syu"
}

test_aur_warnings_do_not_block_full_repo_upgrade() {
  local root="$WORK/aur-warn"
  init_fixture "$root"
  printf 'aurtool 1.0 -> 1.1\n' > "$root/aur.out"
  prepare_checked_gate "$root" $'linux 1.0 -> 1.1'

  jq -e '.aurCount == 1 and .systemCount == 1' "$root/home/.cache/qs-arch-updates.json" >/dev/null
  jq -e '.warn == 1 and .ok == 1 and .fail == 0 and .degraded == false' "$root/home/.cache/qs-arch-gate.json" >/dev/null

  printf 'linux 1.0 -> 1.1\n' > "$root/checkupdates.out"
  run_apply_checked "$root" >/dev/null

  assert_file_exists "$root/pacman.marker" "pacman -Syu was blocked by AUR warnings"
  assert_contains "pacman -Syu" "$root/sudo.log" "sudo pacman -Syu was not called with AUR warnings"
  assert_contains "-Syu" "$root/pacman.log" "pacman did not receive exact -Syu with AUR warnings"
}

test_rescan_drift_aborts_before_pacman() {
  local root="$WORK/drift"
  init_fixture "$root"
  prepare_checked_gate "$root" $'linux 1.0 -> 1.1\nglibc 2.0 -> 2.1'

  printf 'linux 1.0 -> 1.2\nglibc 2.0 -> 2.1\n' > "$root/checkupdates.out"
  if run_apply_checked "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded despite package drift"
  fi
  assert_file_absent "$root/pacman.marker" "pacman ran despite package drift"
  assert_contains "-v" "$root/sudo.log" "sudo -v should happen before the fresh rescan"
}

test_stale_scan_aborts_before_sudo() {
  local root="$WORK/stale"
  init_fixture "$root"
  prepare_checked_gate "$root" $'linux 1.0 -> 1.1'
  local stale
  stale="$(( $(date +%s) - 99999 ))"
  local tmp
  tmp="$(mktemp)"
  jq --argjson stale "$stale" '.checkedEpoch = $stale' "$root/home/.cache/qs-arch-updates.json" > "$tmp"
  mv "$tmp" "$root/home/.cache/qs-arch-updates.json"

  if run_apply_checked "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded with stale scan"
  fi
  assert_file_absent "$root/pacman.marker" "pacman ran despite stale scan"
  [ ! -s "$root/sudo.log" ] || fail "sudo ran despite stale scan"
}

test_gate_mismatch_aborts_before_sudo() {
  local root="$WORK/gate-mismatch"
  init_fixture "$root"
  prepare_checked_gate "$root" $'linux 1.0 -> 1.1'
  local tmp
  tmp="$(mktemp)"
  jq '.systemHash = "not-the-scan-hash"' "$root/home/.cache/qs-arch-gate.json" > "$tmp"
  mv "$tmp" "$root/home/.cache/qs-arch-gate.json"

  if run_apply_checked "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded with mismatched gate state"
  fi
  assert_file_absent "$root/pacman.marker" "pacman ran despite gate mismatch"
  [ ! -s "$root/sudo.log" ] || fail "sudo ran despite gate mismatch"
}

test_degraded_gate_aborts_before_sudo() {
  local root="$WORK/gate-degraded"
  init_fixture "$root"
  prepare_checked_gate "$root" $'linux 1.0 -> 1.1'
  local tmp
  tmp="$(mktemp)"
  jq '.degraded = true' "$root/home/.cache/qs-arch-gate.json" > "$tmp"
  mv "$tmp" "$root/home/.cache/qs-arch-gate.json"

  if run_apply_checked "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded with degraded gate"
  fi
  assert_file_absent "$root/pacman.marker" "pacman ran despite degraded gate"
  [ ! -s "$root/sudo.log" ] || fail "sudo ran despite degraded gate"
}

test_missing_checkupdates_fails_closed() {
  local root="$WORK/missing-checkupdates"
  init_fixture "$root"
  prepare_checked_gate "$root" $'linux 1.0 -> 1.1'
  rm -f "$root/bin/checkupdates"

  if run_apply_checked "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded without checkupdates"
  fi
  assert_file_absent "$root/pacman.marker" "pacman ran without checkupdates"
  assert_contains "-v" "$root/sudo.log" "sudo -v should happen before the fresh rescan"
}

test_check_without_checkupdates_fails() {
  local root="$WORK/check-missing"
  init_fixture "$root"
  rm -f "$root/bin/checkupdates"
  printf 'linux 1.0 -> 1.1\n' > "$root/checkupdates.out"

  if run_check "$root" >"$root/check.stdout" 2>"$root/check.stderr"; then
    fail "check succeeded without checkupdates"
  fi
  [ ! -e "$root/home/.cache/qs-arch-updates.json" ] || fail "check wrote state without checkupdates"
}

test_state_replaced_after_click_aborts_before_sudo() {
  local root="$WORK/state-replaced"
  init_fixture "$root"
  prepare_checked_gate "$root" $'linux 1.0 -> 1.1'
  mapfile -t clicked_args < <(scan_args "$root")

  printf 'linux 1.0 -> 1.2\n' > "$root/checkupdates.out"
  run_check "$root"

  if run_apply "$root" "${clicked_args[@]}" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded after checked state was replaced"
  fi
  assert_file_absent "$root/pacman.marker" "pacman ran after checked state replacement"
  [ ! -s "$root/sudo.log" ] || fail "sudo ran after checked state replacement"
}

test_gate_changed_after_review_aborts_before_pacman() {
  local root="$WORK/gate-changed"
  init_fixture "$root"
  prepare_checked_gate "$root" $'linux 1.0 -> 1.1'
  mkdir -p "$root/home/.local/share"
  printf 'linux\n' > "$root/home/.local/share/qs-aur-blacklist.txt"

  printf 'linux 1.0 -> 1.1\n' > "$root/checkupdates.out"
  if run_apply_checked "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded after gate source changed"
  fi
  assert_file_absent "$root/pacman.marker" "pacman ran after gate source changed"
  assert_contains "-v" "$root/sudo.log" "sudo -v should happen before the final gate rescan"
}

test_scan_stales_during_sudo_aborts_before_pacman() {
  local root="$WORK/stale-during-sudo"
  init_fixture "$root"
  QS_ARCH_SCAN_MAX_AGE=1 prepare_checked_gate "$root" $'linux 1.0 -> 1.1'

  printf 'linux 1.0 -> 1.1\n' > "$root/checkupdates.out"
  if QS_ARCH_SCAN_MAX_AGE=1 FAKE_SUDO_DELAY=2 run_apply_checked "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded after scan became stale during sudo authentication"
  fi
  assert_file_absent "$root/pacman.marker" "pacman ran after scan became stale during sudo authentication"
  assert_contains "-v" "$root/sudo.log" "sudo -v was not reached in stale-during-sudo test"
}

test_malformed_checkupdates_line_fails_check() {
  local root="$WORK/malformed-check"
  init_fixture "$root"
  printf 'linux 1.0 -> 1.1\nthis is not valid checkupdates output\n' > "$root/checkupdates.out"

  if run_check "$root" >"$root/check.stdout" 2>"$root/check.stderr"; then
    fail "check succeeded with malformed checkupdates output"
  fi
  [ ! -e "$root/home/.cache/qs-arch-updates.json" ] || fail "check wrote state from malformed checkupdates output"
}

test_invalid_checkupdates_package_name_fails_check() {
  local root="$WORK/invalid-package-name"
  init_fixture "$root"
  printf '%s\n' "bad\$name 1.0 -> 1.1" > "$root/checkupdates.out"

  if run_check "$root" >"$root/check.stdout" 2>"$root/check.stderr"; then
    fail "check succeeded with invalid checkupdates package name"
  fi
  [ ! -e "$root/home/.cache/qs-arch-updates.json" ] || fail "check wrote state from invalid package name"
}

test_malformed_rescan_aborts_before_pacman() {
  local root="$WORK/malformed-rescan"
  init_fixture "$root"
  prepare_checked_gate "$root" $'linux 1.0 -> 1.1'

  printf 'linux 1.0 -> 1.1\nthis is not valid checkupdates output\n' > "$root/checkupdates.out"
  if run_apply_checked "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded with malformed fresh checkupdates output"
  fi
  assert_file_absent "$root/pacman.marker" "pacman ran after malformed fresh checkupdates output"
  assert_contains "-v" "$root/sudo.log" "sudo -v should happen before fresh malformed rescan"
}

test_checkupdates_bad_exit_fails_even_without_stderr() {
  local root="$WORK/check-bad-exit"
  init_fixture "$root"
  printf 'linux 1.0 -> 1.1\n' > "$root/checkupdates.out"

  if FAKE_CHECKUPDATES_RC=1 run_check "$root" >"$root/check.stdout" 2>"$root/check.stderr"; then
    fail "check succeeded with non-accepted checkupdates exit code"
  fi
  [ ! -e "$root/home/.cache/qs-arch-updates.json" ] || fail "check wrote state after bad checkupdates exit code"
}

test_success_runs_exact_full_upgrade
test_aur_warnings_do_not_block_full_repo_upgrade
test_rescan_drift_aborts_before_pacman
test_stale_scan_aborts_before_sudo
test_gate_mismatch_aborts_before_sudo
test_degraded_gate_aborts_before_sudo
test_missing_checkupdates_fails_closed
test_check_without_checkupdates_fails
test_state_replaced_after_click_aborts_before_sudo
test_gate_changed_after_review_aborts_before_pacman
test_scan_stales_during_sudo_aborts_before_pacman
test_malformed_checkupdates_line_fails_check
test_invalid_checkupdates_package_name_fails_check
test_malformed_rescan_aborts_before_pacman
test_checkupdates_bad_exit_fails_even_without_stderr

printf 'qs-arch-update regression tests passed\n'
