#!/usr/bin/env bash
# Pre-install security gate for the Quickshell Arch updater.
#
# stdin : one update candidate per line, pipe-separated:  pkg|repo|old|new
#         repo ∈ system|aur   (passed through from the widget's S|/A| prefix)
# stdout: one JSON object per line.
#         First line is meta:  {"meta":"gate","blacklist":N,"degraded":B,"list_date":"YYYY-MM-DD"}
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
if [ -n "${QS_AUR_BLACKLIST:-}" ]; then
  BLACKLIST_SRC="$QS_AUR_BLACKLIST"
else
  BLACKLIST_SRC=""
  for _c in "$HOME/.local/share/check-atomic-arch.sh" "$HOME/Downloads/check-atomic-arch.sh"; do
    [ -r "$_c" ] && { BLACKLIST_SRC="$_c"; break; }
  done
fi
MIN_COUNT="${QS_GATE_MIN:-100}"   # below this the blacklist is treated as degraded

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

# Newest mtime among the sources actually readable = how fresh the protection is.
list_date=""
for _f in "$PLAIN_LIST" "$BLACKLIST_SRC"; do
  [ -n "$_f" ] && [ -r "$_f" ] || continue
  _d="$(date -r "$_f" +%F 2>/dev/null)" || continue
  if [ -z "$list_date" ] || [ "$_d" \> "$list_date" ]; then list_date="$_d"; fi
done

# ${#INFECTED[@]} on an empty assoc array trips `set -u` on bash < 4.4
set +u; blacklist_count=${#INFECTED[@]}; set -u
degraded=false
[ "$blacklist_count" -lt "$MIN_COUNT" ] && degraded=true

# --- JSON emitter (printf-based, minimal escaping; no jq dependency) ------
jstr() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }
emit() { # pkg repo old new verdict reason
  printf '{"pkg":"%s","repo":"%s","old":"%s","new":"%s","verdict":"%s","reason":"%s"}\n' \
    "$(jstr "$1")" "$(jstr "$2")" "$(jstr "$3")" "$(jstr "$4")" "$5" "$(jstr "$6")"
}

# --- meta line first so the UI can show a degraded/limited-protection state
printf '{"meta":"gate","blacklist":%d,"degraded":%s,"list_date":"%s"}\n' \
  "$blacklist_count" "$degraded" "$list_date"

# --- 2. Classify each update candidate -----------------------------------
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
