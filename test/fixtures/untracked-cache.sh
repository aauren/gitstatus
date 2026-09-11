#!/bin/sh
#
# With core.untrackedCache=true git status writes the index far more often
# (to persist the UNTR extension), and every index write smudges racily-clean
# entries by zeroing their stat data. The libgit2 fork gitstatusd shipped
# treated a size mismatch against the index as "modified" without hashing
# (romkatv/libgit2 6ed87d09, dropped in the rebase), so those entries showed
# up as unstaged until git rewrote them. git update-index --cacheinfo
# produces the same zeroed stat data on demand, which is what this uses.
# See https://github.com/romkatv/gitstatus/issues/474

set -ue
. "$(dirname -- "$0")/../lib.sh"

gitstatus_test_setup
trap gitstatus_test_cleanup EXIT

cd -- "$repo"
git init -q
i=1
while [ "$i" -le 20 ]; do
  echo "$i" >"f$i"
  i=$((i + 1))
done
git add .
git commit -qm base
git config core.untrackedCache true

# Let git write the UNTR extension, then check the index still parses
mkdir d
touch d/u
git status >/dev/null
gitstatus_query "$repo"
gitstatus_expect 1 1 is_repo
gitstatus_expect 11 0 num_unstaged
gitstatus_expect 13 1 num_untracked

# Zero the stat data of three clean entries. The content matches, so a hash
# says clean, and that's what git status says too
zero_stat() {
  for f in f1 f2 f3; do
    git update-index --cacheinfo "100644,$(git rev-parse "HEAD:$f"),$f"
  done
}
zero_stat
[ -z "$(git status --porcelain --untracked-files=no)" ] || {
  echo "expected git status to be clean"
  exit 1
}
zero_stat
gitstatus_query "$repo"
gitstatus_expect 11 0 num_unstaged
gitstatus_expect 13 1 num_untracked

# A real change under the same conditions still counts, and only once
echo changed >f1
zero_stat
gitstatus_query "$repo"
gitstatus_expect 11 1 num_unstaged
