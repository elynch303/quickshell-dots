#!/usr/bin/env bash
# 1) live-reload the bar's theme colors
qs -c bar ipc call theme reload >/dev/null 2>&1 || true

bg="$HOME/.config/omarchy/current/theme/backgrounds"

# 2) pre-generate the wallpaper SCAN CACHE for the freshly-switched theme.
#    Byte-identical to ImageCarouselPanel.qml buildScanCmd() (wallpaper branch):
#      find -L .../current/theme/backgrounds … | sort | while read f; printf '%s\t%s\n' f f
#    → first picker open hits a fresh, correct cache (instant paint); the parallel
#      live-scan returns the same text and no-ops via the _lastScan compare. No
#      stale-flash of the previous theme, no reload cycle.
#    ⚠️ DRIFT: must stay identical to that QML branch — change both together.
C="$HOME/.cache/quickshell-scan-wallpaper"
find -L "$bg" -maxdepth 1 -type f \
     \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
     2>/dev/null | sort | while read f; do printf '%s\t%s\n' "$f" "$f"; done > "$C.tmp" \
  && mv -f "$C.tmp" "$C"
# theme sidecar stamp — prepares Schicht 2 (cache validation); inert until QML reads it.
# Canonical theme id: theme.name on this machine (current/theme is a real copy); fall
# back to the symlink basename on upstream omarchy (where current/theme IS a symlink to
# the theme dir). Keeps the stamp canonical on both layouts.
{ cat "$HOME/.config/omarchy/current/theme.name" 2>/dev/null \
    || basename "$(readlink "$HOME/.config/omarchy/current/theme" 2>/dev/null)"; } \
    > "$C.theme" 2>/dev/null || true

# NOTE: an on-switch thumbnail pre-warm used to live here. Removed deliberately —
# it ran concurrently with the user opening the picker and STOLE cores from the
# picker's own on-demand thumbnailer (ImageCarouselPanel.ensureThumb, nice -10),
# making the first open SLOWER, not faster. Measured: opening 11×8K tiles took
# 2110ms with no warm vs 2713ms while a gentle -P3 warm ran. ensureThumb already
# generates exactly the visible tiles with full core headroom, so any background
# warm here is net-negative. The real fix for cold-theme decode cost is an IDLE
# global pre-warm (all themes, -P nproc, when nothing else runs) — not on-switch.
