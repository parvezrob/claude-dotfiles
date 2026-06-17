#!/usr/bin/env bash
# Claude Code status line — two lines (model + effort pinned to the right edge):
#   ctx 427k/1M (42%) · session 45% ↻ 2h26m · week 10% ↻ 6d              Opus 4.8 1M
#   PR#42 ✓ · +3109 -698 lines · tok in 20.3M out 420k                   xhigh·think
#
# Live JSON fields used (see https://code.claude.com/docs/en/statusline):
#   .context_window.{total_input_tokens,total_output_tokens,context_window_size} -> ctx fill
#   .rate_limits.five_hour/seven_day.{used_percentage,resets_at}                 -> session / week + reset
#   .cost.{total_lines_added,total_lines_removed}                                -> lines changed this session
#   .effort.level / .thinking.enabled                                            -> effort (right-aligned, line 2)
#   .pr.{number,review_state}                                                    -> PR badge (when a PR is detected)
#   .model.display_name                                                          -> model name (right-aligned, line 1)
#   .transcript_path                                                             -> this session's JSONL (token totals)
#
# Requirements: bash, jq, a UTF-8 locale. Right-alignment needs Claude Code v2.1.153+
# (which exports $COLUMNS); on older versions the model/effort just fall back inline.
#
# Notes:
#   - rate_limits are absent for non-subscription billing and until the first reply -> shown as "—".
#   - Per-session token totals are summed from the transcript. "in" includes cache re-reads, so it grows
#     much larger than the ctx number (real usage, not a bug). Set TOKENS_INCLUDE_CACHE_READS=0 for new input only.

TOKENS_INCLUDE_CACHE_READS=1

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  printf 'statusline: jq not installed'
  exit 0
fi

