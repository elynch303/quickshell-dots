#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2218,SC2329
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/contrib/post-boot.d/quickshell-rise"
INSTALLER="$REPO_ROOT/install.sh"
UNINSTALLER="$REPO_ROOT/uninstall.sh"
README="$REPO_ROOT/README.md"
WORK="$(mktemp -d /tmp/qs-quattro-runtime-test.XXXXXX)"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -f $1 ]] || fail "$2: missing $1"
}

assert_no_file() {
  [[ ! -e $1 ]] || fail "$2: unexpected $1"
}

assert_contains() {
  local needle="$1" file="$2" message="$3"
  grep -Fq -- "$needle" "$file" || fail "$message: missing '$needle'"
}

assert_not_contains() {
  local needle="$1" file="$2" message="$3"
  [[ ! -f $file ]] || ! grep -Fq -- "$needle" "$file" || fail "$message: unexpected '$needle'"
}

assert_eq() {
  local want="$1" got="$2" message="$3"
  [[ $want == "$got" ]] || fail "$message: want '$want', got '$got'"
}

assert_before() {
  local first_pattern="$1" second_pattern="$2" file="$3" message="$4"
  local first_line second_line
  first_line="$(grep -n -m1 -- "$first_pattern" "$file" | cut -d: -f1)"
  second_line="$(grep -n -m1 -- "$second_pattern" "$file" | cut -d: -f1)"
  [[ -n $first_line && -n $second_line && $first_line -lt $second_line ]] || \
    fail "$message: '$first_pattern' ($first_line) must precede '$second_pattern' ($second_line)"
}

assert_shared_function_same() {
  local function_name="$1"

  diff -u \
    <(sed -n "/^${function_name}() {$/,/^}$/p" "$HOOK") \
    <(sed -n "/^${function_name}() {$/,/^}$/p" "$UNINSTALLER") \
    >/dev/null || fail "standalone uninstall helper drift: $function_name"
}

make_fake_tools() {
  local root="$1"
  mkdir -p "$root/bin"

  cat > "$root/bin/omarchy" <<'SCRIPT'
#!/usr/bin/env bash
set -u
printf 'omarchy %s\n' "$*" >> "${QSR_TEST_LOG:?}"
if [[ ${QSR_TEST_TOGGLE_FAIL:-0} == 1 && ${1:-} == toggle && ${2:-} == bar ]]; then
  exit 42
fi
if [[ ${1:-} == toggle && ${2:-} == bar ]]; then
  [[ ${QSR_TEST_TOGGLE_NOOP:-0} == 1 ]] && exit 0
  mkdir -p "${QSR_TOGGLE_ROOT:?}"
  case "${3:-}" in
    on)
      : > "$QSR_TOGGLE_ROOT/bar-off"
      if [[ ${QSR_TEST_TOGGLE_TIMEOUT_AFTER_WRITE:-0} == 1 ]]; then
        sleep "${QSR_TEST_TOGGLE_SLEEP:-2}"
      fi
      ;;
    off)
      [[ ${QSR_TEST_ROLLBACK_FAIL:-0} == 1 ]] && exit 43
      rm -f "$QSR_TOGGLE_ROOT/bar-off"
      ;;
    *)   exit 2 ;;
  esac
fi
SCRIPT

  cat > "$root/bin/omarchy-toggle-bar" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT

  cat > "$root/bin/omarchy-toggle-enabled" <<'SCRIPT'
#!/usr/bin/env bash
[[ ${1:-} == bar-off && -f ${QSR_TOGGLE_ROOT:?}/bar-off ]]
SCRIPT

  cat > "$root/bin/pkill" <<'SCRIPT'
#!/usr/bin/env bash
printf 'pkill %s\n' "$*" >> "${QSR_TEST_LOG:?}"
exit 1
SCRIPT

  cat > "$root/bin/setsid" <<'SCRIPT'
#!/usr/bin/env bash
printf 'setsid %s\n' "$*" >> "${QSR_TEST_LOG:?}"
exit 0
SCRIPT

  cat > "$root/bin/waybar" <<'SCRIPT'
