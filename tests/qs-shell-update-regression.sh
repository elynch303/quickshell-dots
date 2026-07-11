#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${CHECK:-$REPO_ROOT/scripts/qs-shell-check-update.sh}"
APPLY="${APPLY:-$REPO_ROOT/scripts/qs-shell-apply-update.sh}"
WORK="$(mktemp -d /tmp/qs-shell-update-test.XXXXXX)"

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
  grep -Fq -- "$needle" "$file" || fail "$msg: missing '$needle'"
}

state_file() {
  printf '%s/.cache/qs-shell/update-available.json\n' "$1/home"
}

write_payload() {
  local repo="$1" label="$2" mode="${3:-ok}"
  rm -rf "$repo/versions" "$repo/scripts" "$repo/systemd" "$repo/hooks"
  mkdir -p "$repo/versions/V1" "$repo/scripts" "$repo/systemd" "$repo/hooks"
  case "$mode" in
    missing-shell) ;;
    invalid-shell) printf 'import QtQuick\nItem {\n' > "$repo/versions/V1/shell.qml" ;;
    invalid-import) printf 'import Definitely.Not.A.Real.Module\nimport QtQuick\nItem {}\n' > "$repo/versions/V1/shell.qml" ;;
    bad-local-import) printf 'import QtQuick\nimport "missingLocal"\nItem {}\n' > "$repo/versions/V1/shell.qml" ;;
    missing-component) printf 'import QtQuick\nMissingComponent {}\n' > "$repo/versions/V1/shell.qml" ;;
    qs-module-import)
      mkdir -p "$repo/versions/V1/modules"
      printf 'module qs.modules\nTestThing 1.0 TestThing.qml\n' > "$repo/versions/V1/modules/qmldir"
      printf 'import QtQuick\nItem {}\n' > "$repo/versions/V1/modules/TestThing.qml"
      printf 'import QtQuick\nimport qs.modules\nItem { TestThing {} }\n' > "$repo/versions/V1/shell.qml"
      ;;
    qs-module-import-side-effect)
      mkdir -p "$repo/versions/V1/modules"
      printf 'module qs.modules\nTestThing 1.0 TestThing.qml\n' > "$repo/versions/V1/modules/qmldir"
      printf 'import QtQuick\nItem {}\n' > "$repo/versions/V1/modules/TestThing.qml"
      cat > "$repo/versions/V1/shell.qml" <<'QML'
import QtQuick
import Quickshell.Io
import qs.modules

Item {
  TestThing {}
  Process {
    command: ["sh", "-c", "printf SIDE_EFFECT > \"$HOME/qs-smoke-side-effect\""]
    running: true
  }
}
QML
      ;;
    qs-module-import-no-qmldir-side-effect)
      mkdir -p "$repo/versions/V1/modules"
      printf 'import QtQuick\nItem {}\n' > "$repo/versions/V1/modules/TestThing.qml"
      cat > "$repo/versions/V1/shell.qml" <<'QML'
import QtQuick
import Quickshell.Io
import qs.modules

Item {
  TestThing {}
  Process {
    command: ["sh", "-c", "printf SIDE_EFFECT > \"$HOME/qs-smoke-side-effect\""]
    running: true
  }
}
QML
      ;;
    *) printf 'import QtQuick\nItem {}\n' > "$repo/versions/V1/shell.qml" ;;
  esac
  printf '%s\n' "$label" > "$repo/versions/V1/payload.txt"
  printf '%s\n' "$label" > "$repo/scripts/companion.txt"
  printf 'theme-hook-%s\n' "$label" > "$repo/hooks/50-quickshell-bar.sh"
  chmod 755 "$repo/hooks/50-quickshell-bar.sh"
  printf 'companion-marker\n.config/omarchy/hooks/theme-set.d/50-quickshell-bar.sh\n' > "$repo/scripts/qs-shell-post-update.targets"
  if [ "$mode" = "bad-companion" ]; then
    cat > "$repo/scripts/qs-shell-post-update.sh" <<'SCRIPT'
