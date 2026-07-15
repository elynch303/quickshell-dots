#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${CHECK:-$REPO_ROOT/scripts/qs-theme-update-check.sh}"
APPLY="${APPLY:-$REPO_ROOT/scripts/qs-theme-apply-update.sh}"
HOOK="${HOOK:-$REPO_ROOT/hooks/50-quickshell-bar.sh}"
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
  grep -Fq -- "$needle" "$file" || fail "$msg: missing '$needle'"
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

run_check_default_current() {
  local root="$1"
  shift
  QS_THEMES_DIR="$root/themes" \
  QS_THEME_STATE="$root/state.json" \
  QS_THEME_LOCK="$root/lock" \
  QS_THEME_TIMEOUT=3 \
  QS_THEME_FETCH_TIMEOUT=5 \
  HOME="$root/home" \
  PATH="$root/bin:$PATH" \
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
  assert_eq true "$(jq -r '.themes[0].current' "$root/state.json")" "QS_CURRENT_FILE override marks current theme"
  local target
  target="$(jq -r '.themes[0].targetCommit' "$root/state.json")"

  run_apply "$root" "$name" >/dev/null
  assert_eq "$target" "$(git -C "$root/themes/$name" rev-parse HEAD)" "apply installed saved target"
}

write_test_images() {
  local dir="$1"
  mkdir -p "$dir"
  printf 'one\n' > "$dir/one.jpg"
  printf 'two\n' > "$dir/two.png"
  printf 'three\n' > "$dir/three.webp"
  printf 'four\n' > "$dir/four.bmp"
  printf 'five\n' > "$dir/five.gif"
}

prepare_hook_home() {
  local root="$1"
  mkdir -p "$root/home/.cache" "$root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/qs"
  chmod +x "$root/bin/qs"
}

run_hook_fixture() {
  local root="$1"
  HOME="$root/home" PATH="$root/bin:$PATH" "$HOOK"
}

test_hook_legacy_current_root_writes_cache() {
  local root="$WORK/hook-legacy"
  prepare_hook_home "$root"
  mkdir -p "$root/home/.config/omarchy/current"
  printf 'legacy-theme\n' > "$root/home/.config/omarchy/current/theme.name"
  write_test_images "$root/home/.config/omarchy/current/theme/backgrounds"

  run_hook_fixture "$root"

  assert_eq 5 "$(wc -l < "$root/home/.cache/quickshell-scan-wallpaper" | tr -d '[:space:]')" "legacy hook cache line count"
  assert_eq 5 "$(awk -F '\t' '$1 ~ /\.config\/omarchy\/current\/theme\/backgrounds\// && $2 ~ /\/\.cache\/quickshell-img-thumbs\/[0-9a-f]{64}-512\.jpg$/ { n++ } END { print n + 0 }' "$root/home/.cache/quickshell-scan-wallpaper")" "legacy hook cache paths"
  assert_eq legacy-theme "$(tr -d '[:space:]' < "$root/home/.cache/quickshell-scan-wallpaper.theme")" "legacy hook theme stamp"
}

test_hook_omarchy4_current_root_writes_cache() {
  local root="$WORK/hook-omarchy4"
  prepare_hook_home "$root"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/omarchy-shell"
  chmod +x "$root/bin/omarchy-shell"
  mkdir -p "$root/home/.local/state/omarchy/current" "$root/home/.config/omarchy/current/theme/backgrounds"
  printf 'omarchy4-theme\n' > "$root/home/.local/state/omarchy/current/theme.name"
  printf 'legacy\n' > "$root/home/.config/omarchy/current/theme/backgrounds/legacy.jpg"
  write_test_images "$root/home/.local/state/omarchy/current/theme/backgrounds"

  run_hook_fixture "$root"

  assert_eq 5 "$(wc -l < "$root/home/.cache/quickshell-scan-wallpaper" | tr -d '[:space:]')" "omarchy4 hook cache line count"
  assert_eq 5 "$(awk -F '\t' '$1 ~ /\.local\/state\/omarchy\/current\/theme\/backgrounds\// && $2 ~ /\/\.cache\/quickshell-img-thumbs\/[0-9a-f]{64}-512\.jpg$/ { n++ } END { print n + 0 }' "$root/home/.cache/quickshell-scan-wallpaper")" "omarchy4 hook cache paths"
  assert_eq omarchy4-theme "$(tr -d '[:space:]' < "$root/home/.cache/quickshell-scan-wallpaper.theme")" "omarchy4 hook theme stamp"
}

