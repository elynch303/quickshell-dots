#!/usr/bin/env bash
# Refreshes the AUR known-infected list for the updater's security gate.
# Pulls the maintained (unpinned) Atomic Arch package list, validates it and
# atomically replaces ~/.local/share/qs-aur-blacklist.txt.
# Fail-closed: any fetch/validation error keeps the previous list and exits
# nonzero — the gate then keeps working from the last good copy.
set -uo pipefail

DEST="${QS_AUR_BLACKLIST_LIST:-$HOME/.local/share/qs-aur-blacklist.txt}"
MIN_COUNT="${QS_GATE_MIN:-100}"   # a "list" below this is treated as bogus
URLS=(
  "https://gist.githubusercontent.com/quantenProjects/3f768dce7331618310f016d975bf8547/raw/packages"
)

raw="$(mktemp)"; trap 'rm -f "$raw"' EXIT
ok=false
for url in "${URLS[@]}"; do
  if command -v curl >/dev/null 2>&1; then
    curl -sfL --max-time 30 "$url" -o "$raw" 2>/dev/null && { ok=true; break; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$raw" --timeout=30 "$url" 2>/dev/null && { ok=true; break; }
  fi
done
$ok || { echo "qs-aur-blacklist-fetch: download failed — keeping previous list" >&2; exit 1; }

# Sanitize hard: only valid pacman package-name tokens survive, one per line,
# deduped. Anything else in the payload (markup, commands, garbage) is dropped.
clean="$(tr -d '\042\047' < "$raw" | tr ' \t,' '\n\n\n' \
         | grep -E '^[a-zA-Z0-9][a-zA-Z0-9@._+-]*$' | sort -u)"
count="$(printf '%s\n' "$clean" | grep -c . || true)"
if [ "$count" -lt "$MIN_COUNT" ]; then
  echo "qs-aur-blacklist-fetch: list too short ($count < $MIN_COUNT) — keeping previous list" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
tmp="$(mktemp "$DEST.XXXXXX")" || exit 1
printf '%s\n' "$clean" > "$tmp" || { rm -f "$tmp"; exit 1; }
chmod 644 "$tmp"
mv -f "$tmp" "$DEST"   # same directory ⇒ atomic rename
echo "qs-aur-blacklist-fetch: $count packages → $DEST"
