#!/bin/bash
# Stop hook: at each turn end, accumulate the WHOLE session's cost across ALL
# models/agents (main transcript + every sub-agent transcript), pricing each
# message at ITS OWN model's rate. Emits per-category cost weights {w,o,c}
# (write / output / cache) so the statusline's Write/Out/Cache split stays
# correct even when sub-agents run on a different model (Opus main + Haiku agents).
# Rate model: per-MTok input price by model; output = 5x input, cache read = 0.1x,
# cache write 5m = 1.25x, 1h = 2x (Anthropic's uniform multiplier structure).
# Works with Bash 3.2+ (macOS system Bash, Linux Bash, and Windows Git Bash).
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

input=$(cat)
printf '%s' "$input" | jq -e . >/dev/null 2>&1 || exit 0   # bad/empty stdin -> do nothing, never block the turn

sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
case "$sid" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac        # only safe chars may go into the snapshot file path
raw=$(printf '%s' "$input" | jq -r '.transcript_path // empty')

normalize_path() {
  local raw_path="$1" p drive rest alt
  [ -n "$raw_path" ] || return 0

  if command -v cygpath >/dev/null 2>&1; then
    p=$(cygpath -u "$raw_path" 2>/dev/null)
    [ -n "$p" ] && [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  fi

  # Backslashes -> slashes. Some Bash builds can use C:/... directly.
  local bs='\'
  p="${raw_path//"$bs"//}"
  [ -f "$p" ] && { printf '%s' "$p"; return 0; }

  if [[ "$p" =~ ^([A-Za-z]):/(.*)$ ]]; then
    drive=$(printf '%s' "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')
    rest="${BASH_REMATCH[2]}"
    for alt in "/$drive/$rest" "/cygdrive/$drive/$rest" "/mnt/$drive/$rest"; do
      [ -f "$alt" ] && { printf '%s' "$alt"; return 0; }
    done
  fi

  printf '%s' "$p"
}

tpath=$(normalize_path "$raw")
[ -z "$tpath" ] && tpath="$raw"
[ -n "$tpath" ] && [ -f "$tpath" ] || exit 0

# main transcript + sub-agent transcripts (sub-agents may use a different model)
base="${tpath%.jsonl}"
shopt -s nullglob
files=("$tpath")
[ -d "$base/subagents" ] && files+=("$base"/subagents/*.jsonl)

snap=$(cat "${files[@]}" 2>/dev/null | jq -n -R '
  def pin($m): ($m // "") as $x
    | if   ($x|test("synthetic";"i")) then 0
      elif ($x|test("haiku";"i"))     then 1
      elif ($x|test("sonnet";"i"))    then 3
      elif ($x|test("fable";"i")) or ($x|test("mythos";"i")) then 10
      elif ($x|test("opus";"i"))      then 5
      else 5 end;
  # -R + (fromjson? // empty) makes parsing line-resilient: a single malformed
  # transcript line is skipped rather than aborting the whole accumulation.
  reduce (inputs | (fromjson? // empty) | select(.message.usage != null)) as $l (
    {w:0, o:0, c:0};
    (pin($l.message.model)) as $p | ($l.message.usage) as $u |
    # cache-creation token weight: TTL breakdown when present, else the flat
    # cache_creation_input_tokens (treated as 1h x2).
    ( (2*($u.cache_creation.ephemeral_1h_input_tokens // 0)
       + 1.25*($u.cache_creation.ephemeral_5m_input_tokens // 0)) as $byttl
      | if $byttl > 0 then $byttl else 2*($u.cache_creation_input_tokens // 0) end ) as $cw |
      .w += $p * ( ($u.input_tokens // 0) + $cw )
    | .o += $p * ( 5   * ($u.output_tokens // 0) )
    | .c += $p * ( 0.1 * ($u.cache_read_input_tokens // 0) )
  )' 2>/dev/null)

# write the snapshot atomically, stripping CR jq may emit on Windows so the file is clean/self-contained
if [ -n "$snap" ] && [ "$snap" != "null" ]; then
  mkdir -p "$HOME/.claude" 2>/dev/null || exit 0
  target="$HOME/.claude/statusline-tokens-$sid.json"
  tmp="$target.$$"
  if printf '%s' "$snap" | tr -d '\r' > "$tmp"; then
    mv -f "$tmp" "$target" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
fi

# housekeeping: drop snapshot files from sessions untouched for 30+ days (portable, no GNU find flags)
for old_snap in "$HOME"/.claude/statusline-tokens-*.json; do
  [ -e "$old_snap" ] || continue
  find "$old_snap" -type f -mtime +30 -exec rm -f {} \; 2>/dev/null
done
exit 0
