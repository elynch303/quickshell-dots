#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_USAGE="${CODEX_USAGE:-$REPO_ROOT/scripts/codex-usage}"
WORK="$(mktemp -d /tmp/qs-codex-usage-test.XXXXXX)"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

run_usage() {
  local root="$1" json="$2" now="$3"
  CODEX_HOME="$root/codex" \
  CODEX_USAGE_CACHE_FILE="$root/cache.json" \
  CODEX_USAGE_ACTIVITY_FILE="$root/activity.json" \
  CODEX_USAGE_DISABLE_RPC=1 \
  CODEX_USAGE_RATE_LIMITS_JSON="$json" \
  CODEX_USAGE_NOW="$now" \
  TZ=Europe/Berlin \
    "$CODEX_USAGE"
}

assert_cache() {
  local file="$1" script="$2"
  python - "$file" "$script" <<'PY'
import json, sys
path, code = sys.argv[1], sys.argv[2]
with open(path) as fh:
    data = json.load(fh)
ns = {"data": data}
try:
    exec(code, ns, ns)
except AssertionError as e:
    raise SystemExit(f"assertion failed: {e}")
PY
}

write_token_event() {
  local file="$1" ts="$2" total="$3"
  mkdir -p "$(dirname "$file")"
  printf '{"timestamp":"%s","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":%s},"last_token_usage":{"total_tokens":123}}}}\n' "$ts" "$total" >> "$file"
}

write_rate_limit_event() {
  local file="$1" ts="$2" used="$3" reset="$4"
  mkdir -p "$(dirname "$file")"
  printf '{"type":"event_msg","timestamp":"%s","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","plan_type":"prolite","primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"secondary":null}}}\n' "$ts" "$used" "$reset" >> "$file"
}

write_rate_limit_event_without_id() {
  local file="$1" ts="$2" used="$3" reset="$4"
  mkdir -p "$(dirname "$file")"
  printf '{"type":"event_msg","timestamp":"%s","payload":{"type":"token_count","rate_limits":{"plan_type":"prolite","primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"secondary":null}}}\n' "$ts" "$used" "$reset" >> "$file"
}

test_general_weekly_and_spark_bucket() {
  local root="$WORK/buckets"
  mkdir -p "$root/codex/sessions"
  run_usage "$root" '{"rateLimits":{"limitId":"codex","planType":"prolite","primary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":1784488047},"secondary":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","planType":"prolite","primary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":1784488047},"secondary":null},"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1784568335},"secondary":null}}}' 1783965600
  assert_cache "$root/cache.json" '
assert data["schemaVersion"] == 3
assert [b["id"] for b in data["buckets"]] == ["codex", "codex_bengalfox"]
assert data["buckets"][0]["isGeneral"] is True
assert data["buckets"][0]["label"] == "Codex"
assert data["buckets"][0]["windows"][0]["label"] == "Weekly"
assert data["buckets"][0]["windows"][0]["minutes"] == 10080
assert data["buckets"][0]["windows"][0]["utilization"] == 0.1
assert data["buckets"][1]["isGeneral"] is False
assert data["buckets"][1]["label"] == "GPT-5.3-Codex-Spark"
assert data["windows"] == data["buckets"][0]["windows"]
assert data["5h-utilization"] == ""
assert data["5h-reset"] == ""
assert data["7d-utilization"] == "0.1000"
assert data["7d-reset"] == "1784488047"
assert data["_quota_bucket"] == "Codex"
assert data["_quota_window"] == "Weekly"
assert "_window_limit" not in data
assert "_tokens_used" not in data
'
}