#!/usr/bin/env bash
printf 'waybar %s\n' "$*" >> "${QSR_TEST_LOG:?}"
SCRIPT

  chmod 0755 "$root/bin/omarchy" "$root/bin/omarchy-toggle-bar" \
    "$root/bin/omarchy-toggle-enabled" "$root/bin/pkill" \
    "$root/bin/setsid" "$root/bin/waybar"
}

run_uninstaller() {
  local root="$1"
  HOME="$root/home" \
  XDG_RUNTIME_DIR="$root/run" \
  XDG_STATE_HOME="$root/state" \
  QSR_RUNTIME_ROOT="$root/run/quickshell" \
  QSR_PROC_ROOT="${QSR_PROC_ROOT:-/proc}" \
  QSR_TOGGLE_ROOT="$root/toggles" \
  QSR_TEST_LOG="$root/actions.log" \
  QSR_POLL_INTERVAL=0 \
  QSR_STOP_ROUNDS=3 \
  QSR_STABLE_ROUNDS=1 \
  QSR_COMMAND_TIMEOUT=1 \
  PATH="$root/bin:/usr/bin:/bin" \
    bash "$UNINSTALLER"
}

case_runtime_toggle_ownership() (
  local root="$WORK/runtime-toggle"
  mkdir -p "$root/home" "$root/run" "$root/state" "$root/toggles"
  : > "$root/actions.log"
  make_fake_tools "$root"

  export HOME="$root/home"
  export XDG_RUNTIME_DIR="$root/run"
  export XDG_STATE_HOME="$root/state"
  export QSR_RUNTIME_ROOT="$root/run/quickshell"
  export QSR_TOGGLE_ROOT="$root/toggles"
  export QSR_TEST_LOG="$root/actions.log"
  export QSR_POLL_INTERVAL=0
  export QSR_COMMAND_TIMEOUT=1
  export QSR_RUNTIME_LIB_ONLY=1
  export PATH="$root/bin:/usr/bin:/bin"
  # shellcheck source=/dev/null
  source "$HOOK"

  qsr_has_quattro || fail "runtime capability gate missed fake Quattro"
  qsr_hide_stock_bar_owned || fail "could not hide visible fake stock bar"
  assert_file "$QSR_BAR_MARKER" "visible stock bar ownership"
  assert_file "$QSR_TOGGLE_ROOT/bar-off" "hidden stock flag"
  qsr_hide_stock_bar_owned || fail "owned hide was not idempotent"
  assert_eq 1 "$(grep -c 'omarchy toggle bar on' "$QSR_TEST_LOG")" "hide toggle count"

  qsr_release_owned_stock_bar || fail "could not release owned stock bar"
  assert_no_file "$QSR_BAR_MARKER" "released ownership marker"
  assert_no_file "$QSR_TOGGLE_ROOT/bar-off" "visible stock flag"
  assert_contains "omarchy toggle bar off" "$QSR_TEST_LOG" "show direction"

  mkdir -p "$QSR_STATE_ROOT" "$QSR_TOGGLE_ROOT"
  : > "$QSR_BAR_PENDING"
  : > "$QSR_TOGGLE_ROOT/bar-off"
  qsr_hide_stock_bar_owned || fail "pending hide transaction was not recovered"
  assert_file "$QSR_BAR_MARKER" "pending transaction promotion"
  assert_no_file "$QSR_BAR_PENDING" "pending transaction cleanup"
  qsr_release_owned_stock_bar || fail "promoted transaction could not be released"

  : > "$QSR_TOGGLE_ROOT/bar-off"
  : > "$QSR_TEST_LOG"
  qsr_hide_stock_bar_owned || fail "pre-hidden stock bar should be accepted"
  assert_no_file "$QSR_BAR_MARKER" "foreign hidden state must not be claimed"
  assert_not_contains "omarchy toggle bar" "$QSR_TEST_LOG" "foreign hidden state mutation"

  rm -f "$QSR_TOGGLE_ROOT/bar-off"
  export QSR_TEST_TOGGLE_NOOP=1
  if qsr_hide_stock_bar_owned; then
    fail "no-op toggle was accepted without verified bar-off state"
  fi
  assert_no_file "$QSR_BAR_MARKER" "no-op toggle ownership"
  unset QSR_TEST_TOGGLE_NOOP

  # A timed-out command may already have written bar-off. The failed hide must
  # restore visibility before dropping its pending ownership record.
  : > "$QSR_TEST_LOG"
  export QSR_COMMAND_TIMEOUT=0.05
  export QSR_TEST_TOGGLE_TIMEOUT_AFTER_WRITE=1
  if qsr_hide_stock_bar_owned; then
    fail "timed-out hide was accepted"
  fi
  assert_no_file "$QSR_TOGGLE_ROOT/bar-off" "timeout-after-write rollback"
  assert_no_file "$QSR_BAR_MARKER" "timed-out hide ownership marker"
  assert_no_file "$QSR_BAR_PENDING" "timed-out hide pending marker"
  assert_contains "omarchy toggle bar on" "$QSR_TEST_LOG" "timed-out hide direction"
  assert_contains "omarchy toggle bar off" "$QSR_TEST_LOG" "timeout rollback direction"
  qsr_warn_stock_bar_hide_failure 2> "$root/visible-warning.log"
  assert_contains "it remains visible" "$root/visible-warning.log" "verified rollback warning"
  assert_not_contains "omarchy toggle bar off" "$root/visible-warning.log" "unnecessary recovery command"

  # If the compensating toggle also fails, ownership evidence must survive so
  # a later post-boot run or uninstall can recover the hidden stock bar.
  : > "$QSR_TEST_LOG"
  export QSR_TEST_ROLLBACK_FAIL=1
  if qsr_hide_stock_bar_owned; then
    fail "hide with failed rollback was accepted"
  fi
  assert_file "$QSR_TOGGLE_ROOT/bar-off" "failed rollback hidden state"
  assert_no_file "$QSR_BAR_MARKER" "failed rollback final marker"
  assert_file "$QSR_BAR_PENDING" "failed rollback recovery evidence"
  assert_contains "omarchy toggle bar off" "$QSR_TEST_LOG" "failed rollback direction"
  qsr_warn_stock_bar_hide_failure 2> "$root/hidden-warning.log"
  assert_contains "omarchy toggle bar off" "$root/hidden-warning.log" "failed rollback recovery command"
  unset QSR_TEST_ROLLBACK_FAIL
  unset QSR_TEST_TOGGLE_TIMEOUT_AFTER_WRITE
  qsr_release_owned_stock_bar || fail "could not clean up failed rollback fixture"
)

