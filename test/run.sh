#!/bin/sh
#
# Runs every fixture in test/fixtures/ against a gitstatusd binary.
#
#   test/run.sh [path/to/gitstatusd]
#
# Defaults to usrbin/gitstatusd. Fixtures are plain sh scripts that exit
# non-zero on failure, see test/lib.sh for the helpers they share.

set -u

root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
GITSTATUSD="${1:-$root/usrbin/gitstatusd}"
# Fixtures cd into their scratch dirs, so a relative path has to be resolved here
case "$GITSTATUSD" in
  /*) ;;
  *) GITSTATUSD="$PWD/$GITSTATUSD" ;;
esac
export GITSTATUSD
# Unlimited counts and no recursion into untracked dirs, which is what the
# shell bindings use and what the untracked-dir fixtures depend on
export GITSTATUSD_ARGS="${GITSTATUSD_ARGS:--s -1 -u -1 -d -1 -v ERROR}"

if [ ! -x "$GITSTATUSD" ]; then
  >&2 echo "[error] not an executable: $GITSTATUSD"
  exit 1
fi

pass=0
fail=0
for fixture in "$root"/test/fixtures/*.sh; do
  name="${fixture##*/}"
  name="${name%.sh}"
  if out="$(sh "$fixture" 2>&1)"; then
    echo "PASS $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name"
    printf '%s\n' "$out" | sed 's/^/    /'
    fail=$((fail + 1))
  fi
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
