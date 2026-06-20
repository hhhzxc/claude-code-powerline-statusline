#!/bin/bash
# Powerline statusline for Claude Code - pure local, zero API calls.
# Line 1: [model | effort | context%]   (24-space gap)   [$total | 5h% | 7d%]
# Line 2: [Write $ (%) | Out $ (%) | Cache $ (%)]
#
# Line-2 dollars are allocated from the authoritative .cost.total_cost_usd in
# proportion to per-category cost weights {w,o,c} from the Stop hook (each
# transcript message — main loop + every sub-agent — priced at its OWN model's
# rate). Invariants for ALL inputs: the three dollars sum EXACTLY to the Line-1
# total, and the three percentages sum to exactly 100 (largest-weight category
# absorbs the rounding residual; one canonical rounded total used for both lines).
# Refreshes once per turn (snapshot); context% / total / rate limits are live.
#
# Works with Bash 3.2+ (macOS system Bash, Linux Bash, and Windows Git Bash).
# Perf: all JSON fields are pulled in ONE jq call (one field per line) instead
# of ~13 separate jq processes per refresh - matters on Windows where spawns are slow.
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

input=$(cat)
printf '%s' "$input" | jq -e . >/dev/null 2>&1 || input='{}'   # bad/empty stdin -> {} so // defaults apply, no stderr noise

# ---- one jq call extracts every field, one per line; read loop keeps empty fields ----
F=()
_idx=0
while IFS= read -r _line; do
  F[$_idx]="$_line"
  _idx=$((_idx + 1))
