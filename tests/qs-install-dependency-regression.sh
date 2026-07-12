#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"
WORK="$(mktemp -d /tmp/qs-install-dependency-test.XXXXXX)"
FRAGMENT="$WORK/install-dependencies.sh"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  grep -Fq -- "$1" "$2" || fail "$3"
}

# Run the real installer through the dependency phase, then stop before its
# network clone. This keeps the prompt/control flow identical without touching
# the user's bar, repository, systemd units, or packages.
awk '/^# ── 2\. fetch repo/{exit} {print}' "$INSTALLER" > "$FRAGMENT"
printf '\nexit 0\n' >> "$FRAGMENT"

init_fixture() {
  local root="$1" name
  mkdir -p "$root/bin" "$root/home"
  ln -s "$(command -v bash)" "$root/bin/bash"
  ln -s "$(command -v chmod)" "$root/bin/chmod"

  for name in qs git jq curl; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/$name"
    chmod +x "$root/bin/$name"
  done

  cat > "$root/bin/fc-list" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' 'JetBrainsMono Nerd Font' 'Material Symbols Rounded'
SCRIPT

  cat > "$root/bin/sudo" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SUDO_LOG"
if [ "${FAKE_SUDO_RC:-0}" -ne 0 ]; then
  exit "$FAKE_SUDO_RC"
fi
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/checkupdates"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/fakeroot"
chmod +x "$FAKE_BIN/checkupdates" "$FAKE_BIN/fakeroot"
SCRIPT
  chmod +x "$root/bin/fc-list" "$root/bin/sudo"
  : > "$root/sudo.log"
}

run_without_tty() {
  local root="$1"
  PATH="$root/bin" \
  HOME="$root/home" \
  FAKE_BIN="$root/bin" \
  FAKE_SUDO_LOG="$root/sudo.log" \
  /usr/bin/bash "$FRAGMENT" </dev/null >"$root/out" 2>"$root/err"
}

run_with_answer() {
  local root="$1" answer="$2" sudo_rc="${3:-0}" command
  command="env PATH='$root/bin' HOME='$root/home' FAKE_BIN='$root/bin' FAKE_SUDO_LOG='$root/sudo.log' FAKE_SUDO_RC='$sudo_rc' /usr/bin/bash '$FRAGMENT'"
  printf '%s\n' "$answer" | script -qec "$command" /dev/null >"$root/out" 2>"$root/err"
}

test_no_tty_continues_without_sudo() {
  local root="$WORK/no-tty"
  init_fixture "$root"
  run_without_tty "$root"

  [ ! -s "$root/sudo.log" ] || fail "installer invoked sudo without an interactive terminal"
  assert_contains "No interactive terminal available" "$root/out" "no-TTY skip was not explained"
  assert_contains "required for safe repository update scans" "$root/out" "missing dependency capability was not explained"
}

test_decline_continues_and_prints_exact_command() {
  local root="$WORK/decline"
  init_fixture "$root"
  run_with_answer "$root" "n"

  [ ! -s "$root/sudo.log" ] || fail "installer invoked sudo after dependency prompt was declined"
  assert_contains "sudo pacman -S --needed pacman-contrib fakeroot" "$root/out" "later-install command is missing or incorrect"
}

test_accept_installs_exact_package_and_enables_capability() {
  local root="$WORK/accept"
  init_fixture "$root"
  run_with_answer "$root" "y"

  [ -x "$root/bin/checkupdates" ] || fail "successful dependency install did not expose checkupdates"
  [ -x "$root/bin/fakeroot" ] || fail "successful dependency install did not expose fakeroot"
  [ "$(cat "$root/sudo.log")" = "pacman -S --needed pacman-contrib fakeroot" ] \
    || fail "installer did not use the exact optional dependency command"
  assert_contains "repository update scans are enabled" "$root/out" "successful dependency install was not confirmed"
}

test_install_failure_does_not_abort_bar_install() {
  local root="$WORK/install-failure"
  init_fixture "$root"
  run_with_answer "$root" "y" 1

  [ ! -e "$root/bin/checkupdates" ] || fail "failed dependency install unexpectedly created checkupdates"
  [ ! -e "$root/bin/fakeroot" ] || fail "failed dependency install unexpectedly created fakeroot"
  assert_contains "continuing with repository update scans disabled" "$root/out" "dependency failure was not handled as optional"
}

test_self_update_never_prompts_or_installs_dependency() {
  if grep -Fq 'pacman-contrib' "$REPO_ROOT/scripts/qs-shell-post-update.sh"; then
    fail "shell self-update gained pacman-contrib installation or prompting"
  fi
}

test_no_tty_continues_without_sudo
test_decline_continues_and_prints_exact_command
test_accept_installs_exact_package_and_enables_capability
test_install_failure_does_not_abort_bar_install
test_self_update_never_prompts_or_installs_dependency

printf 'qs-install dependency regression tests passed\n'
