#!/usr/bin/env bash
# Claude Code status line — two lines (model + effort pinned to the right edge):
#   ctx 427k/1M (42%) · session 45% ↻ 2h26m · week 10% ↻ 6d              Opus 4.8 1M
#   PR#42 ✓ · +3109 -698 lines · tok in 5.3B out 7.7M ⣀⣤⣶⣿ · sub 41% · cache 99% · ≈$4.1k   xhigh·think
#
# Live JSON fields used (see https://code.claude.com/docs/en/statusline):
#   .context_window.{total_input_tokens,total_output_tokens,context_window_size} -> ctx fill
#   .rate_limits.five_hour/seven_day.{used_percentage,resets_at}                 -> session / week + reset
#   .cost.{total_lines_added,total_lines_removed}                                -> lines changed this session
#   .effort.level / .thinking.enabled                                            -> effort (right-aligned, line 2)
#   .pr.{number,review_state}                                                    -> PR badge (when a PR is detected)
#   .model.display_name                                                          -> model name (right-aligned, line 1)
#   .session_id                                                                  -> this session's token ledger
#   .prompt_cache.hit_ratio                                                      -> session cache-hit ratio (main thread)
#   .prompt_cache.{warm,expires_at}                                              -> warm-cache countdown ("warm 47m")
#   .cost.total_cost_usd                                                         -> estimated session cost (list price)
#
# Requirements: bash, jq, a UTF-8 locale. Right-alignment needs Claude Code v2.1.153+
# (which exports $COLUMNS); on older versions the model/effort just fall back inline.
#
# Notes:
#   - rate_limits are absent for non-subscription billing and until the first reply -> shown as "—".
#   - Per-session token totals come from the token-ledger mod (~/.claude/mods-local/token-ledger), which counts
#     every model request and writes ~/.claude/token-ledger/<session_id>.json; this script only reads that small
#     file. No ledger (mod not loaded) -> no token segment. "in" includes cache re-reads, so it grows much larger
#     than the ctx number (real usage, not a bug). Set TOKENS_INCLUDE_CACHE_READS=0 for new input only.
#   - The braille sparkline is the output tokens of the last 16 main-conversation requests (2 per glyph).
#   - The cache countdown is teal while warm, amber under 5 minutes, dim "cold" once expired; Claude Code
#     re-runs the script when expires_at passes, between those runs it counts down only on other updates.
#   - Narrow terminals drop the cache countdown, then cost, then the sparkline, then the subagent share.
#   - One process per run, the jq: stdin is read with the `read` builtin, "now" comes from jq, and the
#     helpers hand their result back in REPLY instead of through $( ) subshells.

TOKENS_INCLUDE_CACHE_READS=1

IFS= read -r -d '' input || true

if ! command -v jq >/dev/null 2>&1; then
  printf 'statusline: jq not installed'
  exit 0
fi

# --- Token ledger: the token-ledger mod's small per-session file. -------------
# The mod (~/.claude/mods-local/token-ledger) counts every model request and
# writes <config>/token-ledger/<session_id>.json, debounced. The session id is
# matched in bash (no extra process) and read as raw text, so a missing or
# half-written ledger only drops the token segment, never the whole bar.
ledger=/dev/null
if [[ $input =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]+)\" ]]; then
  f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/token-ledger/${BASH_REMATCH[1]}.json"
  [ -r "$f" ] && ledger="$f"
fi

