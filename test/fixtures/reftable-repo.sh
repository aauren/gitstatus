#!/bin/sh
#
# With extensions.refStorage=reftable there is no refs/tags directory and no
# packed-refs, so the direct-file tag reader finds nothing and gitstatusd
# reported an empty tag for every commit. It falls back to libgit2's ref
# iterator for these repos.

set -ue
. "$(dirname -- "$0")/../lib.sh"

gitstatus_test_setup
trap gitstatus_test_cleanup EXIT

cd -- "$repo"
if ! git init -q --ref-format=reftable 2>/dev/null; then
  echo "git $(git --version | cut -d' ' -f3) can't init a reftable repo, skipping"
  exit 0
fi
[ "$(git config extensions.refstorage)" = reftable ] || {
  echo "expected extensions.refStorage=reftable"
  exit 1
}

echo 1 >a
git add a
git commit -qm one
git tag lightweight
gitstatus_query "$repo"
gitstatus_expect 1 1 is_repo
gitstatus_expect 3 "$(git rev-parse HEAD)" commit
gitstatus_expect 4 master branch
gitstatus_expect 17 lightweight tag

# Annotated tags are stored with a peeled value, so this resolves without
# reading the tag object
echo 2 >a
git commit -qam two
git tag -a annotated -m annotated
gitstatus_query "$repo"
gitstatus_expect 17 annotated tag

# Nothing points at this one
echo 3 >a
git commit -qam three
gitstatus_query "$repo"
gitstatus_expect 17 "" tag

# Tags with a slash, the same as the files backend
git tag foo/bar
gitstatus_query "$repo"
gitstatus_expect 17 foo/bar tag

# Compaction rewrites the tables, tags must survive it
git pack-refs --all
gitstatus_query "$repo"
gitstatus_expect 17 foo/bar tag

# Linked worktrees have their own reftable stack for per-worktree refs, but
# tags are shared and live in the main one
git worktree add -q "$work/wt" annotated
gitstatus_query "$work/wt"
gitstatus_expect 1 1 is_repo
gitstatus_expect 17 annotated tag