#!/usr/bin/env bash
exit 42
SCRIPT
  elif [ "$mode" = "no-companion-manifest" ]; then
    rm -f "$repo/scripts/qs-shell-post-update.targets"
    cat > "$repo/scripts/qs-shell-post-update.sh" <<'SCRIPT'
#!/usr/bin/env bash
printf 'SHOULD-NOT-RUN\n' > "$HOME/companion-marker"
SCRIPT
  elif [ "$mode" = "bad-companion-after-mutation" ]; then
    printf 'companion-side-effect\n' > "$repo/scripts/qs-shell-post-update.targets"
    cat > "$repo/scripts/qs-shell-post-update.sh" <<'SCRIPT'
#!/usr/bin/env bash
printf 'TARGET-SIDE-EFFECT\n' > "$HOME/companion-side-effect"
exit 42
SCRIPT
  elif [ "$mode" = "blacklist-side-effects-fail" ]; then
    printf '.local/share/qs-aur-blacklist.txt\n.local/share/qs-aur-blacklist.txt.meta.json\n.local/share/qs-aur-blacklist.txt.pending\n' > "$repo/scripts/qs-shell-post-update.targets"
    cat > "$repo/scripts/qs-shell-post-update.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/.local/share"
printf 'TARGET-LIST\n' > "$HOME/.local/share/qs-aur-blacklist.txt"
printf 'TARGET-META\n' > "$HOME/.local/share/qs-aur-blacklist.txt.meta.json"
printf 'TARGET-PENDING\n' > "$HOME/.local/share/qs-aur-blacklist.txt.pending"
exit 42
SCRIPT
  elif [ "$mode" = "systemd-unit-mutation-fail" ]; then
    printf '.config/systemd/user/qs-shell-update-check.timer\n' > "$repo/scripts/qs-shell-post-update.targets"
    cat > "$repo/scripts/qs-shell-post-update.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/.config/systemd/user"
printf 'TARGET-UNIT\n' > "$HOME/.config/systemd/user/qs-shell-update-check.timer"
exit 42
SCRIPT
  elif [ "$mode" = "systemd-unit-mutation-ok" ]; then
    printf '.config/systemd/user/qs-shell-update-check.timer\n' > "$repo/scripts/qs-shell-post-update.targets"
    cat > "$repo/scripts/qs-shell-post-update.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/.config/systemd/user"
printf 'TARGET-UNIT\n' > "$HOME/.config/systemd/user/qs-shell-update-check.timer"
SCRIPT
  elif [ "$mode" = "hook-mutation-fail" ]; then
    printf '.config/omarchy/hooks/theme-set.d/50-quickshell-bar.sh\n' > "$repo/scripts/qs-shell-post-update.targets"
    cat > "$repo/scripts/qs-shell-post-update.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
src="${1:?}"
mkdir -p "$HOME/.config/omarchy/hooks/theme-set.d"
cp "$src/hooks/50-quickshell-bar.sh" "$HOME/.config/omarchy/hooks/theme-set.d/50-quickshell-bar.sh"
exit 42
SCRIPT
  else
    cat > "$repo/scripts/qs-shell-post-update.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
src="${1:?}"
mkdir -p "$HOME"
cp "$src/scripts/companion.txt" "$HOME/companion-marker"
mkdir -p "$HOME/.config/omarchy/hooks/theme-set.d"
cp "$src/hooks/50-quickshell-bar.sh" "$HOME/.config/omarchy/hooks/theme-set.d/50-quickshell-bar.sh"
chmod 755 "$HOME/.config/omarchy/hooks/theme-set.d/50-quickshell-bar.sh"
SCRIPT
  fi
  printf '[Unit]\nDescription=%s\n' "$label" > "$repo/systemd/qs-test.service"
}

commit_payload() {
  local repo="$1" label="$2" mode="${3:-ok}"
  write_payload "$repo" "$label" "$mode"
  git -C "$repo" add -A >/dev/null
  git -C "$repo" commit -m "payload-$label" >/dev/null
}