test_general_primary_and_secondary_windows() {
  local root="$WORK/two-windows"
  mkdir -p "$root/codex/sessions"
  run_usage "$root" '{"plan_type":"pro","primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1784000000},"secondary":{"usedPercent":91,"windowDurationMins":10080,"resetsAt":1784500000}}' 1783965600
  assert_cache "$root/cache.json" '
assert data["schemaVersion"] == 3
assert len(data["buckets"]) == 1
assert data["buckets"][0]["id"] == "codex"
assert [w["label"] for w in data["windows"]] == ["5h", "Weekly"]
assert data["5h-utilization"] == "0.2000"
assert data["7d-utilization"] == "0.9100"
assert data["status"] == "allowed_warning"
assert data["_quota_bucket"] == "Codex"
assert data["_quota_window"] == "Weekly"
'
}

test_unknown_window_does_not_pollute_legacy_fields() {
  local root="$WORK/unknown"
  mkdir -p "$root/codex/sessions"
  run_usage "$root" '{"primary":{"usedPercent":33,"windowDurationMins":1234,"resetsAt":1784012345},"secondary":null}' 1783965600
  assert_cache "$root/cache.json" '
assert data["schemaVersion"] == 3
assert len(data["buckets"]) == 1
assert data["windows"][0]["label"] == "1234m"
assert data["5h-utilization"] == ""
assert data["7d-utilization"] == ""
'
}

test_null_rate_limits_by_id_falls_back_to_rate_limits() {
  local root="$WORK/null-by-id"
  mkdir -p "$root/codex/sessions"
  run_usage "$root" '{"rateLimits":{"limitId":"codex","planType":"plus","primary":{"usedPercent":55,"windowDurationMins":10080,"resetsAt":1784488047},"secondary":null},"rateLimitsByLimitId":null}' 1783965600
  assert_cache "$root/cache.json" '
assert data["schemaVersion"] == 3
assert len(data["buckets"]) == 1
assert data["buckets"][0]["id"] == "codex"
assert data["buckets"][0]["isGeneral"] is True
assert data["windows"][0]["utilization"] == 0.55
assert data["7d-utilization"] == "0.5500"
'
}

test_session_log_supplements_missing_general_5h() {
  local root="$WORK/session-supplement"
  local file="$root/codex/sessions/2026/07/13/session.jsonl"
  write_rate_limit_event "$file" "2026-07-13T18:00:00Z" 42 1783979000
  run_usage "$root" '{"rateLimits":{"limitId":"codex","planType":"prolite","primary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":1784488047},"secondary":null},"rateLimitsByLimitId":null}' 1783965600
  assert_cache "$root/cache.json" '
assert [w["label"] for w in data["windows"]] == ["5h", "Weekly"]
assert data["windows"][0]["source"] == "session"
assert data["5h-utilization"] == "0.4200"
assert data["5h-reset"] == "1783979000"
assert data["7d-utilization"] == "0.1100"
assert data["_quota_bucket"] == "Codex"
assert data["_quota_window"] == "5h"
assert data["status"] == "allowed"
'
}

test_session_supplement_rejects_noncanonical_and_implausible_5h() {
  local root="$WORK/session-rejects"
  local file="$root/codex/sessions/2026/07/13/session.jsonl"
  write_rate_limit_event_without_id "$file" "2026-07-13T20:00:00Z" 88 1783979000
  write_rate_limit_event "$file" "2026-07-13T20:01:00Z" 93 0
  write_rate_limit_event "$file" "2026-07-13T20:02:00Z" 94 1783960000
  write_rate_limit_event "$file" "2026-07-13T20:03:00Z" 95 1785000000
  run_usage "$root" '{"rateLimits":{"limitId":"codex","planType":"prolite","primary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":1784488047},"secondary":null},"rateLimitsByLimitId":null}' 1783965600
  assert_cache "$root/cache.json" '
assert [w["label"] for w in data["windows"]] == ["Weekly"]
assert data["5h-utilization"] == ""
assert data["5h-reset"] == ""
assert data["7d-utilization"] == "0.1100"
assert data["status"] == "allowed"
assert data["_quota_bucket"] == "Codex"
assert data["_quota_window"] == "Weekly"
'
}

