#!/bin/sh
#
# Use-after-free in libgit2's handle_unmatched_new_item(): an untracked dir
# that is the last entry of its parent (because a tracked sibling was deleted)
# made the diff read a path from a freed iterator frame. Crashes on musl 1.2.x,
# silently returns the right answer on glibc and old musl.
# See .plans/fix-libgit2-untracked-dir-use-after-free/PLAN.md

set -ue
. "$(dirname -- "$0")/../lib.sh"

gitstatus_test_setup
trap gitstatus_test_cleanup EXIT

cd -- "$repo"
git init -q
mkdir -p local/lib/git_prompt zsh/configs
echo 1 >local/lib/git_prompt/a.py
echo 2 >local/lib/git_prompt/b.py
echo 1 >top1
echo 2 >top2
echo z >zsh/configs/a.zsh
git add -A
git commit -qm init

rm -rf local/lib/git_prompt
mkdir -p local/lib/gitstatus
echo n >local/lib/gitstatus/gitstatusd

gitstatus_query "$repo"
gitstatus_expect 1 1 is_repo
gitstatus_expect 11 2 num_unstaged
gitstatus_expect 13 1 num_untracked
gitstatus_expect 18 2 num_unstaged_deleted
