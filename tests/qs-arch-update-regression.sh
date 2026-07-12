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
  PATH="$root/bin:${QS_TEST_BASE_PATH:-$PATH}" \
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

restricted_tool_path() {
  local root="$1" name src
  mkdir -p "$root/system-bin"
  for name in bash cat dirname mkdir mktemp rm timeout awk sort sha256sum wc tr date od mv jq; do
    src="$(command -v "$name")"
    ln -sf "$src" "$root/system-bin/$name"
  done
  printf '%s\n' "$root/system-bin"
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
  jq -e '.schemaVersion == 1 and .systemScanAvailable == true and .reason == "" and (.scanId | length > 0) and .systemCount > 0 and (.systemHash | length > 0)' \
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
  local restricted
  restricted="$(restricted_tool_path "$root")"

  if QS_TEST_BASE_PATH="$restricted" run_apply_checked "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded without checkupdates"
  fi
  assert_file_absent "$root/pacman.marker" "pacman ran without checkupdates"
  [ ! -s "$root/sudo.log" ] || fail "sudo ran without checkupdates"
  assert_contains "pacman-contrib is required" "$root/apply.err" "missing dependency error was not actionable"
}

test_check_without_checkupdates_writes_capability_and_keeps_aur() {
  local root="$WORK/check-missing"
  init_fixture "$root"
  rm -f "$root/bin/checkupdates"
  printf 'aurtool 1.0 -> 1.1\n' > "$root/aur.out"
  local restricted
  restricted="$(restricted_tool_path "$root")"

  QS_TEST_BASE_PATH="$restricted" run_check "$root"

  jq -e '
    .schemaVersion == 1
    and .systemScanAvailable == false
    and .reason == "missing-checkupdates"
    and .scanId == ""
    and .systemHash == ""
    and .systemCount == 0
    and .aurCount == 1
    and (.checked | length > 0)
    and .checkedEpoch > 0
    and (.systemPackages | length) == 0
    and (.aurPackages | length) == 1
  ' "$root/home/.cache/qs-arch-updates.json" >/dev/null
  [ "$(date -d "$(jq -r '.checked' "$root/home/.cache/qs-arch-updates.json")" +%s)" \
      = "$(jq -r '.checkedEpoch' "$root/home/.cache/qs-arch-updates.json")" ] \
    || fail "unavailable scan timestamps do not describe the same instant"
  if compgen -G "$root/home/.cache/.qs-arch-updates.*" >/dev/null; then
    fail "atomic state write left a temporary file behind"
  fi
  assert_contains "C|0|missing-checkupdates" "$root/check.out" "missing capability stream record"
  assert_contains "A|aurtool|1.0|1.1" "$root/check.out" "AUR update was lost without checkupdates"
  if grep -q '^M|' "$root/check.out"; then
    fail "unavailable system scan emitted trusted scan metadata"
  fi

  run_gate_from_check "$root"
  jq -e '.warn == 1 and .fail == 0 and .degraded == true' \
    "$root/home/.cache/qs-arch-gate.json" >/dev/null
}

test_dependency_install_transition_needs_no_reinstall() {
  local root="$WORK/check-transition"
  init_fixture "$root"
  rm -f "$root/bin/checkupdates"
  local restricted
  restricted="$(restricted_tool_path "$root")"

  QS_TEST_BASE_PATH="$restricted" run_check "$root"
  jq -e '.systemScanAvailable == false and .reason == "missing-checkupdates"' \
    "$root/home/.cache/qs-arch-updates.json" >/dev/null

  cat > "$root/bin/checkupdates" <<'SCRIPT'
#!/usr/bin/env bash
cat "$FAKE_CHECKUPDATES_FILE"
exit 0
SCRIPT
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/fakeroot"
  chmod +x "$root/bin/checkupdates" "$root/bin/fakeroot"
  printf 'linux 1.0 -> 1.1\n' > "$root/checkupdates.out"
  QS_TEST_BASE_PATH="$restricted" run_check "$root"

  jq -e '.systemScanAvailable == true and .reason == "" and .systemCount == 1 and (.scanId | length > 0) and (.systemHash | length > 0)' \
    "$root/home/.cache/qs-arch-updates.json" >/dev/null
  assert_contains "C|1|" "$root/check.out" "available capability stream record missing after dependency install"
}

test_old_state_without_capability_fails_before_sudo() {
  local root="$WORK/old-state"
  init_fixture "$root"
  prepare_checked_gate "$root" $'linux 1.0 -> 1.1'
  local tmp
  tmp="$(mktemp)"
  jq 'del(.systemScanAvailable, .reason)' "$root/home/.cache/qs-arch-updates.json" > "$tmp"
  mv "$tmp" "$root/home/.cache/qs-arch-updates.json"

  if run_apply_checked "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply accepted old state without capability"
  fi
  assert_file_absent "$root/pacman.marker" "pacman ran from old state without capability"
  [ ! -s "$root/sudo.log" ] || fail "sudo ran from old state without capability"
}