case_runtime_postboot_order_and_fail_open() (
  local root="$WORK/runtime-postboot"
  mkdir -p "$root/home" "$root/run" "$root/state" "$root/toggles"
  : > "$root/actions.log"
  make_fake_tools "$root"

  export HOME="$root/home"
  export XDG_RUNTIME_DIR="$root/run"
  export XDG_STATE_HOME="$root/state"
  export QSR_RUNTIME_ROOT="$root/run/quickshell"
  export QSR_TOGGLE_ROOT="$root/toggles"
  export QSR_TEST_LOG="$root/actions.log"
  export QSR_POLL_INTERVAL=0
  export QSR_COMMAND_TIMEOUT=1
  export QSR_RUNTIME_LIB_ONLY=1
  export PATH="$root/bin:/usr/bin:/bin"
  # shellcheck source=/dev/null
  source "$HOOK"

  qsr_start_bar() { printf 'start\n' >> "$QSR_TEST_LOG"; }
  qsr_wait_for_bar() { printf 'ready\n' >> "$QSR_TEST_LOG"; }
  qsr_hide_stock_bar_owned() { printf 'hide\n' >> "$QSR_TEST_LOG"; }
  qsr_post_boot_main
  assert_eq $'start\nready\nhide' "$(cat "$QSR_TEST_LOG")" "post-boot start/ready/hide order"

  # Reload pristine functions, then simulate a failed start with an owned flag.
  : > "$QSR_TEST_LOG"
  # shellcheck source=/dev/null
  source "$HOOK"
  qsr_live_bar_pids() { return 1; }
  if qsr_start_bar; then
    fail "registry read failure was treated as permission to start another bar"
  fi
  assert_not_contains "setsid" "$QSR_TEST_LOG" "start after registry failure"

  # Reload once more before simulating a failed real start with owned state.
  # shellcheck source=/dev/null
  source "$HOOK"
  mkdir -p "$QSR_STATE_ROOT" "$QSR_TOGGLE_ROOT"
  : > "$QSR_BAR_MARKER"
  : > "$QSR_TOGGLE_ROOT/bar-off"
  qsr_start_bar() { return 1; }
  qsr_post_boot_main 2>/dev/null
  assert_no_file "$QSR_BAR_MARKER" "failed start marker release"
  assert_no_file "$QSR_TOGGLE_ROOT/bar-off" "failed start stock restore"
)

