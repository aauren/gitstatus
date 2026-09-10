#!/bin/sh
#
# Tags are shared refs, so in a linked worktree refs/tags and packed-refs live
# in the common gitdir, not in .git/worktrees/<name>/. gitstatusd used to look
# in the per-worktree gitdir and report no tag at all.
# See https://github.com/romkatv/gitstatus/pull/467

set -ue
. "$(dirname -- "$0")/../lib.sh"

gitstatus_test_setup
trap gitstatus_test_cleanup EXIT

cd -- "$repo"
git init -q
echo 1 >a
git add a
git commit -qm one
git tag packed-tag
git pack-refs --all
echo 2 >a
git commit -qam two
git tag loose-tag

# Control: tags resolve in the main worktree as before
gitstatus_query "$repo"
gitstatus_expect 1 1 is_repo
gitstatus_expect 17 loose-tag tag

git worktree add -q "$work/wt-loose" loose-tag
gitstatus_query "$work/wt-loose"
gitstatus_expect 1 1 is_repo
gitstatus_expect 17 loose-tag tag

git worktree add -q "$work/wt-packed" packed-tag
gitstatus_query "$work/wt-packed"
gitstatus_expect 1 1 is_repo
gitstatus_expect 17 packed-tag tag