test_missing_fakeroot_is_unavailable_and_apply_fails_before_sudo() {
  local root="$WORK/missing-fakeroot"
  init_fixture "$root"
  prepare_checked_gate "$root" $'linux 1.0 -> 1.1'
  local restricted
  restricted="$(restricted_tool_path "$root")"

  QS_TEST_BASE_PATH="$restricted" run_check "$root"
  jq -e '.systemScanAvailable == false and .reason == "missing-fakeroot" and .scanId == "" and .systemHash == ""' \
    "$root/home/.cache/qs-arch-updates.json" >/dev/null
  assert_contains "C|0|missing-fakeroot" "$root/check.out" "missing fakeroot capability record was not emitted"

  # Restore a previously valid reviewed state, then prove the apply helper still
  # checks the runtime capability before sudo.
  QS_TEST_BASE_PATH="$PATH" prepare_checked_gate "$root" $'linux 1.0 -> 1.1'
  if QS_TEST_BASE_PATH="$restricted" run_apply_checked "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded without fakeroot"
  fi
  assert_file_absent "$root/pacman.marker" "pacman ran without fakeroot"
  [ ! -s "$root/sudo.log" ] || fail "sudo ran without fakeroot"
  assert_contains "fakeroot is required" "$root/apply.err" "missing fakeroot error was not actionable"
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

test_blacklist_fetch_service_has_bounded_retries() {
  local service="$REPO_ROOT/systemd/qs-aur-blacklist-fetch.service"
  assert_contains "StartLimitIntervalSec=1h" "$service" "blacklist fetch service missing retry interval limit"
  assert_contains "StartLimitBurst=4" "$service" "blacklist fetch service missing retry burst limit"
  assert_contains "Restart=on-failure" "$service" "blacklist fetch service missing failure retry policy"
  assert_contains "RestartSec=15min" "$service" "blacklist fetch service missing retry delay"
}

test_arch_panel_refresh_updates_freshness_clock() {
  local panel="$REPO_ROOT/versions/V1/panels/ArchUpdaterPanel.qml"
  assert_contains "function onArchScanCheckedEpochChanged()" "$panel" "arch panel does not refresh its freshness clock after package scan"
  assert_contains "archPanel.nowEpoch = Math.floor(Date.now() / 1000)" "$panel" "arch panel freshness clock update is missing"
}

test_qml_exposes_missing_dependency_without_unsafe_fallback() {
  local widget="$REPO_ROOT/versions/V1/modules/ArchUpdaterWidget.qml"
  local panel="$REPO_ROOT/versions/V1/panels/ArchUpdaterPanel.qml"
  assert_contains 'parts[0] === "C"' "$widget" "Arch updater widget does not parse capability records"
  assert_contains 'root.archSystemScanAvailable = sawCapability && systemScanAvailable' "$widget" "Arch updater widget does not fail closed without a capability record"
  assert_contains 'Install pacman-contrib and fakeroot for safe repository checks' "$panel" "Packages tab lacks the missing dependency explanation"
  assert_contains 'sudo pacman -S --needed pacman-contrib fakeroot' "$panel" "Packages tab dependency command is missing or unsafe"
  if grep -Eq '^[[:space:]]*(LC_ALL=[^ ]+[[:space:]]+)?pacman[[:space:]]+-Qu' "$REPO_ROOT/scripts/qs-arch-update-check.sh"; then
    fail "Arch update check regained the unsafe pacman -Qu fallback"
  fi
}

test_success_runs_exact_full_upgrade
test_aur_warnings_do_not_block_full_repo_upgrade
test_rescan_drift_aborts_before_pacman
test_stale_scan_aborts_before_sudo
test_gate_mismatch_aborts_before_sudo
test_degraded_gate_aborts_before_sudo
test_missing_checkupdates_fails_closed
test_check_without_checkupdates_writes_capability_and_keeps_aur
test_dependency_install_transition_needs_no_reinstall
test_old_state_without_capability_fails_before_sudo
test_missing_fakeroot_is_unavailable_and_apply_fails_before_sudo
test_state_replaced_after_click_aborts_before_sudo
test_gate_changed_after_review_aborts_before_pacman
test_scan_stales_during_sudo_aborts_before_pacman
test_malformed_checkupdates_line_fails_check
test_invalid_checkupdates_package_name_fails_check
test_malformed_rescan_aborts_before_pacman
test_checkupdates_bad_exit_fails_even_without_stderr
test_blacklist_fetch_service_has_bounded_retries
test_arch_panel_refresh_updates_freshness_clock
test_qml_exposes_missing_dependency_without_unsafe_fallback

printf 'qs-arch-update regression tests passed\n'
