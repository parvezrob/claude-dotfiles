#!/bin/sh
# token-ledger one-time seed: sums the token usage a session's transcript
# recorded BEFORE the mod started counting, so a resumed or long-running
# session keeps its full totals. Run once per session by the mod, at low
# priority, never by the status line.
#
#   seed.sh <claude-config-dir> <session-id> <cutoff-iso8601>
#
# Prints one JSON object on stdout:
#   {"main":{"in":..,"out":..,"cr":..,"cw":..,"req":..},"sub":{...},"files":N}
# in = uncached input, cr = cache reads, cw = cache writes, req = requests.
#
# A response with several content blocks is written as several transcript
# lines carrying the same message id and the same usage; each id counts once.
# Subagent runs live in <session>/subagents/*.jsonl and count as "sub".
set -u
cfg="$1" sid="$2" cut="$3"
G=/usr/bin/grep JQ=/usr/bin/jq

main=""
for f in "$cfg"/projects/*/"$sid".jsonl; do
  [ -f "$f" ] && { main="$f"; break; }
done
[ -n "$main" ] || { printf '{"main":null,"sub":null,"files":0,"reason":"no transcript"}\n'; exit 0; }
subdir="${main%.jsonl}/subagents"

# One TSV row per usage line: id, side, in, out, cache-read, cache-write.
rows() { # $1 file, $2 forced side ("" = from isSidechain)
  "$G" -F '"usage"' "$1" 2>/dev/null | "$JQ" -R -r --arg cut "$cut" --arg side "$2" '
    fromjson? // empty
    | select((.message.usage | type) == "object" and ((.timestamp // "") < $cut))
    | .message.usage as $u
    | [ (.message.id // .requestId // .uuid // ""),
        (if $side != "" then $side elif (.isSidechain // false) then "s" else "m" end),
        ($u.input_tokens // 0), ($u.output_tokens // 0),
        ($u.cache_read_input_tokens // 0), ($u.cache_creation_input_tokens // 0) ]
    | @tsv'
}

n=1
{
  rows "$main" ""
  if [ -d "$subdir" ]; then
    for f in "$subdir"/*.jsonl; do
      [ -f "$f" ] || continue
      rows "$f" s; n=$((n + 1))
    done
  fi
  printf 'FILES\t%s\n' "$n"
} | /usr/bin/awk -F '\t' '
  $1 == "FILES" { files = $2; next }
  $1 != "" && seen[$1]++ { next }
  { k = $2; i[k] += $3; o[k] += $4; r[k] += $5; w[k] += $6; q[k]++ }
  function b(k) { return sprintf("{\"in\":%.0f,\"out\":%.0f,\"cr\":%.0f,\"cw\":%.0f,\"req\":%d}", i[k], o[k], r[k], w[k], q[k]) }
  END { printf "{\"main\":%s,\"sub\":%s,\"files\":%d}\n", b("m"), b("s"), files }'
