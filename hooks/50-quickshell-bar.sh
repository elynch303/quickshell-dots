#!/usr/bin/env bash
# 1) live-reload the bar's theme colors
qs -c bar ipc call theme reload >/dev/null 2>&1 || true

bg="$HOME/.config/omarchy/current/theme/backgrounds"

# 2) pre-generate the wallpaper scan cache for the freshly switched theme.
#    This must match the image picker wallpaper scan contract:
#      source_path<TAB>content-addressed_512px_thumbnail_path
#    The content hash is stable across Omarchy's current/theme copy mtimes, so
#    switching A -> B -> A can reuse already generated thumbnails.
C="$HOME/.cache/quickshell-scan-wallpaper"
D="$HOME/.cache/quickshell-img-thumbs"
mkdir -p "$D"
find -L "$bg" -maxdepth 1 -type f \
     \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
     2>/dev/null | sort | while IFS= read -r f; do
       k=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1) || continue
       [ -n "$k" ] || continue
       printf '%s\t%s/%s-512.jpg\n' "$f" "$D" "$k"
     done > "$C.tmp" \
  && mv -f "$C.tmp" "$C"
# theme sidecar stamp — prepares Schicht 2 (cache validation); inert until QML reads it.
# Canonical theme id: theme.name on this machine (current/theme is a real copy); fall
# back to the symlink basename on upstream omarchy (where current/theme IS a symlink to
# the theme dir). Keeps the stamp canonical on both layouts.
{ cat "$HOME/.config/omarchy/current/theme.name" 2>/dev/null \
    || basename "$(readlink "$HOME/.config/omarchy/current/theme" 2>/dev/null)"; } \
    > "$C.theme" 2>/dev/null || true

# NOTE: thumbnail generation remains in the picker warm path. The hook only
# writes deterministic scan metadata so the first open after a theme switch does
# not show a stale previous-theme cache.