test_spark_5h_stays_in_its_bucket() {
  local root="$WORK/spark-5h"
  mkdir -p "$root/codex/sessions"
  run_usage "$root" '{"rateLimits":{"limitId":"codex","primary":{"usedPercent":9,"windowDurationMins":10080,"resetsAt":1784488047},"secondary":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":9,"windowDurationMins":10080,"resetsAt":1784488047},"secondary":null},"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":75,"windowDurationMins":300,"resetsAt":1784500000},"secondary":null}}}' 1783965600
  assert_cache "$root/cache.json" '
spark = data["buckets"][1]
assert spark["id"] == "codex_bengalfox"
assert spark["windows"][0]["minutes"] == 300
assert spark["windows"][0]["label"] == "5h"
assert spark["windows"][0]["utilization"] == 0.75
assert data["5h-utilization"] == ""
assert data["5h-reset"] == ""
assert data["7d-utilization"] == "0.0900"
assert data["_quota_bucket"] == "Codex"
assert data["_quota_window"] == "Weekly"
'
}

test_general_status_ignores_hot_spark_bucket() {
  local root="$WORK/status-general"
  mkdir -p "$root/codex/sessions"
  run_usage "$root" '{"rateLimits":{"limitId":"codex","primary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":1784488047},"secondary":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":1784488047},"secondary":null},"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":1784500000},"secondary":null,"rateLimitReachedType":"primary"}}}' 1783965600
  assert_cache "$root/cache.json" '
assert data["status"] == "allowed"
assert data["_quota_bucket"] == "Codex"
assert data["_quota_window"] == "Weekly"
assert data["_limit_reached_type"] == ""
assert data["buckets"][1]["rateLimitReachedType"] == "primary"
'
}

test_special_only_bucket_is_not_general_codex() {
  local root="$WORK/special-only"
  mkdir -p "$root/codex/sessions"
  run_usage "$root" '{"rateLimits":{},"rateLimitsByLimitId":{"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1783979000},"secondary":null,"rateLimitReachedType":"primary"}}}' 1783965600
  assert_cache "$root/cache.json" '
assert len(data["buckets"]) == 1
assert data["buckets"][0]["id"] == "codex_bengalfox"
assert data["windows"] == []
assert data["5h-utilization"] == ""
assert data["7d-utilization"] == ""
assert data["status"] == "allowed"
assert data["_quota_bucket"] == ""
assert data["_quota_window"] == ""
assert data["_limit_reached_type"] == ""
'
}

test_top_level_special_bucket_is_not_general_codex() {
  local root="$WORK/top-level-special"
  mkdir -p "$root/codex/sessions"
  run_usage "$root" '{"rateLimits":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1783979000},"secondary":null,"rateLimitReachedType":"primary"},"rateLimitsByLimitId":null}' 1783965600
  assert_cache "$root/cache.json" '
assert len(data["buckets"]) == 1
assert data["buckets"][0]["id"] == "codex_bengalfox"
assert data["buckets"][0]["isGeneral"] is False
assert data["windows"] == []
assert data["5h-utilization"] == ""
assert data["status"] == "allowed"
assert data["_quota_bucket"] == ""
assert data["_quota_window"] == ""
assert data["_limit_reached_type"] == ""
'
}

test_future_session_events_are_rejected() {
  local root="$WORK/future-session"
  local file="$root/codex/sessions/2026/07/13/session.jsonl"
  # now=2026-07-13T18:00:00Z. This future event is internally plausible, but not current.
  write_rate_limit_event "$file" "2026-07-14T20:00:00Z" 96 1784066400
  run_usage "$root" '{"rateLimits":{"limitId":"codex","planType":"prolite","primary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":1784488047},"secondary":null},"rateLimitsByLimitId":null}' 1783965600
  assert_cache "$root/cache.json" '
assert [w["label"] for w in data["windows"]] == ["Weekly"]
assert data["5h-utilization"] == ""
assert data["status"] == "allowed"
assert data["_quota_window"] == "Weekly"
'
}

