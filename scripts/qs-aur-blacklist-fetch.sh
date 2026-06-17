#!/usr/bin/env bash
# Refreshes the AUR known-infected list for the updater's security gate.
#
# Source model (Atomic Arch incident, 2026-06):
#   PRIMARY  = the maintained community list (cscs paste).
#   MIRROR   = the SAME list on a second host (md.archlinux.org / HedgeDoc),
#              used only as a transport/tamper cross-check and as a fallback if
#              the primary is unreachable — NOT as an independent corroboration.
#   SECONDARY= a smaller subset (quanten gist), best-effort, union-merged for
#              resilience only.
# Entries in the local supplement (qs-aur-blacklist.local.txt) are union-merged
# into every refresh, so ad-hoc additions survive the periodic overwrite.
#
# Fail-closed: any fetch/validation failure keeps the previous list and exits
# nonzero; the meta is written degraded so the gate/UI never shows false-green.
# A suspicious jump (> growth cap) is quarantined to $DEST.pending for review
# instead of being adopted silently. Atomic writes only (tmp + mv, same FS).
set -uo pipefail

DEST="${QS_AUR_BLACKLIST_LIST:-$HOME/.local/share/qs-aur-blacklist.txt}"
LOCAL="${QS_AUR_BLACKLIST_LOCAL:-$HOME/.local/share/qs-aur-blacklist.local.txt}"
META="${QS_AUR_BLACKLIST_META:-$DEST.meta.json}"
MIN_PRIMARY="${QS_GATE_MIN:-1500}"            # remote primary must carry at least this many names
MAX_COUNT="${QS_GATE_MAX:-10000}"             # an absurdly large feed is itself suspicious
MAX_DROP_PCT="${QS_GATE_MAX_DROP_PCT:-20}"    # > this % shrink vs last good list → keep old
MAX_GROWTH="${QS_GATE_MAX_GROWTH:-1000}"      # > this many net-new names → quarantine as .pending

# Single overridable URL per tier (env hooks make testing / future swaps clean).
PRIMARY_URLS=("${QS_AUR_PRIMARY_URL:-https://cscs.pastes.sh/raw/aurvulnlist20260611.txt}")
MIRROR_URLS=("${QS_AUR_MIRROR_URL:-https://md.archlinux.org/s/SxbqukK6IA/download}")
SECONDARY_URLS=("${QS_AUR_SECONDARY_URL:-https://gist.githubusercontent.com/quantenProjects/3f768dce7331618310f016d975bf8547/raw/packages}")

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT

# stdin → normalized package-name tokens. Strips quotes AND backticks (the md
# mirror wraps the list in a markdown code fence), splits on whitespace/commas,
# keeps only valid pacman pkgname tokens, dedups.
sanitize() {
  tr -d '\042\047\140' | tr ' \t,' '\n\n\n' \
    | grep -E '^[a-zA-Z0-9][a-zA-Z0-9@._+-]*$' | sort -u
}
fetch() {  # url outfile → 0 ok / 1 fail
  if command -v curl >/dev/null 2>&1; then curl -sfL --max-time 30 "$1" -o "$2" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" --timeout=30 "$1" 2>/dev/null
  else return 1; fi
}
count() { local n; n="$(grep -c . "$1" 2>/dev/null)"; echo "${n:-0}"; }

write_meta() {  # total primary mirrors_agree degraded pending
  local mtmp; mtmp="$(mktemp "${META}.XXXXXX")" || return 1
  printf '{"updated_at":"%s","total_count":%s,"primary_count":%s,"mirrors_agree":%s,"degraded":%s,"pending_review":%s}\n' \
    "$(date -Iseconds)" "${1:-0}" "${2:-0}" "${3:-false}" "${4:-false}" "${5:-false}" > "$mtmp" \
    || { rm -f "$mtmp"; return 1; }
  chmod 644 "$mtmp"; mv -f "$mtmp" "$META"      # same dir as DEST ⇒ atomic
}
keep_old() {  # reason — refresh degraded meta, keep existing list, exit 1
  echo "qs-aur-blacklist-fetch: $1 — keeping previous list" >&2
  write_meta "$(count "$DEST")" 0 false true false || true
  exit 1
}