init_fixture() {
  local root="$1"
  mkdir -p "$root/home" "$root/state" "$root/dest"
  git init --bare "$root/remote.git" >/dev/null
  git init "$root/repo" >/dev/null
  git -C "$root/repo" config user.email test@example.invalid
  git -C "$root/repo" config user.name Test
  git -C "$root/repo" branch -M main
  git -C "$root/repo" remote add origin "$root/remote.git"

  commit_payload "$root/repo" base
  git -C "$root/repo" push -u origin main >/dev/null 2>&1
  git --git-dir="$root/remote.git" symbolic-ref HEAD refs/heads/main

  git -C "$root/repo" archive HEAD:versions/V1 | tar -x -C "$root/dest"
  printf 'V1\n' > "$root/dest/.qsrise"
  git -C "$root/repo" rev-parse HEAD > "$root/dest/.qsrise-commit"
  mkdir -p "$root/home/.config/omarchy/hooks/theme-set.d"
  git -C "$root/repo" show HEAD:hooks/50-quickshell-bar.sh > "$root/home/.config/omarchy/hooks/theme-set.d/50-quickshell-bar.sh"
  chmod 755 "$root/home/.config/omarchy/hooks/theme-set.d/50-quickshell-bar.sh"
}

make_update_and_check() {
  local root="$1" label="$2" mode="${3:-ok}"
  commit_payload "$root/repo" "$label" "$mode"
  git -C "$root/repo" push origin main >/dev/null 2>&1
  HOME="$root/home" \
  QS_SHELL_REPO="$root/repo" \
  QS_SHELL_DEST="$root/dest" \
    "$CHECK"
  jq -e '(.schemaVersion == 4) and (.behind > 0)
    and (.targetCommit | type == "string")
    and (.commitIds | type == "array") and (.commitIds | length > 0)
    and (.payloadTree | type == "string") and (.payloadTree | length > 0)
    and (.scriptsTree | type == "string")
    and (.systemdTree | type == "string")
    and (.hookBlob | type == "string")' "$(state_file "$root")" >/dev/null
}

run_apply() {
  local root="$1"
  PATH="$root/bin:$PATH" \
  HOME="$root/home" \
  XDG_STATE_HOME="$root/state" \
  QS_SHELL_REPO="$root/repo" \
  QS_SHELL_DEST="$root/dest" \
  QS_SHELL_NO_RESTART=1 \
  QS_SHELL_SMOKE_PLATFORM=offscreen \
  QS_SHELL_SMOKE_TIMEOUT=1 \
    "$APPLY"
}

install_fake_systemctl() {
  local root="$1"
  mkdir -p "$root/bin"
cat > "$root/bin/systemctl" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/systemctl.log"
[ "${1:-}" = "--user" ] || exit 0
shift
case "${1:-}" in
  daemon-reload)
    if [ -e "$HOME/.config/systemd/user/qs-shell-update-check.timer" ]; then
      printf 'daemon-reload-unit=%s\n' "$(tr -d '\n' < "$HOME/.config/systemd/user/qs-shell-update-check.timer")" >> "$HOME/systemctl.log"
    else
      printf 'daemon-reload-unit=missing\n' >> "$HOME/systemctl.log"
    fi
    ;;
  is-enabled)
    if [ "${2:-}" = "qs-shell-update-check.timer" ]; then
      printf 'enabled\n'
      exit 0
    fi
    printf 'disabled\n'
    exit 1
    ;;
  is-active)
    if [ "${2:-}" = "qs-shell-update-check.timer" ]; then
      printf 'active\n'
      exit 0
    fi
    printf 'inactive\n'
    exit 3
    ;;
esac
exit 0
SCRIPT
  chmod 755 "$root/bin/systemctl"
}

