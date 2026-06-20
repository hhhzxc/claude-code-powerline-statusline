#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
POWERLINE="$ROOT/statusline-powerline.sh"
STOP_HOOK="$ROOT/statusline-stop.sh"
SETTINGS="$ROOT/settings-snippet.json"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected output to contain: $2" ;;
  esac
}

command -v bash >/dev/null 2>&1 || fail "bash is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v awk >/dev/null 2>&1 || fail "awk is required"

bash -n "$POWERLINE" || fail "statusline-powerline.sh has a syntax error"
bash -n "$STOP_HOOK" || fail "statusline-stop.sh has a syntax error"
jq -e . "$SETTINGS" >/dev/null || fail "settings-snippet.json is not valid JSON"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/claude-statusline.XXXXXX") || fail "could not create temp dir"
trap 'rm -rf "$tmp"' EXIT

status_json='{"model":{"display_name":"claude-opus-4-8","id":"claude-opus-4-8"},"effort":{"level":"high"},"cost":{"total_cost_usd":34.5},"context_window":{"used_percentage":66,"context_window_size":1000000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":200,"output_tokens":300,"cache_read_input_tokens":4000}},"rate_limits":{"five_hour":{"used_percentage":21},"seven_day":{"used_percentage":3}},"session_id":"sample-session"}'

main_output=$(printf '%s\n' "$status_json" | HOME="$tmp" bash "$POWERLINE") || fail "main statusline failed"
assert_contains "$main_output" "opus-4-8"
assert_contains "$main_output" "high"
assert_contains "$main_output" "660.0K/1000K 66%"
assert_contains "$main_output" '$34.50'
assert_contains "$main_output" "Write $"
assert_contains "$main_output" "Out $"
assert_contains "$main_output" "Cache $"

transcript="$tmp/transcript.jsonl"
printf '%s\n' '{"message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":200,"cache_creation":{"ephemeral_5m_input_tokens":40,"ephemeral_1h_input_tokens":20}}}}' > "$transcript"

hook_json=$(jq -n --arg p "$transcript" '{session_id:"sample-session",transcript_path:$p}')
printf '%s\n' "$hook_json" | HOME="$tmp" bash "$STOP_HOOK" || fail "Stop hook failed"

snapshot="$tmp/.claude/statusline-tokens-sample-session.json"
[ -s "$snapshot" ] || fail "Stop hook did not write snapshot"

w=$(jq -r '.w' "$snapshot")
o=$(jq -r '.o' "$snapshot")
c=$(jq -r '.c' "$snapshot")
[ "$w" = "950" ] || fail "unexpected write weight: $w"
[ "$o" = "250" ] || fail "unexpected output weight: $o"
[ "$c" = "100" ] || fail "unexpected cache weight: $c"

snapshot_status_json='{"model":{"display_name":"claude-opus-4-8","id":"claude-opus-4-8"},"cost":{"total_cost_usd":13},"context_window":{"used_percentage":50,"context_window_size":200000,"current_usage":{"input_tokens":1,"cache_creation_input_tokens":1,"output_tokens":1,"cache_read_input_tokens":1}},"session_id":"sample-session"}'
snapshot_output=$(printf '%s\n' "$snapshot_status_json" | HOME="$tmp" bash "$POWERLINE") || fail "main statusline with snapshot failed"
assert_contains "$snapshot_output" 'Write $9.50 (73%)'
assert_contains "$snapshot_output" 'Out $2.50 (19%)'
assert_contains "$snapshot_output" 'Cache $1.00 (8%)'

printf 'not json\n' | HOME="$tmp" bash "$POWERLINE" >/dev/null || fail "main statusline should tolerate bad input"
printf 'not json\n' | HOME="$tmp" bash "$STOP_HOOK" >/dev/null || fail "Stop hook should tolerate bad input"

printf 'OK: smoke tests passed on %s with Bash %s\n' "$(uname -s 2>/dev/null || printf unknown)" "$BASH_VERSION"
