#!/usr/bin/env bash
# Pre-install security gate for the Quickshell Arch updater.
#
# stdin : one update candidate per line, pipe-separated:  pkg|repo|old|new
#         repo ∈ system|aur   (passed through from the widget's S|/A| prefix)
# stdout: one JSON object per line.
#         First line is meta:
#           {"meta":"gate","blacklist":N,"degraded":B,"list_date":"YYYY-MM-DD",
#            "stale":B,"mirrors_agree":B}
#         Then per package:    {"pkg","repo","old","new","verdict","reason"}
#           verdict ∈ OK | WARN | FAIL
#
# Pure function: reads only, installs nothing, needs no root, no jq, no eval.
set -uo pipefail

# Blacklist sources, merged as a union (an entry is never lost because one
# source lags behind the other):
#   1. plain list kept current by qs-aur-blacklist-fetch.sh (timer)
#   2. KNOWN_INFECTED array embedded in the Atomic Arch scanner script
PLAIN_LIST="${QS_AUR_BLACKLIST_LIST:-$HOME/.local/share/qs-aur-blacklist.txt}"
META="${QS_AUR_BLACKLIST_META:-$PLAIN_LIST.meta.json}"   # written by the fetcher
if [ -n "${QS_AUR_BLACKLIST:-}" ]; then
  BLACKLIST_SRC="$QS_AUR_BLACKLIST"
else
  BLACKLIST_SRC=""
  for _c in "$HOME/.local/share/check-atomic-arch.sh" "$HOME/Downloads/check-atomic-arch.sh"; do
    [ -r "$_c" ] && { BLACKLIST_SRC="$_c"; break; }
  done
fi
MIN_COUNT="${QS_GATE_MIN:-1500}"          # below this the blacklist is treated as degraded
STALE_DAYS="${QS_GATE_STALE_DAYS:-7}"     # list older than this ⇒ stale ⇒ degraded

# --- 1. Load blacklist WITHOUT eval --------------------------------------
# Script source: extract the body between `KNOWN_INFECTED=(` and the closing
# `)`, strip any quotes, split on whitespace, keep only valid pkgname tokens.
# Plain source: already one token per line, same charset filter. No execution.
declare -A INFECTED
load_local() {
  [ -r "$BLACKLIST_SRC" ] || return 0
  awk '/^KNOWN_INFECTED=\(/{f=1;next} /^[[:space:]]*\)/{f=0} f' "$BLACKLIST_SRC" \
    | tr -d '\042\047' \
    | tr ' \t' '\n\n' \
    | grep -E '^[a-zA-Z0-9][a-zA-Z0-9@._+-]*$'
}
load_plain() {
  [ -r "$PLAIN_LIST" ] || return 0
  grep -E '^[a-zA-Z0-9][a-zA-Z0-9@._+-]*$' "$PLAIN_LIST"
}
while read -r p; do [ -n "$p" ] && INFECTED["$p"]=1; done < <(load_plain; load_local)

# --- 2. Freshness + fetcher signals from the meta JSON (read-only, no jq) --
# Prefer the fetcher's content timestamp over file mtime: install/mv/post-update
# can reset mtime and thereby mask or fake staleness. Fall back to mtime only
# when no meta is present.
meta_updated=""; meta_degraded=false; meta_pending=false; mirrors_agree=false
if [ -r "$META" ]; then
  meta_raw="$(cat "$META" 2>/dev/null || true)"
  if [ -n "$meta_raw" ]; then
    meta_updated="$(printf '%s' "$meta_raw" | grep -oE '"updated_at":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')"
    printf '%s' "$meta_raw" | grep -qE '"degraded":[[:space:]]*true'       && meta_degraded=true
    printf '%s' "$meta_raw" | grep -qE '"pending_review":[[:space:]]*true' && meta_pending=true
    printf '%s' "$meta_raw" | grep -qE '"mirrors_agree":[[:space:]]*true'  && mirrors_agree=true
  fi
fi

# Resolve a freshness epoch: meta updated_at first, else newest source mtime.
src_epoch=""
if [ -n "$meta_updated" ]; then
  src_epoch="$(date -d "$meta_updated" +%s 2>/dev/null || true)"
fi
if [ -z "$src_epoch" ]; then
  for _f in "$PLAIN_LIST" "$BLACKLIST_SRC"; do
    [ -n "$_f" ] && [ -r "$_f" ] || continue
    _e="$(date -r "$_f" +%s 2>/dev/null)" || continue
    if [ -z "$src_epoch" ] || [ "$_e" -gt "$src_epoch" ]; then src_epoch="$_e"; fi
  done
fi
list_date=""; stale=false
if [ -n "$src_epoch" ]; then
  list_date="$(date -d "@$src_epoch" +%F 2>/dev/null || true)"
  now="$(date +%s)"
  [ $(( (now - src_epoch) / 86400 )) -gt "$STALE_DAYS" ] && stale=true
fi

# --- 3. Combine the degraded state (fail-closed) -------------------------
# ${#INFECTED[@]} on an empty assoc array trips `set -u` on bash < 4.4
set +u; blacklist_count=${#INFECTED[@]}; set -u
degraded=false
[ "$blacklist_count" -lt "$MIN_COUNT" ] && degraded=true   # too few names = weak protection
$meta_degraded && degraded=true                            # fetcher kept an old list / fetch failed
$meta_pending  && degraded=true                            # a large jump is quarantined, unadopted
$stale         && degraded=true                            # protection list is too old

# --- JSON emitter (printf-based, minimal escaping; no jq dependency) ------
jstr() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }
emit() { # pkg repo old new verdict reason
  printf '{"pkg":"%s","repo":"%s","old":"%s","new":"%s","verdict":"%s","reason":"%s"}\n' \
    "$(jstr "$1")" "$(jstr "$2")" "$(jstr "$3")" "$(jstr "$4")" "$5" "$(jstr "$6")"
}

# --- meta line first so the UI can show a degraded/limited-protection state
printf '{"meta":"gate","blacklist":%d,"degraded":%s,"list_date":"%s","stale":%s,"mirrors_agree":%s}\n' \
  "$blacklist_count" "$degraded" "$list_date" "$stale" "$mirrors_agree"

# --- 4. Classify each update candidate -----------------------------------
while IFS='|' read -r pkg repo old new || [ -n "$pkg" ]; do
  [ -n "$pkg" ] || continue
  # Not a valid pkgname (spaces, shell noise, broken framing) → skip the line.
  # The QML side counts answers vs. candidates and fail-closes on a mismatch.
  case "$pkg" in *[!a-zA-Z0-9@._+-]*) continue ;; esac
  [ "$repo" = "aur" ] || repo="system"

  if [ -n "${INFECTED[$pkg]:-}" ]; then
    emit "$pkg" "$repo" "$old" "$new" "FAIL" "On Atomic Arch known-infected list"
    continue
  fi

  if [ "$repo" = "aur" ]; then
    # AUR is the Atomic Arch entry vector (orphan takeover -> malicious PKGBUILD).
    # Not blocked, but flagged for a manual PKGBUILD look.
    emit "$pkg" "$repo" "$old" "$new" "WARN" "AUR package — review PKGBUILD before building"
  else
    emit "$pkg" "$repo" "$old" "$new" "OK" ""
  fi
done

exit 0