install_failing_systemctl() {
  local root="$1"
  mkdir -p "$root/bin"
  cat > "$root/bin/systemctl" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/systemctl.log"
exit 1
SCRIPT
  chmod 755 "$root/bin/systemctl"
}

assert_pending_state_preserved() {
  local root="$1" before="$2"
  assert_eq "$before" "$(jq -c . "$(state_file "$root")")" "pending state preserved"
}

assert_dest_label() {
  local root="$1" label="$2"
  assert_eq "$label" "$(tr -d '\n' < "$root/dest/payload.txt")" "deployed payload label"
}

assert_installed_hook() {
  local root="$1" label="$2"
  assert_eq "theme-hook-$label" "$(tr -d '\n' < "$root/home/.config/omarchy/hooks/theme-set.d/50-quickshell-bar.sh")" "installed theme hook"
}

installed_payload_hash() {
  local dir="$1"
  (
    cd "$dir"
    LC_ALL=C find . -type f ! -name '.qsrise' ! -name '.qsrise-commit' ! -name '.qsrise-payload-tree' -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 sha256sum \
      | sha256sum \
      | awk '{print $1}'
  )
}

target_payload_hash() {
  local root="$1" commit="$2" tmp
  tmp="$root/expected-payload"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  git -C "$root/repo" archive "$commit:versions/V1" | tar -x -C "$tmp"
  installed_payload_hash "$tmp"
}

test_remote_moves_but_apply_installs_checked_target() {
  local root="$WORK/move"
  init_fixture "$root"
  make_update_and_check "$root" A
  local target_a
  target_a="$(jq -r '.targetCommit' "$(state_file "$root")")"

  commit_payload "$root/repo" B
  git -C "$root/repo" push origin main >/dev/null 2>&1
  run_apply "$root" >/dev/null

  assert_dest_label "$root" A
  assert_eq "$target_a" "$(tr -d '\n' < "$root/dest/.qsrise-commit")" "deploy stayed pinned to checked target"
  assert_eq "$(target_payload_hash "$root" "$target_a")" "$(installed_payload_hash "$root/dest")" "installed payload byte hash"
  assert_eq "$(git -C "$root/repo" rev-parse "$target_a:versions/V1")" \
    "$(tr -d '\n' < "$root/dest/.qsrise-payload-tree")" "installed payload tree marker"
  assert_eq A "$(tr -d '\n' < "$root/home/companion-marker")" "companion came from checked target"
  assert_installed_hook "$root" A
  assert_eq 0 "$(jq -r '.behind' "$(state_file "$root")")" "success cleared state"
}

test_hook_only_update_installs_checked_hook() {
  local root="$WORK/hook-only"
  init_fixture "$root"
  printf 'theme-hook-A\n' > "$root/repo/hooks/50-quickshell-bar.sh"
  git -C "$root/repo" add hooks/50-quickshell-bar.sh >/dev/null
  git -C "$root/repo" commit -m "hook-only" >/dev/null
  git -C "$root/repo" push origin main >/dev/null 2>&1

  HOME="$root/home" QS_SHELL_REPO="$root/repo" QS_SHELL_DEST="$root/dest" "$CHECK"
  local target hook_blob
  target="$(jq -r '.targetCommit' "$(state_file "$root")")"
  hook_blob="$(git -C "$root/repo" rev-parse "$target:hooks/50-quickshell-bar.sh")"
  jq -e --arg hook "$hook_blob" '(.schemaVersion == 4) and (.behind == 1) and (.hookBlob == $hook)' "$(state_file "$root")" >/dev/null

  run_apply "$root" >/dev/null
  assert_dest_label "$root" base
  assert_installed_hook "$root" A
  assert_eq "$target" "$(tr -d '\n' < "$root/dest/.qsrise-commit")" "hook-only update deployed checked target"
  assert_eq 0 "$(jq -r '.behind' "$(state_file "$root")")" "success cleared state"
}