test_hook_omarchy4_combines_theme_and_user_backgrounds() {
  local root="$WORK/hook-omarchy4-combined"
  prepare_hook_home "$root"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/omarchy-shell"
  chmod +x "$root/bin/omarchy-shell"
  mkdir -p "$root/home/.local/state/omarchy/current"
  printf 'combined-theme\n' > "$root/home/.local/state/omarchy/current/theme.name"
  write_test_images "$root/home/.local/state/omarchy/current/theme/backgrounds"
  write_test_images "$root/home/.config/omarchy/backgrounds/combined-theme"

  run_hook_fixture "$root"

  local cache="$root/home/.cache/quickshell-scan-wallpaper"
  assert_eq 10 "$(wc -l < "$cache" | tr -d '[:space:]')" "combined hook cache line count"
  assert_eq 5 "$(awk -F '\t' '$1 ~ /\.local\/state\/omarchy\/current\/theme\/backgrounds\// { n++ } END { print n + 0 }' "$cache")" "combined hook theme paths"
  assert_eq 5 "$(awk -F '\t' '$1 ~ /\.config\/omarchy\/backgrounds\/combined-theme\// { n++ } END { print n + 0 }' "$cache")" "combined hook user paths"
}

test_hook_omarchy4_accepts_user_backgrounds_without_theme_directory() {
  local root="$WORK/hook-omarchy4-user-only"
  prepare_hook_home "$root"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/omarchy-shell"
  chmod +x "$root/bin/omarchy-shell"
  mkdir -p "$root/home/.local/state/omarchy/current"
  printf 'user-theme\n' > "$root/home/.local/state/omarchy/current/theme.name"
  write_test_images "$root/home/.config/omarchy/backgrounds/user-theme"

  run_hook_fixture "$root"

  local cache="$root/home/.cache/quickshell-scan-wallpaper"
  assert_eq 5 "$(wc -l < "$cache" | tr -d '[:space:]')" "user-only hook cache line count"
  assert_eq 5 "$(awk -F '\t' '$1 ~ /\.config\/omarchy\/backgrounds\/user-theme\// { n++ } END { print n + 0 }' "$cache")" "user-only hook paths"
}

test_hook_without_valid_root_keeps_existing_cache() {
  local root="$WORK/hook-no-root"
  prepare_hook_home "$root"
  printf 'SENTINEL\n' > "$root/home/.cache/quickshell-scan-wallpaper"
  printf 'SENTINEL-THEME\n' > "$root/home/.cache/quickshell-scan-wallpaper.theme"

  run_hook_fixture "$root"

  assert_eq SENTINEL "$(tr -d '\n' < "$root/home/.cache/quickshell-scan-wallpaper")" "hook no-root preserves cache"
  assert_eq SENTINEL-THEME "$(tr -d '\n' < "$root/home/.cache/quickshell-scan-wallpaper.theme")" "hook no-root preserves stamp"
}

test_default_current_file_prefers_omarchy4_state() {
  local root="$WORK/default-current-omarchy4" name="demo"
  init_fixture "$root" "$name"
  printf 'v2\n' > "$root/seed/base.txt"
  git -C "$root/seed" commit -am update-v2 >/dev/null
  git -C "$root/seed" push origin main >/dev/null 2>&1
  mkdir -p "$root/home/.local/state/omarchy/current" "$root/home/.config/omarchy/current" "$root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/omarchy-shell"
  chmod +x "$root/bin/omarchy-shell"
  printf '%s\n' "$name" > "$root/home/.local/state/omarchy/current/theme.name"
  printf 'not-current\n' > "$root/home/.config/omarchy/current/theme.name"

  run_check_default_current "$root"

  assert_eq true "$(jq -r '.themes[0].current' "$root/state.json")" "default current file prefers omarchy4 state"
}

test_default_current_file_uses_legacy_path() {
  local root="$WORK/default-current-legacy" name="demo"
  init_fixture "$root" "$name"
  printf 'v2\n' > "$root/seed/base.txt"
  git -C "$root/seed" commit -am update-v2 >/dev/null
  git -C "$root/seed" push origin main >/dev/null 2>&1
  mkdir -p "$root/home/.config/omarchy/current" "$root/bin"
  printf '%s\n' "$name" > "$root/home/.config/omarchy/current/theme.name"

  run_check_default_current "$root"

  assert_eq true "$(jq -r '.themes[0].current' "$root/state.json")" "default current file uses legacy path"
}

test_palette_alias_contract_is_present() {
  local p="$REPO_ROOT/versions/V1/Palette.js"
  assert_contains 'keys: ["background", "bg"]' "$p" "palette background alias"
  assert_contains 'keys: ["foreground", "fg"]' "$p" "palette foreground alias"
  assert_contains 'keys: ["color1", "red"]' "$p" "palette red alias"
  assert_contains 'keys: ["color2", "green"]' "$p" "palette green alias"
  assert_contains 'keys: ["color3", "yellow"]' "$p" "palette yellow alias"
  assert_contains 'validColor(value)' "$p" "palette valid color gate"
}