done < <(printf '%s' "$input" | jq -r '
  ((.model.display_name // .model.id // "unknown") | sub("^claude-";"") | gsub("[\n\r]";" ")),  # 0 model display
  ((.model.id // "") | gsub("[\n\r]";" ")),                                # 1 model id (pricing)
  ((.effort.level // "") | gsub("[\n\r]";" ")),                            # 2 effort
  (.cost.total_cost_usd // 0),                                             # 3 total cost
  (.context_window.used_percentage // ""),                                 # 4 ctx %
  (.context_window.context_window_size // ""),                             # 5 ctx size
  (.rate_limits.five_hour.used_percentage // ""),                          # 6 5h
  (.rate_limits.seven_day.used_percentage // ""),                          # 7 7d
  ((.session_id // "") | gsub("[\n\r]";" ")),                              # 8 session id
  (.context_window.current_usage.input_tokens // 0),                       # 9  live input  (fallback)
  (.context_window.current_usage.cache_creation_input_tokens // 0),        # 10 live cw     (fallback)
  (.context_window.current_usage.output_tokens // 0),                      # 11 live output (fallback)
  (.context_window.current_usage.cache_read_input_tokens // 0)             # 12 live cr     (fallback)
' 2>/dev/null | tr -d '\r')   # jq emits CRLF on Windows; tr drops CR; gsub above also collapses any embedded newline so the per-line field count never shifts
unset _idx _line
model="${F[0]:-unknown}"; model_id="${F[1]}"; effort="${F[2]}"; cost="${F[3]:-0}"
used_pct="${F[4]}"; ctx_size="${F[5]}"; rate_5h="${F[6]}"; rate_7d="${F[7]}"; sid="${F[8]}"
cu_in="${F[9]:-0}"; cu_cw="${F[10]:-0}"; cu_out="${F[11]:-0}"; cu_cr="${F[12]:-0}"
case "$sid" in *[!A-Za-z0-9._-]*) sid="" ;; esac   # ignore an unsafe session id -> fall back to live

# ---- fallback pricing table (USD per MILLION tokens), only used pre-snapshot.
#      From official Anthropic docs (2026-06-18). Cache rule: read=in x0.1,
#      write_5m=in x1.25, write_1h=in x2. *...* matches dated snapshots / Bedrock
#      "anthropic." prefix; the [1m] tag is stripped first. ----
model_id="${model_id%%\[*}"
case "$model_id" in
  *opus-4-8*|*opus-4-7*|*opus-4-6*|*opus-4-5*) P_IN=5;  P_OUT=25; P_CR=0.5; P_W5=6.25; P_W1=10 ;;  # Opus 4.5 / 4.6 / 4.7 / 4.8
  *sonnet-4-6*|*sonnet-4-5*)                   P_IN=3;  P_OUT=15; P_CR=0.3; P_W5=3.75; P_W1=6  ;;  # Sonnet 4.5 / 4.6
  *haiku-4-5*)                                 P_IN=1;  P_OUT=5;  P_CR=0.1; P_W5=1.25; P_W1=2  ;;  # Haiku 4.5
  *fable-5*|*mythos-5*|*mythos-preview*)       P_IN=10; P_OUT=50; P_CR=1.0; P_W5=12.5; P_W1=20 ;;  # Fable 5 / Mythos 5
  *)                                           P_IN=5;  P_OUT=25; P_CR=0.5; P_W5=6.25; P_W1=10 ;;  # unknown -> assume Opus-tier
esac

# ---- per-category cost weights: per-turn snapshot (priced per-model across all
#      agents); else live single-model current_usage already pulled above ----
snap="$HOME/.claude/statusline-tokens-$sid.json"
if [ -n "$sid" ] && [ -s "$snap" ] && jq -e . "$snap" >/dev/null 2>&1; then
  S=()
  _idx=0
  while IFS= read -r _line; do
    S[$_idx]="$_line"
    _idx=$((_idx + 1))
  done < <(jq -r '(.w // 0), (.o // 0), (.c // 0)' "$snap" 2>/dev/null | tr -d '\r')
  unset _idx _line
  raw_w="${S[0]:-0}"; raw_o="${S[1]:-0}"; raw_c="${S[2]:-0}"
else
  raw_w=$(awk -v a="$cu_in" -v b="$cu_cw" -v ri="$P_IN" -v r1="$P_W1" 'BEGIN{printf "%.4f", a*ri + b*r1}')
  raw_o=$(awk -v t="$cu_out" -v r="$P_OUT" 'BEGIN{printf "%.4f", t*r}')
  raw_c=$(awk -v t="$cu_cr" -v r="$P_CR"  'BEGIN{printf "%.4f", t*r}')
fi

# ---- allocation: dollars sum EXACTLY to total, percentages sum to 100; largest
#      weight absorbs both residuals; one canonical T returned for the Line-1 total ----
read -r cost_w cost_o cost_c pct_w pct_o pct_c total_disp <<EOF
$(awk -v rw="$raw_w" -v ow="$raw_o" -v cwc="$raw_c" -v tot="$cost" 'BEGIN{
  if (rw<0) rw=0; if (ow<0) ow=0; if (cwc<0) cwc=0;
  raw=rw+ow+cwc;
  T=int(tot*100+0.5)/100; if (T<0) T=0;
  if (raw<=0){ printf "0.00 0.00 %.2f 0 0 100 %.2f", T, T; exit }
  dw=int(T*rw/raw*100+0.5)/100; do_=int(T*ow/raw*100+0.5)/100; dc=int(T*cwc/raw*100+0.5)/100;
  pw=int(rw/raw*100+0.5);       po=int(ow/raw*100+0.5);        pc=int(cwc/raw*100+0.5);
  if      (rw>=ow && rw>=cwc) { dw=T-do_-dc; pw=100-po-pc; }
  else if (ow>=rw && ow>=cwc) { do_=T-dw-dc; po=100-pw-pc; }
  else                        { dc=T-dw-do_; pc=100-pw-po; }
  printf "%.2f %.2f %.2f %d %d %d %.2f", dw, do_, dc, pw, po, pc, T
}')
EOF

# ---- powerline glyph / palette ----
SEP=$'\xee\x82\xb0'   # powerline right separator U+E0B0 (explicit bytes)
ESC=$'\033'; RESET="${ESC}[0m"; DARK="43;43;43"
BG_MODEL="209;122;133"; BG_EFFORT="122;186;181"; BG_CTX="214;168;92"
BG_COST="169;201;106";  BG_5H="111;159;216";     BG_7D="209;122;133"
BG_WRITE="224;152;92";  BG_OUT="111;159;216";    BG_CACHE="175;143;204"

render() {  # $1 = bg-array name, $2 = text-array name
  local bg_name="$1" tx_name="$2" out="" n=0 i bg tx next_bg
  eval "n=\${#${bg_name}[@]}"
  for ((i=0;i<n;i++)); do
    eval "bg=\${${bg_name}[$i]}"
    eval "tx=\${${tx_name}[$i]}"
    out+="${ESC}[48;2;${bg}m${ESC}[38;2;${DARK}m${tx}"
    if ((i<n-1)); then
      eval "next_bg=\${${bg_name}[$((i+1))]}"
      out+="${ESC}[48;2;${next_bg}m${ESC}[38;2;${bg}m${SEP}"
    else
      out+="${RESET}${ESC}[38;2;${bg}m${SEP}${RESET}"
    fi
  done
  printf '%s' "$out"
}

# ---- line 1 LEFT: model | effort | context ----
declare -a L_BG L_TX
L_BG+=("$BG_MODEL"); L_TX+=(" ${model} ")
[ -n "$effort" ] && { L_BG+=("$BG_EFFORT"); L_TX+=(" ${effort} "); }
if [ -n "$used_pct" ] && [ -n "$ctx_size" ]; then
  used_k=$(awk -v p="$used_pct" -v s="$ctx_size" 'BEGIN{printf "%.1f",(p/100)*s/1000}')
  total_k=$(awk -v t="$ctx_size" 'BEGIN{printf "%.0f",t/1000}')
  pct=$(awk -v p="$used_pct" 'BEGIN{printf "%.0f",p}')
  L_BG+=("$BG_CTX"); L_TX+=(" ${used_k}K/${total_k}K ${pct}% ")
else
  L_BG+=("$BG_CTX"); L_TX+=(" --K ")
fi

# ---- line 1 RIGHT: total cost | 5h | 7d ----
declare -a R_BG R_TX
R_BG+=("$BG_COST"); R_TX+=(" \$${total_disp} ")
[ -n "$rate_5h" ] && { R_BG+=("$BG_5H"); R_TX+=(" 5h $(awk -v p="$rate_5h" 'BEGIN{printf "%.0f",p}')% "); }
[ -n "$rate_7d" ] && { R_BG+=("$BG_7D"); R_TX+=(" 7d $(awk -v p="$rate_7d" 'BEGIN{printf "%.0f",p}')% "); }

line1_left=$(render L_BG L_TX); line1_right=$(render R_BG R_TX)
gap=$(printf '%*s' 24 '')
line1="${line1_left}${gap}${line1_right}"

# ---- line 2: Write $ (%) | Out $ (%) | Cache $ (%) ----
declare -a L2_BG L2_TX
L2_BG+=("$BG_WRITE"); L2_TX+=(" Write \$${cost_w} (${pct_w}%) ")
L2_BG+=("$BG_OUT");   L2_TX+=(" Out \$${cost_o} (${pct_o}%) ")
L2_BG+=("$BG_CACHE"); L2_TX+=(" Cache \$${cost_c} (${pct_c}%) ")
line2=$(render L2_BG L2_TX)

printf '%s\n%s' "$line1" "$line2"