test_check_clears_stale_schema_before_offline_fetch() {
  local root="$WORK/stale-schema-offline"
  init_fixture "$root"
  mkdir -p "$(dirname "$(state_file "$root")")"
  printf '{"behind":3,"checked":"old"}\n' > "$(state_file "$root")"
  git -C "$root/repo" remote set-url origin "$root/missing-remote.git"

  HOME="$root/home" QS_SHELL_REPO="$root/repo" QS_SHELL_DEST="$root/dest" "$CHECK"
  jq -e '(.schemaVersion == 4) and (.behind == 0)' "$(state_file "$root")" >/dev/null
}

test_alternate_reachable_commit_with_same_subject_aborts() {
  local root="$WORK/alternate-same-subject"
  init_fixture "$root"
  local base target_b before
  base="$(git -C "$root/repo" rev-parse HEAD)"

  printf 'CHECKED-A\n' > "$root/repo/versions/V1/checked-marker"
  git -C "$root/repo" add versions/V1/checked-marker >/dev/null
  git -C "$root/repo" commit -m "same-subject" >/dev/null
  git -C "$root/repo" push origin main >/dev/null 2>&1
  HOME="$root/home" QS_SHELL_REPO="$root/repo" QS_SHELL_DEST="$root/dest" "$CHECK"
  jq -e '(.schemaVersion == 4) and (.behind == 1) and (.summary == ["same-subject"])' "$(state_file "$root")" >/dev/null

  git -C "$root/repo" checkout -b alternate "$base" >/dev/null 2>&1
  printf 'ALTERNATE-B\n' > "$root/repo/versions/V1/alternate-marker"
  git -C "$root/repo" add versions/V1/alternate-marker >/dev/null
  git -C "$root/repo" commit -m "same-subject" >/dev/null
  target_b="$(git -C "$root/repo" rev-parse HEAD)"
  git -C "$root/repo" checkout main >/dev/null 2>&1
  git -C "$root/repo" merge --no-ff alternate -m "merge alternate" >/dev/null
  git -C "$root/repo" push origin main >/dev/null 2>&1

  jq --arg target "$target_b" '.targetCommit = $target' "$(state_file "$root")" > "$root/state.tmp"
  mv "$root/state.tmp" "$(state_file "$root")"
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded after target SHA was changed to alternate reachable commit with same count and subject"
  fi
  assert_dest_label "$root" base
  assert_pending_state_preserved "$root" "$before"
}

test_later_non_payload_commit_in_target_state_aborts() {
  local root="$WORK/later-non-payload"
  init_fixture "$root"
  make_update_and_check "$root" A
  mkdir -p "$root/repo/docs"
  printf 'docs only\n' > "$root/repo/docs/readme.txt"
  git -C "$root/repo" add docs/readme.txt >/dev/null
  git -C "$root/repo" commit -m "docs-only" >/dev/null
  git -C "$root/repo" push origin main >/dev/null 2>&1
  local target_docs before
  target_docs="$(git -C "$root/repo" rev-parse HEAD)"
  jq --arg target "$target_docs" '.targetCommit = $target' "$(state_file "$root")" > "$root/state.tmp"
  mv "$root/state.tmp" "$(state_file "$root")"
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded after target SHA was changed to later non-payload commit"
  fi
  assert_dest_label "$root" base
  assert_pending_state_preserved "$root" "$before"
}

test_missing_target_aborts_before_mutation() {
  local root="$WORK/missing-target"
  init_fixture "$root"
  make_update_and_check "$root" A
  local before
  before="$(jq -c . "$(state_file "$root")")"
  jq '.targetCommit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$(state_file "$root")" > "$root/state.tmp"
  mv "$root/state.tmp" "$(state_file "$root")"
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded with missing target commit"
  fi
  assert_dest_label "$root" base
  assert_pending_state_preserved "$root" "$before"
}