case_registry_live_health_and_stop() (
  local root="$WORK/registry"
  local config="$root/home/.config/quickshell/bar/shell.qml"
  local runtime="$root/run/quickshell"
  local instance="$runtime/by-id/live-instance"
  local stale="$runtime/by-id/stale-instance"
  local path_id bar_pid live

  mkdir -p "$root/bin" "$(dirname "$config")" "$instance" "$stale" \
    "$runtime/by-path" "$runtime/by-pid"
  : > "$config"
  printf 'Configuration Loaded\n' > "$instance/log.log"
  : > "$instance/instance.lock"
  : > "$stale/instance.lock"

  # Deliberately make qs resolve to a different executable. The live process is
  # the bare quickshell candidate, exercising the crash-relaunch allowance.
  ln -s /usr/bin/sleep "$root/bin/qs"
  ln -s "$(command -v python3)" "$root/bin/quickshell"
  cat > "$root/bin/pkill" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
  chmod 0755 "$root/bin/pkill"

  path_id="$(printf '%s' "$config" | md5sum | awk '{print $1}')"
  mkdir -p "$runtime/by-path/$path_id"
  ln -s "$instance" "$runtime/by-path/$path_id/live"
  ln -s "$stale" "$runtime/by-path/$path_id/stale"

  "$root/bin/quickshell" -c 'import fcntl, sys, time; f = open(sys.argv[1], "w"); fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB); time.sleep(300)' \
    "$instance/instance.lock" &
  bar_pid=$!
  trap 'kill "$bar_pid" 2>/dev/null || true' EXIT
  ln -s "$instance" "$runtime/by-pid/$bar_pid"

  for _ in {1..50}; do
    lslocks -n -o PID,PATH | grep -Fq "$instance/instance.lock" && break
    sleep 0.02
  done

  export HOME="$root/home"
  export XDG_STATE_HOME="$root/state"
  export QSR_CONFIG_PATH="$config"
  export QSR_RUNTIME_ROOT="$runtime"
  export QSR_PROC_ROOT=/proc
  export QSR_READY_ROUNDS=2
  export QSR_STOP_ROUNDS=20
  export QSR_STABLE_ROUNDS=2
  export QSR_POLL_INTERVAL=0.02
  export QSR_COMMAND_TIMEOUT=1
  export QSR_RUNTIME_LIB_ONLY=1
  export PATH="$root/bin:/usr/bin:/bin"
  # shellcheck source=/dev/null
  source "$HOOK"

  live="$(qsr_live_bar_pids)" || fail "direct registry scan failed"
  assert_eq "$bar_pid" "$live" "live registry PID"

  rm -f "$runtime/by-pid/$bar_pid"
  assert_eq "" "$(qsr_live_bar_pids)" "missing by-pid cross-check"
  ln -s "$stale" "$runtime/by-pid/$bar_pid"
  assert_eq "" "$(qsr_live_bar_pids)" "wrong by-pid cross-check"
  rm -f "$runtime/by-pid/$bar_pid"
  ln -s "$instance" "$runtime/by-pid/$bar_pid"

  qsr_stop_registered_bars || fail "registered stop did not stabilize"
  wait "$bar_pid" 2>/dev/null || true
  if kill -0 "$bar_pid" 2>/dev/null; then
    fail "registered lock owner survived TERM/rescan"
  fi
)

