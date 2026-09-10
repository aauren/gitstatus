#!/bin/sh
#
# Protocol-driven benchmark: times gitstatusd requests against one or more
# repos, for each binary given.
#
#   test/bench.sh [-n warm_requests] [-t threads] -r repo [-r repo ...] gitstatusd [gitstatusd ...]
#
# For every (binary, repo) pair we start one daemon and send one request (cold:
# repo open, index read, full scan) followed by N more (warm: cached repo and
# index, incremental scan), printing wall time for each phase. Keep the machine
# quiet and run it a couple of times; the numbers are wall clock, not CPU.
#
# Note that "cold" is dominated by CheckDirMtime(), the one-second probe the
# daemon runs per repo to learn whether the filesystem updates directory
# mtimes, so it's the warm number that tells you about scan speed.

set -u

warm=20
threads=
repos=
while getopts 'n:t:r:' opt; do
  case "$opt" in
    n) warm="$OPTARG" ;;
    t) threads="$OPTARG" ;;
    r) repos="$repos $OPTARG" ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

if [ -z "$repos" ] || [ $# -eq 0 ]; then
  >&2 echo "usage: $0 [-n warm] [-t threads] -r repo [-r repo ...] gitstatusd [gitstatusd ...]"
  exit 2
fi

args="-s -1 -u -1 -d -1 -v ERROR"
[ -n "$threads" ] && args="$args -t $threads"

now_ns() { date +%s%N; }

for bin in "$@"; do
  ver="$("$bin" --version 2>/dev/null | head -1)"
  for repo in $repos; do
    repo="$(cd -- "$repo" && pwd)"
    fifo="$(mktemp -u)"
    mkfifo "$fifo"
    out="$(mktemp)"
    "$bin" $args <"$fifo" >"$out" 2>/dev/null &
    pid=$!
    exec 3>"$fifo"

    # cold
    t0=$(now_ns)
    printf 'req\037%s\036' "$repo" >&3
    while [ "$(tr -cd '\036' <"$out" | wc -c)" -lt 1 ]; do sleep 0.001; done
    t1=$(now_ns)

    # warm
    i=0
    while [ "$i" -lt "$warm" ]; do
      printf 'req\037%s\036' "$repo" >&3
      i=$((i + 1))
    done
    while [ "$(tr -cd '\036' <"$out" | wc -c)" -lt $((warm + 1)) ]; do sleep 0.001; done
    t2=$(now_ns)

    exec 3>&-
    wait "$pid" 2>/dev/null
    rm -f "$fifo" "$out"

    cold_ms=$(( (t1 - t0) / 1000000 ))
    warm_us=$(( (t2 - t1) / 1000 / warm ))
    printf '%-24s %-40s cold %6d ms   warm %6d us/req\n' "$ver" "$repo" "$cold_ms" "$warm_us"
  done
done