# --- Pull everything we need out of the live JSON in one pass. ---------------
result=$(printf '%s' "$input" | jq -r '
  def hum(n):
    if   n >= 1000000 then ((n/100000|floor)/10|tostring) + "M"
    elif n >= 1000    then ((n/1000)|round|tostring)       + "k"
    else (n|floor|tostring) end;
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
      (.transcript_path // "")
    ] | map(tostring) | join("\u001f")
')

# Split on US (0x1F), a non-whitespace delimiter, so empty fields are preserved
# (a tab delimiter would collapse adjacent empties and shift later fields).
IFS=$'\037' read -r used_h size_h ctx_pct sess_pct sess_reset week_pct week_reset ladd lrem effort think \
  pr_num pr_state model tpath <<< "$result"

# --- Per-session token totals + last-turn cache hit, from the transcript. ----
# Totals sum every call; "cache" is the cache-hit ratio of the most recent
# main-thread call (cache_read / total input) — high means the turn was served
# mostly from cache, which is also why the cumulative "in" grows so large.
tok_in_h="" tok_out_h="" cache_pct=""
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
  toks=$(jq -nr --argjson reads "$TOKENS_INCLUDE_CACHE_READS" '
    def hum(n):
      if   n >= 1000000 then ((n/100000|floor)/10|tostring) + "M"
      elif n >= 1000    then ((n/1000)|round|tostring)       + "k"
      else (n|floor|tostring) end;
    reduce inputs as $l ({i:0, o:0, li:0, lcc:0, lcr:0};
      if ($l.message.usage // null) == null then .
      else
        ($l.message.usage) as $u
        | .i += (($u.input_tokens // 0)
                 + ($u.cache_creation_input_tokens // 0)
                 + (if $reads == 1 then ($u.cache_read_input_tokens // 0) else 0 end))
        | .o += ($u.output_tokens // 0)
        | if ($l.isSidechain // false) then .          # ignore subagent calls for "last turn"
          else .li  = ($u.input_tokens // 0)
             | .lcc = ($u.cache_creation_input_tokens // 0)
             | .lcr = ($u.cache_read_input_tokens // 0) end
      end)
    | (.li + .lcc + .lcr) as $din
    | (if $din > 0 then ((.lcr * 100 / $din) | floor) else -1 end) as $cpct
    | "\(hum(.i))\t\(hum(.o))\t\($cpct)"
  ' "$tpath" 2>/dev/null)
  IFS=$'\t' read -r tok_in_h tok_out_h cache_pct <<< "$toks"
fi

# --- Colours. ----------------------------------------------------------------
ESC=$'\033'
dim="${ESC}[2m"; rst="${ESC}[0m"
teal="${ESC}[38;5;86m"; amber="${ESC}[38;5;214m"; red="${ESC}[38;5;203m"; green="${ESC}[38;5;72m"

# Teal while there's headroom, warming as it fills: teal < 80%, amber 80-89%, red >= 90%.
color_for() {
  if   [ "$1" -ge 90 ]; then printf '%s' "$red"
  elif [ "$1" -ge 80 ]; then printf '%s' "$amber"
  else printf '%s' "$teal"; fi
}

# Compact "time until" for a Unix-epoch target: 5d / 3h12m / 47m / <1m / now.
fmt_dur() {
  local rem=$(( $1 - $(date +%s) ))
  if   [ "$rem" -le 0 ];     then printf 'now'
  elif [ "$rem" -ge 86400 ]; then printf '%dd' $(( rem / 86400 ))
  elif [ "$rem" -ge 3600 ];  then printf '%dh%02dm' $(( rem / 3600 )) $(( (rem % 3600) / 60 ))
  elif [ "$rem" -ge 60 ];    then printf '%dm' $(( rem / 60 ))
  else printf '<1m'; fi
}

# A rate-limit segment ("session"/"week"); em dash when there's no data yet.
# $3 is the Unix-epoch reset time; appends a dimmed "↻<countdown>" when present.
limit_seg() {
  local label="$1" pct="$2" reset="$3" body
  if [ "$pct" = "-" ]; then
    printf '%s%s —%s' "$dim" "$label" "$rst"
    return
  fi
  body="$(color_for "$pct")${label} ${pct}%${rst}"
  [ -n "$reset" ] && body="${body}${dim} ↻ $(fmt_dur "$reset")${rst}"
  printf '%s' "$body"
}

# --- Assemble two lines from whichever segments have data. -------------------
sep=" ${dim}·${rst} "

# Join the given segments with the separator.
join_segs() {
  local out="" i=0 s
  for s in "$@"; do
    [ "$i" -gt 0 ] && out+="$sep"
    out+="$s"; i=$((i + 1))
  done
  printf '%s' "$out"
}

# Line 1 — capacity & limits. Model is rendered separately, right-aligned below.
line1=()
line1+=("$(color_for "${ctx_pct:-0}")ctx ${used_h}/${size_h} (${ctx_pct}%)${rst}")
line1+=("$(limit_seg session "$sess_pct" "$sess_reset")")
line1+=("$(limit_seg week "$week_pct" "$week_reset")")

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
[ -n "$tok_in_h" ] && line2+=("${dim}tok in ${rst}${teal}${tok_in_h}${rst}${dim} out ${rst}${teal}${tok_out_h}${rst}")
if [ -n "$cache_pct" ] && [ "$cache_pct" -ge 0 ] 2>/dev/null; then
  cc2="$teal"; [ "$cache_pct" -lt 90 ] && cc2="$amber"; [ "$cache_pct" -lt 50 ] && cc2="$red"
  line2+=("${dim}cache ${cc2}${cache_pct}%${rst}")
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
dispw() {
  local s="$1" b=${#1} a=0 g t
  for g in "·" "↻" "…" "✓" "✗" "—"; do t="${s//$g/}"; a=$(( a + b - ${#t} )); done
  printf '%s' $(( b + a ))
}

# Emit "left … right" with the right text flush to the terminal edge. Claude Code
# exports $COLUMNS (v2.1.153+); without it (or when too narrow) fall back to inline.
emit_line() {
  local left="$1" rplain="$2" rseg="$3" cols="${COLUMNS:-0}" lp pad
  lp="$(printf '%s' "$left" | sed $'s/\033\\[[0-9;]*m//g')"
  pad=$(( cols - $(dispw "$lp") - $(dispw "$rplain") - 2 ))
  if [ "$cols" -gt 0 ] && [ "$pad" -ge 1 ]; then
    printf '%s%*s%s' "$left" "$pad" '' "$rseg"
  else
    printf '%s%s%s' "$left" "$sep" "$rseg"
  fi
}

# Line 1: capacity on the left, model name flush right.
emit_line "$(join_segs "${line1[@]}")" "$model" "${dim}${model}${rst}"

# Line 2: work + tokens on the left, effort flush right (directly under the model).
line2_left="$(join_segs "${line2[@]}")"
if [ -n "$effort_txt" ]; then
  printf '\n'
  emit_line "$line2_left" "$effort_txt" "${dim}${effort_txt}${rst}"
elif [ -n "$line2_left" ]; then
  printf '\n%s' "$line2_left"
fi