test_changed_target_sha_aborts_before_mutation() {
  local root="$WORK/changed-target"
  init_fixture "$root"
  make_update_and_check "$root" A
  commit_payload "$root/repo" B
  git -C "$root/repo" push origin main >/dev/null 2>&1
  local target_b before
  target_b="$(git -C "$root/repo" rev-parse HEAD)"
  jq --arg target "$target_b" '.targetCommit = $target' "$(state_file "$root")" > "$root/state.tmp"
  mv "$root/state.tmp" "$(state_file "$root")"
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded after target SHA was changed to a different reachable commit"
  fi
  assert_dest_label "$root" base
  assert_pending_state_preserved "$root" "$before"
}

test_unreachable_target_aborts_before_mutation() {
  local root="$WORK/unreachable"
  init_fixture "$root"
  make_update_and_check "$root" A
  local before base
  before="$(jq -c . "$(state_file "$root")")"
  base="$(tr -d '\n' < "$root/dest/.qsrise-commit")"

  git -C "$root/repo" reset --hard "$base" >/dev/null
  commit_payload "$root/repo" C
  git -C "$root/repo" push --force origin main >/dev/null 2>&1

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded with target no longer reachable"
  fi
  assert_dest_label "$root" base
  assert_pending_state_preserved "$root" "$before"
}

test_dirty_repo_aborts_before_mutation() {
  local root="$WORK/dirty"
  init_fixture "$root"
  make_update_and_check "$root" A
  local before
  before="$(jq -c . "$(state_file "$root")")"
  printf 'local edit\n' >> "$root/repo/versions/V1/payload.txt"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded with dirty repo"
  fi
  assert_dest_label "$root" base
  assert_pending_state_preserved "$root" "$before"
}

test_staging_smoke_failure_keeps_old_deploy_and_pending_state() {
  local root="$WORK/smoke"
  init_fixture "$root"
  make_update_and_check "$root" broken missing-shell
  local before
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded with staged payload missing shell.qml"
  fi
  assert_dest_label "$root" base
  assert_pending_state_preserved "$root" "$before"
}

test_invalid_shell_qml_fails_smoke_and_keeps_old_deploy() {
  local root="$WORK/invalid-qml"
  init_fixture "$root"
  make_update_and_check "$root" invalid invalid-shell
  local before
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded with invalid staged shell.qml"
  fi
  assert_dest_label "$root" base
  assert_pending_state_preserved "$root" "$before"
}

test_invalid_import_fails_smoke_and_keeps_old_deploy() {
  local root="$WORK/invalid-import"
  init_fixture "$root"
  make_update_and_check "$root" invalid-import invalid-import
  local before
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded with staged shell.qml importing an unknown module"
  fi
  assert_dest_label "$root" base
  assert_pending_state_preserved "$root" "$before"
}

test_bad_local_import_fails_smoke_and_keeps_old_deploy() {
  local root="$WORK/bad-local-import"
  init_fixture "$root"
  make_update_and_check "$root" bad-local bad-local-import
  local before
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded with staged shell.qml importing a missing local directory"
  fi
  assert_dest_label "$root" base
  assert_pending_state_preserved "$root" "$before"
}

test_missing_component_fails_smoke_and_keeps_old_deploy() {
  local root="$WORK/missing-component"
  init_fixture "$root"
  make_update_and_check "$root" missing-component missing-component
  local before
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded with staged shell.qml referencing a missing component"
  fi
  assert_dest_label "$root" base
  assert_pending_state_preserved "$root" "$before"
}

test_qs_module_import_passes_smoke() {
  local root="$WORK/qs-module-import"
  init_fixture "$root"
  make_update_and_check "$root" qs-module qs-module-import

  run_apply "$root" >/dev/null
  assert_dest_label "$root" qs-module
  [ ! -e "$root/dest/.qs-shell-smoke.qml" ] || fail "smoke wrapper leaked into deployed payload"
  assert_eq 0 "$(jq -r '.behind' "$(state_file "$root")")" "success cleared state"
}