prepare_owned_install() {
  local root="$1"
  mkdir -p "$root/home/.config/quickshell/bar" "$root/state/quickshell-rise" \
    "$root/toggles" "$root/run"
  : > "$root/home/.config/quickshell/bar/.qsrise"
  : > "$root/home/.config/quickshell/bar/shell.qml"
  : > "$root/state/quickshell-rise/owns-omarchy-bar-off"
  : > "$root/toggles/bar-off"
  : > "$root/actions.log"
}

case_uninstall_owned_backup_provider() {
  local root="$WORK/uninstall-owned"
  make_fake_tools "$root"
  prepare_owned_install "$root"
  mkdir -p "$root/home/.config/quickshell/bar.bak.20260719-120000"
  printf 'foreign backup\n' > "$root/home/.config/quickshell/bar.bak.20260719-120000/shell.qml"
  mkdir -p "$root/home/.config/omarchy/hooks/post-boot.d"
  : > "$root/home/.config/omarchy/hooks/post-boot.d/quickshell-rise"

  run_uninstaller "$root" >/dev/null
  assert_no_file "$root/state/quickshell-rise/owns-omarchy-bar-off" "uninstall marker release"
  assert_no_file "$root/toggles/bar-off" "uninstall stock visibility"
  assert_contains "foreign backup" "$root/home/.config/quickshell/bar/shell.qml" "backup restore"
  assert_contains "omarchy toggle bar off" "$root/actions.log" "uninstall show-before-stop"
  assert_not_contains "setsid quickshell" "$root/actions.log" "double-provider restore"
}

case_uninstall_foreign_hidden_state() {
  local root="$WORK/uninstall-foreign-state"
  make_fake_tools "$root"
  mkdir -p "$root/home/.config/quickshell/bar" "$root/toggles" "$root/run"
  : > "$root/home/.config/quickshell/bar/.qsrise"
  : > "$root/home/.config/quickshell/bar/shell.qml"
  : > "$root/toggles/bar-off"
  : > "$root/actions.log"

  run_uninstaller "$root" >/dev/null
  assert_file "$root/toggles/bar-off" "foreign hidden state preservation"
  assert_not_contains "omarchy toggle bar" "$root/actions.log" "foreign toggle mutation"
  assert_not_contains "restart waybar" "$root/actions.log" "Quattro Waybar restart"
}

case_uninstall_toggle_failure_aborts() {
  local root="$WORK/uninstall-toggle-fail"
  make_fake_tools "$root"
  prepare_owned_install "$root"
  mkdir -p "$root/home/.config/omarchy/hooks/post-boot.d"
  : > "$root/home/.config/omarchy/hooks/post-boot.d/quickshell-rise"

  if QSR_TEST_TOGGLE_FAIL=1 run_uninstaller "$root" >/dev/null 2>&1; then
    fail "uninstaller accepted failed Quattro toggle"
  fi
  assert_file "$root/home/.config/quickshell/bar/.qsrise" "toggle failure config preservation"
  assert_file "$root/home/.config/omarchy/hooks/post-boot.d/quickshell-rise" "toggle failure hook preservation"
  assert_file "$root/state/quickshell-rise/owns-omarchy-bar-off" "toggle failure marker preservation"
}

case_uninstall_legacy_and_generic() {
  local legacy="$WORK/uninstall-legacy" generic="$WORK/uninstall-generic"

  make_fake_tools "$legacy"
  rm -f "$legacy/bin/omarchy-toggle-bar" "$legacy/bin/omarchy-toggle-enabled"
  mkdir -p "$legacy/home/.config/quickshell/bar" "$legacy/run"
  : > "$legacy/home/.config/quickshell/bar/.qsrise"
  : > "$legacy/actions.log"
  run_uninstaller "$legacy" >/dev/null
  assert_contains "omarchy restart waybar" "$legacy/actions.log" "legacy Waybar restore"

  make_fake_tools "$generic"
  rm -f "$generic/bin/omarchy" "$generic/bin/omarchy-toggle-bar" "$generic/bin/omarchy-toggle-enabled"
  mkdir -p "$generic/home/.config/quickshell/bar" "$generic/run"
  : > "$generic/home/.config/quickshell/bar/.qsrise"
  : > "$generic/actions.log"
  run_uninstaller "$generic" >/dev/null
  assert_contains "setsid waybar" "$generic/actions.log" "generic Waybar restore"
}