test_theme_apply_exports_omarchy_path() {
  local theme="$REPO_ROOT/versions/V1/Theme.qml"
  local updater="$REPO_ROOT/versions/V1/panels/ArchUpdaterPanel.qml"
  local postboot="$REPO_ROOT/contrib/post-boot.d/quickshell-rise"
  local picker_count

  assert_contains 'property string omarchyInstallRoot:' "$theme" "theme install root property"
  assert_contains '/usr/share/omarchy' "$theme" "omarchy4 install root"
  picker_count="$(grep -RFl '["env", "OMARCHY_PATH=" + root.omarchyInstallRoot, "omarchy-theme-set", name]' \
    "$REPO_ROOT/versions/V1/panels/ImageCarouselPanel.qml" \
    "$REPO_ROOT/versions/V1/panels/ImageCarouselCarousel.qml" \
    "$REPO_ROOT/versions/V1/panels/ImageCarouselHearthstone.qml" | wc -l | tr -d '[:space:]')"
  assert_eq 3 "$picker_count" "all image pickers pass OMARCHY_PATH to omarchy-theme-set"
  assert_contains 'OMARCHY_PATH=' "$updater" "theme reapply passes OMARCHY_PATH"
  assert_contains 'export OMARCHY_PATH=/usr/share/omarchy' "$postboot" "post-boot omarchy4 export"
  assert_contains "export OMARCHY_PATH=\"\$HOME/.local/share/omarchy\"" "$postboot" "post-boot legacy export"
}

test_theme_change_watcher_contract_is_present() {
  local theme="$REPO_ROOT/versions/V1/Theme.qml"
  local block

  block="$(sed -n '/id: currentThemeNameWatcher/,/^    }/p' "$theme")"
  [[ $block == *'path: theme.themeNamePath'* ]] || fail "theme watcher does not use the resolved theme.name path"
  [[ $block == *'watchChanges: theme.omarchyCurrentRootResolved'* ]] || fail "theme watcher is not gated by current-root resolution"
  [[ $block == *'theme.reloadCurrentThemeFiles()'* ]] || fail "theme watcher does not schedule a palette reload"
  assert_contains 'id: themeReloadDebounce' "$theme" "theme reload debounce"
}

test_image_picker_entry_contract_is_centralized() {
  local theme="$REPO_ROOT/versions/V1/Theme.qml"
  local widget="$REPO_ROOT/versions/V1/modules/ThemeDisplayWidget.qml"

  assert_contains 'function openImagePicker(mode, screen)' "$theme" "screen-aware image picker entry"
  assert_contains 'function toggleImagePicker(mode, screen)' "$theme" "image picker toggle entry"
  assert_contains 'imagePickerVisible && imagePickerMode === mode' "$theme" "same-mode picker toggle closes"
  assert_contains 'imagePickerVisible && imagePickerMode !== mode' "$theme" "cross-mode picker reset"
  assert_contains 'rootMod.root.toggleImagePicker(' "$widget" "theme widget uses centralized picker entry"

  if grep -Eq 'root\.(imagePickerMode|imagePickerVisible)[[:space:]]*=' "$widget"; then
    fail "theme widget still mutates picker state directly"
  fi
}

test_wallpaper_source_contract_is_shared() {
  local theme="$REPO_ROOT/versions/V1/Theme.qml"
  local pickers=(
    "$REPO_ROOT/versions/V1/panels/ImageCarouselPanel.qml"
    "$REPO_ROOT/versions/V1/panels/ImageCarouselCarousel.qml"
    "$REPO_ROOT/versions/V1/panels/ImageCarouselHearthstone.qml"
  )
  local picker
  local dollar='$'

  assert_contains 'readonly property var wallpaperSourcePaths:' "$theme" "central wallpaper source list"
  assert_contains '/.config/omarchy/backgrounds/' "$theme" "omarchy user backgrounds root"
  assert_contains 'currentThemeNameWatcher.reload()' "$theme" "theme name reload after current-root resolution"
  for picker in "${pickers[@]}"; do
    assert_contains 'root.wallpaperSourcePaths' "$picker" "picker uses central wallpaper sources"
    assert_contains "-iname '*.bmp'" "$picker" "picker supports bmp wallpapers"
    assert_contains "-iname '*.gif'" "$picker" "picker supports gif wallpapers"
    assert_contains "magick \\\"${dollar}0[0]\\\"" "$picker" "picker thumbnails only the first image frame"
  done
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
test_hook_legacy_current_root_writes_cache
test_hook_omarchy4_current_root_writes_cache
test_hook_omarchy4_combines_theme_and_user_backgrounds
test_hook_omarchy4_accepts_user_backgrounds_without_theme_directory
test_hook_without_valid_root_keeps_existing_cache
test_default_current_file_prefers_omarchy4_state
test_default_current_file_uses_legacy_path
test_palette_alias_contract_is_present
test_theme_apply_exports_omarchy_path
test_theme_change_watcher_contract_is_present
test_image_picker_entry_contract_is_centralized
test_wallpaper_source_contract_is_shared
test_ignored_untracked_collision_blocks_check_and_apply
test_ignored_file_blocks_incoming_subpath
test_ignored_subpath_blocks_incoming_file
test_apply_aborts_when_check_lock_is_held

printf 'qs-theme-update regression tests passed\n'
