#!/usr/bin/env bash
# lane-sweep.sh - run several focused --test-pattern lanes back to back as ONE command.
#
# Why: a fresh-boot lane costs about a minute of fixed overhead before its test editors start (a
# Script/Generated regen boot whenever the previous run rewrote a generated file, plus a discovery boot under
# --discover-fresh). Nothing changes between the lanes of one sweep, so only the first lane pays it: later
# lanes pass --no-script-regen and reuse the cached test list. A later lane that cannot use the shortcut
# (exit 76 or 80, or no summary) is re-run once with the full flags and marked "retried".
#
# For an agent: launch this once in the background and wait for it to exit. Do not tail it, do not watch
# the summary per lane. It prints nothing until the end, then one table and a SWEEP_DONE line.
#
# usage: lane-sweep.sh --tag <name> [--build] [--cached-discovery] [--editor-args "<args>"] [--strings <file>]
#                      [--start <n>] [--stop-file <path>] [--project <root>] <pattern>...
#   --tag          names the run: logs go to Saved/Logs/Lanes/<tag>/, one .stdout and one .log per lane
#   --build        the first lane is --build --target=Editor --test (editor closed)
#   --cached-discovery  the first lane reuses the cached test list too: pass it when no test was added, renamed
#                  or removed since the last run (a --discover-fresh run also costs the NEXT run a regen boot)
#   --editor-args  passed to every test editor (one value per sweep; chain two sweeps for two values)
#   --strings      a file with one fixed string per line; each lane reports how often each appears,
#                  as <in the lane's stdout>/<in the project logs the lane wrote>
#   --start        number of the first lane (default 1), to continue an earlier sweep under one tag
#   --stop-file    when this file exists the sweep stops before the next lane (default <dir>/stop)
# exit: 0 every lane green; 1 at least one lane not green; 2 usage; 3 stopped by the stop file.
set -u

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

TAG=""; BUILD=0; CACHED=0; EARGS=""; STRINGS=""; START=1; STOP=""; ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --build) BUILD=1; shift ;;
    --cached-discovery) CACHED=1; shift ;;
    --editor-args) EARGS="$2"; shift 2 ;;
    --strings) STRINGS="$2"; shift 2 ;;
    --start) START="$2"; shift 2 ;;
    --stop-file) STOP="$2"; shift 2 ;;
    --project) ROOT="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done
[ -n "$TAG" ] && [ $# -gt 0 ] || usage
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
[ -x "$ROOT/CkAuto/UnrealToolbox.exe" ] || { echo "no CkAuto/UnrealToolbox.exe under $ROOT" >&2; exit 2; }
cd "$ROOT" || exit 2

REL="Saved/Logs/Lanes/$TAG"
mkdir -p "$REL"
SUM="$REL/summary.txt"
[ -n "$STOP" ] || STOP="$REL/stop"

run_lane() { # <name> <pattern> <first|next|full>
  local flags=(--test --test-pattern "$2" --no-live "--output=$REL/$1.log")
  case "$3" in
    first) [ "$CACHED" = 1 ] || flags+=(--discover-fresh)
           [ "$BUILD" = 1 ] && flags=(--build --target=Editor "${flags[@]}") ;;
    full)  flags+=(--discover-fresh) ;;
    next)  flags+=(--no-script-regen) ;;
  esac
  [ -n "$EARGS" ] && flags+=(--editor-args "$EARGS")
  ./CkAuto/UnrealToolbox.exe "${flags[@]}" > "$REL/$1.stdout" 2>&1
  echo "EXIT=$?" >> "$REL/$1.stdout"
}

field() { grep -a -m1 "^$1:" "$2" | awk '{print $2}'; }

n=$START; mode=first; lanes=0; red=0; t0=$(date +%s)
for pat in "$@"; do
  if [ -f "$STOP" ]; then echo "STOPPED before $pat" >> "$SUM"; cat "$SUM"; exit 3; fi
  name=$(printf "%s_%02d_%s" "$TAG" "$n" "$(printf '%s' "$pat" | tr -c 'A-Za-z0-9' '_')")
  out="$REL/$name.stdout"; marker="$REL/.start_$name"; note="$mode"
  touch "$marker"; sleep 1; l0=$(date +%s)
  run_lane "$name" "$pat" "$mode"
  ex=$(grep -a '^EXIT=' "$out" | tail -1 | cut -d= -f2); tot=$(field Total "$out")
  if [ "$mode" = next ] && { [ "$ex" = 76 ] || [ "$ex" = 80 ] || [ -z "$tot" ]; }; then
    cp "$out" "$REL/$name.first-try.stdout"
    run_lane "$name" "$pat" full; note="retried(full)"
    ex=$(grep -a '^EXIT=' "$out" | tail -1 | cut -d= -f2); tot=$(field Total "$out")
  fi
  pas=$(field Passed "$out"); fai=$(field Failed "$out")
  ase=$(grep -a -c 'Angelscript: Error' "$out")
  boots=$(grep -a -c -E '^Discovering tests|^Script/Generated: regenerating' "$out")
  counts=""
  if [ -n "$STRINGS" ] && [ -f "$STRINGS" ]; then
    while IFS= read -r s || [ -n "$s" ]; do
      s="${s%$'\r'}"; [ -n "$s" ] || continue
      a=$(grep -a -c -F -- "$s" "$out"); b=0
      while IFS= read -r l; do [ -n "$l" ] && b=$((b + $(grep -a -c -F -- "$s" "$l"))); done \
        < <(find Saved/Logs -maxdepth 1 -name '*.log' -newer "$marker")
      counts="$counts $a/$b"
    done < "$STRINGS"
  fi
  verdict=green
  if [ "$ex" != 0 ] || [ -z "$tot" ] || [ "$tot" = 0 ] || [ "${fai:-1}" != 0 ] || [ "$ase" != 0 ]; then
    verdict=RED; red=$((red + 1))
  fi
  detail=""
  [ "$verdict" = RED ] && detail=$(grep -a -A12 -E '^Failed tests|NEW FAILURES|^\[population\] ERROR' "$out" | cut -c1-160 | head -14 | tr '\n' ';')
  echo "$verdict | $name | $pat | ${tot:--}/${pas:--}/${fai:--} | EXIT=$ex | AS=$ase |${counts:+ strings:$counts |} $(( $(date +%s) - l0 ))s | $note, extra boots=$boots | $detail" >> "$SUM"
  n=$((n + 1)); lanes=$((lanes + 1)); mode=next
done

cat "$SUM"
echo "SWEEP_DONE tag=$TAG lanes=$lanes red=$red seconds=$(( $(date +%s) - t0 )) summary=$REL/summary.txt"
[ "$red" = 0 ]