case_uninstall_registry_failure_aborts() {
  local root="$WORK/uninstall-registry-fail" config path_id
  make_fake_tools "$root"
  mkdir -p "$root/home/.config/quickshell/bar" "$root/run/quickshell/by-path" "$root/toggles"
  : > "$root/home/.config/quickshell/bar/.qsrise"
  : > "$root/home/.config/quickshell/bar/shell.qml"
  : > "$root/actions.log"
  config="$root/home/.config/quickshell/bar/shell.qml"
  path_id="$(printf '%s' "$config" | md5sum | awk '{print $1}')"
  mkdir -p "$root/run/quickshell/by-path/$path_id"
  ln -s /usr/bin/bash "$root/bin/qs"
  cat > "$root/bin/lslocks" <<'SCRIPT'
#!/usr/bin/env bash
exit 70
SCRIPT
  chmod 0755 "$root/bin/lslocks"

  if run_uninstaller "$root" >/dev/null 2>&1; then
    fail "uninstaller treated failed lslocks as an empty registry"
  fi
  assert_file "$root/home/.config/quickshell/bar/.qsrise" "registry failure config preservation"
}

case_static_contracts() {
  local shared_function

  assert_not_contains "qs list --all" "$README" "README unsafe instance query"
  assert_contains "qsr_has_quattro" "$INSTALLER" "installer capability gate"
  assert_contains "hook_was_installed" "$INSTALLER" "installer existing-hook gate"
  assert_contains "qsr_hide_stock_bar_owned" "$INSTALLER" "installer ownership hide"
  assert_contains "pkill -x waybar" "$INSTALLER" "legacy/generic Waybar overlap guard"
  assert_contains "if [[ \"\$quattro_mode\" != true ]]" "$INSTALLER" "Waybar Quattro exclusion"
  assert_before "qsr_wait_for_bar" "pkill -x waybar" "$INSTALLER" "health before Waybar stop"
  assert_before "qsr_wait_for_bar" "qsr_hide_stock_bar_owned" "$INSTALLER" "health before Quattro hide"
  assert_before "if ! qsr_release_owned_stock_bar" "if ! qsr_stop_bar_instances" "$UNINSTALLER" "show before stop"
  assert_contains "left it stopped because the Omarchy stock bar is active" "$UNINSTALLER" "backup double-bar guard"
  assert_contains "Other Hyprland systems" "$README" "non-Omarchy compatibility docs"

  # uninstall.sh intentionally stays standalone. Keep the shared lifecycle
  # functions byte-identical so future fixes cannot silently land in one copy.
  for shared_function in \
    qsr_export_omarchy_path qsr_has_quattro qsr_pid_holds_lock \
    qsr_live_bar_pids qsr_term_pid qsr_stop_registered_bars \
    qsr_stop_legacy_patterns qsr_stop_bar_instances qsr_stock_bar_hidden \
    qsr_wait_for_stock_state qsr_set_stock_bar qsr_owns_stock_bar_hide \
    qsr_release_owned_stock_bar; do
    assert_shared_function_same "$shared_function"
  done
}

case_runtime_toggle_ownership
case_runtime_postboot_order_and_fail_open
case_registry_live_health_and_stop
case_uninstall_owned_backup_provider
case_uninstall_foreign_hidden_state
case_uninstall_toggle_failure_aborts
case_uninstall_legacy_and_generic
case_uninstall_registry_failure_aborts
case_static_contracts

printf 'PASS: Quattro lifecycle, ownership, fail-open, registry, uninstall, legacy, and generic regressions\n'