test_qs_module_with_qmldir_smoke_does_not_execute_side_effect() {
  local root="$WORK/qs-module-side-effect"
  init_fixture "$root"
  make_update_and_check "$root" qs-module-side-effect qs-module-import-side-effect

  run_apply "$root" >/dev/null
  assert_dest_label "$root" qs-module-side-effect
  [ ! -e "$root/home/qs-smoke-side-effect" ] || fail "qs.* qmldir smoke executed staged QML side effect"
  assert_eq 0 "$(jq -r '.behind' "$(state_file "$root")")" "success cleared state"
}

test_qs_module_without_qmldir_fails_before_side_effect() {
  local root="$WORK/qs-module-no-qmldir"
  init_fixture "$root"
  make_update_and_check "$root" no-qmldir qs-module-import-no-qmldir-side-effect
  local before
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded with qs.* module missing qmldir"
  fi
  assert_dest_label "$root" base
  assert_pending_state_preserved "$root" "$before"
  [ ! -e "$root/home/qs-smoke-side-effect" ] || fail "qs.* no-qmldir smoke executed staged QML side effect"
}

test_manifest_does_not_restore_whole_systemd_wants_dir() {
  if grep -Fxq '.config/systemd/user/timers.target.wants' "$REPO_ROOT/scripts/qs-shell-post-update.targets"; then
    fail "companion target manifest restores whole timers.target.wants directory"
  fi
}

test_companion_manifest_is_required() {
  local root="$WORK/companion-no-manifest"
  init_fixture "$root"
  make_update_and_check "$root" A no-companion-manifest
  local before
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded despite companion post-update missing rollback manifest"
  fi
  assert_dest_label "$root" base
  [ ! -e "$root/home/companion-marker" ] || fail "companion ran despite missing manifest"
  assert_pending_state_preserved "$root" "$before"
}

test_companion_failure_keeps_old_deploy_and_pending_state() {
  local root="$WORK/companion-fail"
  init_fixture "$root"
  make_update_and_check "$root" A bad-companion
  local before
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded despite failing companion post-update"
  fi
  assert_dest_label "$root" base
  assert_pending_state_preserved "$root" "$before"
}

test_companion_mutation_failure_restores_side_effect() {
  local root="$WORK/companion-mutation-fail"
  init_fixture "$root"
  printf 'BASE-SIDE-EFFECT\n' > "$root/home/companion-side-effect"
  make_update_and_check "$root" A bad-companion-after-mutation
  local before
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded despite companion mutation followed by failure"
  fi
  assert_dest_label "$root" base
  assert_eq BASE-SIDE-EFFECT "$(tr -d '\n' < "$root/home/companion-side-effect")" "companion side effect restored"
  assert_pending_state_preserved "$root" "$before"
}

test_hook_mutation_failure_restores_old_hook() {
  local root="$WORK/hook-mutation-fail"
  init_fixture "$root"
  make_update_and_check "$root" A hook-mutation-fail
  local before
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded despite hook mutation followed by companion failure"
  fi
  assert_dest_label "$root" base
  assert_installed_hook "$root" base
  assert_pending_state_preserved "$root" "$before"
}

test_companion_blacklist_side_effects_restore() {
  local root="$WORK/companion-blacklist-fail"
  init_fixture "$root"
  mkdir -p "$root/home/.local/share"
  printf 'BASE-LIST\n' > "$root/home/.local/share/qs-aur-blacklist.txt"
  printf 'BASE-META\n' > "$root/home/.local/share/qs-aur-blacklist.txt.meta.json"
  printf 'BASE-PENDING\n' > "$root/home/.local/share/qs-aur-blacklist.txt.pending"
  make_update_and_check "$root" A blacklist-side-effects-fail
  local before
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded despite companion blacklist mutation followed by failure"
  fi
  assert_dest_label "$root" base
  assert_eq BASE-LIST "$(tr -d '\n' < "$root/home/.local/share/qs-aur-blacklist.txt")" "blacklist list restored"
  assert_eq BASE-META "$(tr -d '\n' < "$root/home/.local/share/qs-aur-blacklist.txt.meta.json")" "blacklist meta restored"
  assert_eq BASE-PENDING "$(tr -d '\n' < "$root/home/.local/share/qs-aur-blacklist.txt.pending")" "blacklist pending restored"
  assert_pending_state_preserved "$root" "$before"
}