test_slight_clock_skew_session_event_is_allowed() {
  local root="$WORK/skew-session"
  local file="$root/codex/sessions/2026/07/13/session.jsonl"
  write_rate_limit_event "$file" "2026-07-13T18:01:00Z" 44 1783972860
  run_usage "$root" '{"rateLimits":{"limitId":"codex","planType":"prolite","primary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":1784488047},"secondary":null},"rateLimitsByLimitId":null}' 1783965600
  assert_cache "$root/cache.json" '
assert [w["label"] for w in data["windows"]] == ["5h", "Weekly"]
assert data["5h-utilization"] == "0.4400"
assert data["status"] == "allowed"
'
}

test_cached_future_session_events_are_rejected_and_cache_is_bounded() {
  local root="$WORK/cached-future"
  local file="$root/codex/sessions/2026/07/13/session.jsonl"
  mkdir -p "$(dirname "$file")"
  python - "$file" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "w") as fh:
    for i in range(10000):
        sec = i % 60
        event = {
            "type": "event_msg",
            "timestamp": f"2026-07-13T18:00:{sec:02d}Z",
            "payload": {
                "type": "token_count",
                "rate_limits": {
                    "limit_id": "codex",
                    "plan_type": "prolite",
                    "primary": {
                        "used_percent": 10 + (i % 80),
                        "window_minutes": 300,
                        "resets_at": 1783972800 + sec,
                    },
                    "secondary": {
                        "used_percent": 11,
                        "window_minutes": 10080,
                        "resets_at": 1784488047,
                    },
                },
            },
        }
        fh.write(json.dumps(event, separators=(",", ":")) + "\n")
PY
  run_usage "$root" '{"rateLimits":{"limitId":"codex","planType":"prolite","primary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":1784488047},"secondary":null},"rateLimitsByLimitId":null}' 1783965600
  assert_cache "$root/activity.json" '
assert data["schemaVersion"] == 2
assert len(data["rateLimitEvents"]) <= 2
'
  python - "$root/activity.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["rateLimitEvents"].append({
    "minutes": 300,
    "kind": "primary",
    "label": "5h",
    "utilization": 0.96,
    "reset": 1784066400,
    "source": "session",
    "timestamp": "2026-07-14T20:00:00Z",
    "eventEpoch": 1784059200,
})
json.dump(data, open(path, "w"), separators=(",", ":"))
PY
  run_usage "$root" '{"rateLimits":{"limitId":"codex","planType":"prolite","primary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":1784488047},"secondary":null},"rateLimitsByLimitId":null}' 1783965600
  assert_cache "$root/cache.json" '
assert data["status"] == "allowed"
assert data["5h-utilization"] != "0.9600"
'
  assert_cache "$root/activity.json" '
assert len(data["rateLimitEvents"]) <= 2
assert all(item["eventEpoch"] <= 1783965600 + 120 for item in data["rateLimitEvents"])
'
}

test_rollout_fallback_uses_newest_canonical_codex_event() {
  local root="$WORK/rollout-canonical"
  local file="$root/codex/sessions/2026/07/13/session.jsonl"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' '{"type":"event_msg","timestamp":"2026-07-13T20:00:00Z","payload":{"rate_limits":{"limit_id":"codex","plan_type":"prolite","primary":{"used_percent":12,"window_minutes":10080,"resets_at":1784488047},"secondary":null}}}' > "$file"
  printf '%s\n' '{"type":"event_msg","timestamp":"2026-07-13T20:05:00Z","payload":{"rate_limits":{"limit_id":"codex_bengalfox","limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":100,"window_minutes":300,"resets_at":1783979000},"secondary":null}}}' >> "$file"
  CODEX_HOME="$root/codex" \
  CODEX_USAGE_CACHE_FILE="$root/cache.json" \
  CODEX_USAGE_ACTIVITY_FILE="$root/activity.json" \
  CODEX_USAGE_DISABLE_RPC=1 \
  CODEX_USAGE_NOW=1783965600 \
  TZ=Europe/Berlin \
    "$CODEX_USAGE"
  assert_cache "$root/cache.json" '
assert len(data["buckets"]) == 1
assert data["buckets"][0]["id"] == "codex"
assert data["windows"][0]["label"] == "Weekly"
assert data["windows"][0]["utilization"] == 0.12
assert data["status"] == "allowed"
assert data["_quota_bucket"] == "Codex"
'
}