# --- Pull everything we need out of the live JSON in one pass. ---------------
result=$(jq -r --rawfile L "$ledger" --argjson reads "$TOKENS_INCLUDE_CACHE_READS" '
  def hum(n):
    if   n >= 1000000 then ((n/100000|floor)/10|tostring) + "M"
    elif n >= 1000    then ((n/1000)|round|tostring)       + "k"
    else (n|floor|tostring) end;
  # Token totals: k / M / B, one decimal while it still says something.
  def humb(n):
    if   n >= 1e10 then ((n/1e9)|round|tostring) + "B"
    elif n >= 1e9  then ((n/1e8|round)/10|tostring) + "B"
    elif n >= 1e8  then ((n/1e6)|round|tostring) + "M"
    elif n >= 1e6  then ((n/1e5|round)/10|tostring) + "M"
    elif n >= 1e3  then ((n/1e3)|round|tostring) + "k"
    else (n|floor|tostring) end;
  def tin:  if . == null then 0 else (.in + .cw + (if $reads == 1 then .cr else 0 end)) end;
  def tout: if . == null then 0 else .out end;
  # Bars of 1-4 dots (square-root scale, so one big reply does not flatten the
  # rest), filled from the bottom, two values per braille cell.
  def spark:
    (map(select(type == "number"))) as $r | ($r | max // 0) as $m
    | if ($r | length) < 2 or $m <= 0 then "" else
        ($r | map(if . <= 0 then 0 else ((. / $m | sqrt) * 4 | ceil | if . > 4 then 4 elif . < 1 then 1 else . end) end)) as $lv
        | (if ($lv | length) % 2 == 1 then [0] + $lv else $lv end) as $l
        | [range(0; $l | length; 2) as $i
            | 10240 + ([0, 64, 68, 70, 71][$l[$i]]) + ([0, 128, 160, 176, 184][$l[$i + 1]])]
        | implode end;
  # seed.state "done": the transcript history from before the mod loaded is in;
  # "pending"/"running": that one-time count is still going; "failed": live only.
  def ledger($sid):
    (try ($L | fromjson) catch null) as $g
    | if ($g | type) != "object" or $g.sessionId != $sid then ["", "", "", "", ""] else
        ($g.seed.state // "") as $st
        | (if $st == "done" then $g.seed else {} end) as $s
        | (($g.live.main | tin) + ($s.main | tin)) as $mi
        | (($g.live.sub  | tin) + ($s.sub  | tin)) as $si
        | (($g.live.main | tout) + ($s.main | tout)) as $mo
        | (($g.live.sub  | tout) + ($s.sub  | tout)) as $so
        | ($mi + $si + $mo + $so) as $all
        | (if ($si + $so) <= 0 or $all <= 0 then ""
           else (($si + $so) * 100 / $all) as $p | if $p < 1 then "<1" else ($p | floor | tostring) end end) as $sub
        | [$st, humb($mi + $si), humb($mo + $so), $sub, (($g.recent // [])[-16:] | spark)]
      end;
  (.context_window.total_input_tokens  // 0)        as $in
  | (.context_window.total_output_tokens // 0)      as $out
  | (.context_window.context_window_size // 200000) as $size
  | ($in + $out) as $used
  | (if $size > 0 then ($used * 100 / $size) else 0 end) as $pct
  | [ hum($used),
      hum($size),
      ($pct|floor|tostring),
      (.rate_limits.five_hour.used_percentage  | if . == null then "-" else (.|floor|tostring) end),
      (.rate_limits.five_hour.resets_at        | if . == null then "" else (.|floor|tostring) end),
      (.rate_limits.seven_day.used_percentage  | if . == null then "-" else (.|floor|tostring) end),
      (.rate_limits.seven_day.resets_at        | if . == null then "" else (.|floor|tostring) end),
      (.cost.total_lines_added   // 0 | tostring),
      (.cost.total_lines_removed // 0 | tostring),
      (.effort.level // ""),
      (.thinking.enabled // false | tostring),
      (.pr.number // "" | tostring),
      (.pr.review_state // ""),
      (.model.display_name // .model.id // "?"),
      (.prompt_cache.hit_ratio | if . == null then "" else (. * 100 | floor | tostring) end),
      (.prompt_cache as $pc
        | if $pc == null then ""
          elif $pc.warm == true and ($pc.expires_at | type) == "number" then ([($pc.expires_at - now | floor), 0] | max | tostring)
          else "-1" end),
      (now | floor | tostring),
      (.cost.total_cost_usd // 0
        | if   . < 0.005 then ""
          elif . < 10    then "$" + ((. * 100 | round) / 100 | tostring)
          elif . < 1000  then "$" + (round | tostring)
          else "$" + ((. / 100 | round) / 10 | tostring) + "k" end)
    ] + ledger(.session_id // "") | map(tostring) | join("\u001f")
' <<< "$input")

# Split on US (0x1F), a non-whitespace delimiter, so empty fields are preserved
# (a tab delimiter would collapse adjacent empties and shift later fields).
IFS=$'\037' read -r used_h size_h ctx_pct sess_pct sess_reset week_pct week_reset ladd lrem effort think \
  pr_num pr_state model cache_pct cache_rem now_s cost_h tok_state tok_in_h tok_out_h sub_pct spark <<< "$result"

# --- Colours. ----------------------------------------------------------------
ESC=$'\033'
dim="${ESC}[2m"; rst="${ESC}[0m"
teal="${ESC}[38;5;86m"; amber="${ESC}[38;5;214m"; red="${ESC}[38;5;203m"; green="${ESC}[38;5;72m"
mist="${ESC}[38;5;73m"; pale="${ESC}[38;5;250m"   # sparkline / cost: quieter than the teal figures

# Teal while there's headroom, warming as it fills: teal < 80%, amber 80-89%, red >= 90%.
color_for() {
  if   [ "$1" -ge 90 ]; then REPLY="$red"
  elif [ "$1" -ge 80 ]; then REPLY="$amber"
  else REPLY="$teal"; fi
}

# Compact "time until" for a Unix-epoch target: 5d / 3h12m / 47m / <1m / now.
fmt_dur() {
  local rem=$(( $1 - ${now_s:-0} ))
  if   [ "$rem" -le 0 ];     then REPLY='now'
  elif [ "$rem" -ge 86400 ]; then REPLY="$(( rem / 86400 ))d"
  elif [ "$rem" -ge 3600 ];  then printf -v REPLY '%dh%02dm' $(( rem / 3600 )) $(( (rem % 3600) / 60 ))
  elif [ "$rem" -ge 60 ];    then REPLY="$(( rem / 60 ))m"
  else REPLY='<1m'; fi
}

# A rate-limit segment ("session"/"week"); em dash when there's no data yet.
# $3 is the Unix-epoch reset time; appends a dimmed "↻<countdown>" when present.
limit_seg() {
  local label="$1" pct="$2" reset="$3" body
  if [ "$pct" = "-" ]; then
    REPLY="${dim}${label} —${rst}"
    return
  fi
  color_for "$pct"; body="${REPLY}${label} ${pct}%${rst}"
  [ -n "$reset" ] && { fmt_dur "$reset"; body="${body}${dim} ↻ ${REPLY}${rst}"; }
  REPLY="$body"
}

# --- Assemble two lines from whichever segments have data. -------------------
sep=" ${dim}·${rst} "

# Join the given segments with the separator, into REPLY.
join_segs() {
  local out="" i=0 s
  for s in "$@"; do
    [ "$i" -gt 0 ] && out+="$sep"
    out+="$s"; i=$((i + 1))
  done
  REPLY="$out"
}

# Line 1 — capacity & limits. Model is rendered separately, right-aligned below.
line1=()
color_for "${ctx_pct:-0}"; line1+=("${REPLY}ctx ${used_h}/${size_h} (${ctx_pct}%)${rst}")
limit_seg session "$sess_pct" "$sess_reset"; line1+=("$REPLY")
limit_seg week "$week_pct" "$week_reset"; line1+=("$REPLY")

# Line 2 — this session's work + tokens (left). Effort is right-aligned below.
line2=()
if [ -n "$pr_num" ]; then
  case "$pr_state" in
    approved)          line2+=("${teal}PR#${pr_num} ✓${rst}") ;;
    changes_requested) line2+=("${red}PR#${pr_num} ✗${rst}") ;;
    *)                 line2+=("${dim}PR#${pr_num}${rst}") ;;
  esac
fi
if [ "$ladd" != "0" ] || [ "$lrem" != "0" ]; then
  line2+=("${green}+${ladd}${rst} ${red}-${lrem}${rst} ${dim}lines${rst}")
fi
# Token segments are kept apart from line2 so a narrow terminal can drop the
# optional ones (see the header's drop order) instead of wrapping.
tok_seg="" sub_seg="" cache_seg="" cost_seg=""
case "$tok_state" in
  done|failed)
    ge=""; [ "$tok_state" = failed ] && ge="≥"
    tok_seg="${dim}tok in ${rst}${teal}${ge}${tok_in_h}${rst}${dim} out ${rst}${teal}${ge}${tok_out_h}${rst}"
    [ -n "$sub_pct" ] && sub_seg="${dim}sub ${rst}${teal}${sub_pct}%${rst}" ;;
  pending|running)
    tok_seg="${dim}tok counting…${rst}"; spark="" ;;
  *) spark="" ;;
esac
if [ -n "$cache_pct" ] && [ "$cache_pct" -ge 0 ] 2>/dev/null; then
  cc2="$teal"; [ "$cache_pct" -lt 90 ] && cc2="$amber"; [ "$cache_pct" -lt 50 ] && cc2="$red"
  cache_seg="${dim}cache ${cc2}${cache_pct}%${rst}"
fi
[ -n "$cost_h" ] && cost_seg="${dim}≈${rst}${pale}${cost_h}${rst}"
# Warm-cache countdown: seconds left, or -1 once cold (empty before the first reply).
cd_seg=""
if [ -n "$cache_rem" ]; then
  if [ "$cache_rem" -le 0 ] 2>/dev/null; then cd_seg="${dim}cold${rst}"
  elif [ "$cache_rem" -lt 60 ]; then cd_seg="${dim}warm ${rst}${amber}<1m${rst}"
  elif [ "$cache_rem" -lt 300 ]; then cd_seg="${dim}warm ${rst}${amber}$(( cache_rem / 60 ))m${rst}"
  else cd_seg="${dim}warm ${rst}${teal}$(( cache_rem / 60 ))m${rst}"; fi
fi

# Shorten the verbose 1M-context model name: "Opus 4.8 (1M context)" -> "Opus 4.8 1M".
model="${model/ (1M context)/ 1M}"

# Effort indicator ("xhigh", plus "·think" when thinking is on) — right-aligned.
effort_txt=""
if [ -n "$effort" ]; then
  effort_txt="$effort"; [ "$think" = "true" ] && effort_txt="${effort}·think"
fi

# Ambiguous-width-aware column count of an ANSI-free string. Many terminals render
# East-Asian "ambiguous width" glyphs (·, ↻, …) two columns wide, so count them twice;
# without this the right-aligned text overflows and gets truncated.
dispw() { # -> REPLY
  local s="$1" b=${#1} a=0 g t
  for g in "·" "↻" "…" "✓" "✗" "—" "≥" "≈"; do t="${s//$g/}"; a=$(( a + b - ${#t} )); done
  REPLY=$(( b + a ))
}

# ANSI-free copy of $1 into REPLY, in bash alone (no sed process per call).
strip_ansi() {
  local s="$1" out=""
  while [[ $s == *$'\033['* ]]; do
    out+="${s%%$'\033['*}"; s="${s#*$'\033['}"; s="${s#*m}"
  done
  REPLY="$out$s"
}

# Emit "left … right" with the right text flush to the terminal edge. Claude Code
# exports $COLUMNS (v2.1.153+); without it (or when too narrow) fall back to inline.
emit_line() {
  local left="$1" rplain="$2" rseg="$3" cols="${COLUMNS:-0}" lw pad
  strip_ansi "$left"; dispw "$REPLY"; lw=$REPLY
  dispw "$rplain"; pad=$(( cols - lw - REPLY - 2 ))
  if [ "$cols" -gt 0 ] && [ "$pad" -ge 1 ]; then
    printf '%s%*s%s' "$left" "$pad" '' "$rseg"
  else
    printf '%s%s%s' "$left" "$sep" "$rseg"
  fi
}

# Line 1: capacity on the left, model name flush right.
join_segs "${line1[@]}"; emit_line "$REPLY" "$model" "${dim}${model}${rst}"

# Line 2: work + tokens on the left, effort flush right (directly under the model).
# Assemble line 2's left side, shedding optional segments until it fits beside
# the effort text, in the header's drop order.
build_line2() { # $1 spark? $2 sub? $3 cost? $4 countdown?  -> sets line2_left
  local segs=("${line2[@]}") t="$tok_seg"
  if [ -n "$t" ]; then
    [ "$1" = 1 ] && [ -n "$spark" ] && t+=" ${mist}${spark}${rst}"
    segs+=("$t")
  fi
  [ "$2" = 1 ] && [ -n "$sub_seg" ] && segs+=("$sub_seg")
  [ -n "$cache_seg" ] && segs+=("$cache_seg")
  [ "$4" = 1 ] && [ -n "$cd_seg" ] && segs+=("$cd_seg")
  [ "$3" = 1 ] && [ -n "$cost_seg" ] && segs+=("$cost_seg")
  join_segs "${segs[@]}"; line2_left="$REPLY"
}
room=0
if [ "${COLUMNS:-0}" -gt 0 ]; then
  ew=0; [ -n "$effort_txt" ] && { dispw "$effort_txt"; ew=$(( REPLY + 1 )); }
  room=$(( COLUMNS - 2 - ew ))
fi
for opts in "1 1 1 1" "1 1 1 0" "1 1 0 0" "0 1 0 0" "0 0 0 0"; do
  build_line2 $opts
  [ "$room" -le 0 ] && break
  strip_ansi "$line2_left"; dispw "$REPLY"
  [ "$REPLY" -le "$room" ] && break
done
if [ -n "$effort_txt" ]; then
  printf '\n'
  emit_line "$line2_left" "$effort_txt" "${dim}${effort_txt}${rst}"
elif [ -n "$line2_left" ]; then
  printf '\n%s' "$line2_left"
fi