test_companion_failure_restores_systemd_state() {
  local root="$WORK/companion-systemd-fail"
  init_fixture "$root"
  install_fake_systemctl "$root"
  make_update_and_check "$root" A bad-companion-after-mutation
  local before
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded despite companion failure in systemd restore test"
  fi
  assert_dest_label "$root" base
  assert_contains "--user daemon-reload" "$root/home/systemctl.log" "systemd daemon-reload was not run during rollback"
  assert_contains "--user enable qs-shell-update-check.timer" "$root/home/systemctl.log" "previous enabled timer state was not restored"
  assert_contains "--user start qs-shell-update-check.timer" "$root/home/systemctl.log" "previous active timer state was not restored"
  assert_pending_state_preserved "$root" "$before"
}

test_systemd_restore_happens_after_file_restore() {
  local root="$WORK/companion-systemd-order"
  init_fixture "$root"
  install_fake_systemctl "$root"
  mkdir -p "$root/home/.config/systemd/user"
  printf 'BASE-UNIT\n' > "$root/home/.config/systemd/user/qs-shell-update-check.timer"
  make_update_and_check "$root" A systemd-unit-mutation-fail
  local before
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded despite companion systemd unit mutation followed by failure"
  fi
  assert_dest_label "$root" base
  assert_eq BASE-UNIT "$(tr -d '\n' < "$root/home/.config/systemd/user/qs-shell-update-check.timer")" "systemd unit file restored"
  assert_contains "daemon-reload-unit=BASE-UNIT" "$root/home/systemctl.log" "systemd daemon-reload did not observe restored unit files"
  assert_pending_state_preserved "$root" "$before"
}

test_systemd_commit_failure_keeps_pending_state() {
  local root="$WORK/systemd-commit-fail"
  init_fixture "$root"
  install_failing_systemctl "$root"
  make_update_and_check "$root" A systemd-unit-mutation-ok
  local before
  before="$(jq -c . "$(state_file "$root")")"

  if run_apply "$root" >"$root/apply.out" 2>"$root/apply.err"; then
    fail "apply succeeded despite systemctl failing during commit phase"
  fi
  assert_dest_label "$root" base
  assert_pending_state_preserved "$root" "$before"
}

test_remote_moves_but_apply_installs_checked_target
test_check_clears_stale_schema_before_offline_fetch
test_hook_only_update_installs_checked_hook
test_missing_target_aborts_before_mutation
test_changed_target_sha_aborts_before_mutation
test_alternate_reachable_commit_with_same_subject_aborts
test_later_non_payload_commit_in_target_state_aborts
test_unreachable_target_aborts_before_mutation
test_dirty_repo_aborts_before_mutation
test_staging_smoke_failure_keeps_old_deploy_and_pending_state
test_invalid_shell_qml_fails_smoke_and_keeps_old_deploy
test_invalid_import_fails_smoke_and_keeps_old_deploy
test_bad_local_import_fails_smoke_and_keeps_old_deploy
test_missing_component_fails_smoke_and_keeps_old_deploy
test_qs_module_import_passes_smoke
test_qs_module_with_qmldir_smoke_does_not_execute_side_effect
test_qs_module_without_qmldir_fails_before_side_effect
test_manifest_does_not_restore_whole_systemd_wants_dir
test_companion_manifest_is_required
test_companion_failure_keeps_old_deploy_and_pending_state
test_companion_mutation_failure_restores_side_effect
test_hook_mutation_failure_restores_old_hook
test_companion_blacklist_side_effects_restore
test_companion_failure_restores_systemd_state
test_systemd_restore_happens_after_file_restore
test_systemd_commit_failure_keeps_pending_state

printf 'qs-shell-update regression tests passed\n'