test_cumulative_activity_dedupe_and_local_day() {
  local root="$WORK/activity"
  local file="$root/codex/sessions/2026/07/12/session.jsonl"
  write_token_event "$file" "2026-07-12T21:20:00Z" 1000
  write_token_event "$file" "2026-07-12T22:10:00Z" 1500
  write_token_event "$file" "2026-07-12T22:20:00Z" 1500
  write_token_event "$file" "2026-07-12T22:25:00Z" 2000
  # 2026-07-12 22:30 UTC is 2026-07-13 00:30 Europe/Berlin.
  run_usage "$root" '{"primary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":1784488047},"secondary":null}' 1783895400
  assert_cache "$root/cache.json" '
assert data["_rate_per_hour"] == 1000
assert data["_today_tokens"] == 1000
assert data["_rate_label"] == "Local activity (1h, incl. cached)"
'
  write_token_event "$file" "2026-07-12T22:35:00Z" 2000
  write_token_event "$file" "2026-07-12T22:40:00Z" 2300
  run_usage "$root" '{"primary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":1784488047},"secondary":null}' 1783896000
  assert_cache "$root/cache.json" '
assert data["_rate_per_hour"] == 1300
assert data["_today_tokens"] == 1300
'
}

test_stale_fallback_preserves_cache_shape() {
  local root="$WORK/stale"
  mkdir -p "$root/codex/sessions" "$(dirname "$root/cache.json")"
  printf '{"schemaVersion":3,"buckets":[{"id":"codex","label":"Codex","isGeneral":true,"windows":[{"kind":"primary","minutes":10080,"label":"Weekly","utilization":0.5,"reset":1}]}],"_source":"rpc"}\n' > "$root/cache.json"
  CODEX_HOME="$root/codex" \
  CODEX_USAGE_CACHE_FILE="$root/cache.json" \
  CODEX_USAGE_ACTIVITY_FILE="$root/activity.json" \
  CODEX_USAGE_DISABLE_RPC=1 \
  CODEX_USAGE_NOW=1783965600 \
    "$CODEX_USAGE"
  assert_cache "$root/cache.json" '
assert data["schemaVersion"] == 3
assert data["buckets"][0]["windows"][0]["label"] == "Weekly"
assert data["_source"] == "stale"
'
}

test_general_weekly_and_spark_bucket
test_general_primary_and_secondary_windows
test_unknown_window_does_not_pollute_legacy_fields
test_null_rate_limits_by_id_falls_back_to_rate_limits
test_session_log_supplements_missing_general_5h
test_session_supplement_rejects_noncanonical_and_implausible_5h
test_spark_5h_stays_in_its_bucket
test_general_status_ignores_hot_spark_bucket
test_special_only_bucket_is_not_general_codex
test_top_level_special_bucket_is_not_general_codex
test_future_session_events_are_rejected
test_slight_clock_skew_session_event_is_allowed
test_cached_future_session_events_are_rejected_and_cache_is_bounded
test_rollout_fallback_uses_newest_canonical_codex_event
test_cumulative_activity_dedupe_and_local_day
test_stale_fallback_preserves_cache_shape

printf 'qs-codex-usage regression tests passed\n'