# --- 1. primary -----------------------------------------------------------
primary_ok=false
for u in "${PRIMARY_URLS[@]}"; do
  fetch "$u" "$tmpd/p.raw" && { sanitize < "$tmpd/p.raw" > "$tmpd/primary"; primary_ok=true; break; }
done
# --- 2. mirror (cross-check + fallback) -----------------------------------
mirror_ok=false; mirrors_agree=false
for u in "${MIRROR_URLS[@]}"; do
  fetch "$u" "$tmpd/m.raw" && { sanitize < "$tmpd/m.raw" > "$tmpd/mirror"; mirror_ok=true; break; }
done
# --- choose the trusted remote base ---------------------------------------
if $primary_ok; then
  cp "$tmpd/primary" "$tmpd/base"
  if $mirror_ok && cmp -s "$tmpd/primary" "$tmpd/mirror"; then mirrors_agree=true; fi
elif $mirror_ok; then
  echo "qs-aur-blacklist-fetch: primary unreachable — falling back to mirror" >&2
  cp "$tmpd/mirror" "$tmpd/base"
else
  keep_old "all primary/mirror downloads failed"
fi
primary_count="$(count "$tmpd/base")"

# --- 3. validate the REMOTE base BEFORE unioning local data ---------------
[ "$primary_count" -lt "$MIN_PRIMARY" ] && keep_old "remote feed too short ($primary_count < $MIN_PRIMARY)"
[ "$primary_count" -gt "$MAX_COUNT" ]   && keep_old "remote feed implausibly large ($primary_count > $MAX_COUNT)"

# --- 4. union secondary (best-effort) + local supplement → candidate ------
cp "$tmpd/base" "$tmpd/cand"
for u in "${SECONDARY_URLS[@]}"; do
  fetch "$u" "$tmpd/s.raw" && sanitize < "$tmpd/s.raw" >> "$tmpd/cand"
done
sup_count=0
if [ -s "$LOCAL" ]; then
  sanitize < "$LOCAL" > "$tmpd/sup"; sup_count="$(count "$tmpd/sup")"
  cat "$tmpd/sup" >> "$tmpd/cand"
fi
sort -u "$tmpd/cand" -o "$tmpd/cand"
new_count="$(count "$tmpd/cand")"

# --- 5. delta protection vs the current good list -------------------------
old_count="$(count "$DEST")"
if [ "$old_count" -gt 0 ]; then
  if [ $(( new_count * 100 )) -lt $(( old_count * (100 - MAX_DROP_PCT) )) ]; then
    keep_old "new list shrinks too far ($new_count vs $old_count, >${MAX_DROP_PCT}% drop)"
  fi
  if [ "$new_count" -gt $(( old_count + MAX_GROWTH )) ]; then
    ptmp="$(mktemp "$DEST.pending.XXXXXX")" && { cp "$tmpd/cand" "$ptmp"; chmod 644 "$ptmp"; mv -f "$ptmp" "$DEST.pending"; }
    echo "qs-aur-blacklist-fetch: +$(( new_count - old_count )) names exceeds growth cap ($MAX_GROWTH) → wrote $DEST.pending for review, keeping previous list" >&2
    write_meta "$old_count" "$primary_count" "$mirrors_agree" true true || true
    exit 1
  fi
fi

# --- 6. adopt atomically + write fresh meta -------------------------------
mkdir -p "$(dirname "$DEST")"
tmp="$(mktemp "$DEST.XXXXXX")" || exit 1
cp "$tmpd/cand" "$tmp" || { rm -f "$tmp"; exit 1; }
chmod 644 "$tmp"
mv -f "$tmp" "$DEST"     # same dir ⇒ atomic rename
rm -f "$DEST.pending"    # a clean adoption clears any stale quarantine
write_meta "$new_count" "$primary_count" "$mirrors_agree" false false || true
echo "qs-aur-blacklist-fetch: $new_count packages → $DEST (primary $primary_count, mirrors_agree=$mirrors_agree, supplement $sup_count)"
