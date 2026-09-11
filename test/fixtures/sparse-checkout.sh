#!/bin/sh
#
# Git treats skip-worktree entries (what a sparse checkout sets on every path
# outside the cone) as absent from the worktree: not deleted when missing,
# not modified when a stale copy is on disk. gitstatusd used to stat every
# index entry and hand the missing ones to libgit2, which reported them as
# deleted, so a cone checkout showed every excluded file as unstaged (#107,
# #365). A sparse index (index.sparse=true) is a different story: libgit2
# can't parse the mandatory sdir extension, so the index is reported as
# disabled rather than the repo as missing.
# See https://github.com/romkatv/gitstatus/issues/107
# See https://github.com/romkatv/gitstatus/issues/365

set -ue
. "$(dirname -- "$0")/../lib.sh"

gitstatus_test_setup
trap gitstatus_test_cleanup EXIT

cd -- "$repo"
git init -q
mkdir -p in/deep out1 out2
echo 1 >top
echo 1 >in/a
echo 1 >in/deep/b
echo 1 >out1/c
echo 1 >out2/d
git add .
git commit -qm base

# Cone checkout: out1/ and out2/ are gone from disk and skip-worktree in the
# index. git status is clean
git sparse-checkout set --cone in
[ ! -e out1 ] || {
  echo "expected out1 to be removed by the sparse checkout"
  exit 1
}
gitstatus_query "$repo"
gitstatus_expect 1 1 is_repo
gitstatus_expect 11 0 num_unstaged
gitstatus_expect 13 0 num_untracked
gitstatus_expect 18 0 num_unstaged_deleted
gitstatus_expect 25 2 num_skip_worktree

# Changes inside the cone still count
echo x >>in/a
rm in/deep/b
gitstatus_query "$repo"
gitstatus_expect 11 2 num_unstaged
gitstatus_expect 18 1 num_unstaged_deleted
git checkout -q -- in
git sparse-checkout disable

# The bit on its own, without sparse-checkout mode, since recent git clears
# it for files it finds on disk when that mode is on. d/ mixes a skip-worktree
# entry with a normal one
git update-index --skip-worktree top out1/c
echo x >>top
rm out1/c
gitstatus_query "$repo"
gitstatus_expect 11 0 num_unstaged
gitstatus_expect 25 2 num_skip_worktree

# A dir that can't be opened goes to libgit2 whole, which has to skip the
# skip-worktree entry and report only the real deletion
rm -rf out1
gitstatus_query "$repo"
gitstatus_expect 11 0 num_unstaged
git update-index --no-skip-worktree out1/c
git update-index --skip-worktree out2/d
mkdir out1
echo 1 >out1/c
git add out1/c
echo 1 >out2/e
git add out2/e
git commit -qm mixed
rm -rf out2
gitstatus_query "$repo"
gitstatus_expect 11 1 num_unstaged
gitstatus_expect 18 1 num_unstaged_deleted
mkdir out2
echo u >out2/u
gitstatus_query "$repo"
gitstatus_expect 11 1 num_unstaged
gitstatus_expect 13 1 num_untracked

# Sparse index: the repo is still reported, with the index disabled. The
# bits come off first so git can collapse the dirs, and --sparse-index sets
# index.sparse where sparse-checkout disable put its own copy
rm out2/u
git update-index --no-skip-worktree top out2/d
git checkout -q -- .
git sparse-checkout set --cone --sparse-index in 2>/dev/null || git sparse-checkout set --cone in
if ! git ls-files -t --sparse 2>/dev/null | grep -q '^S out1/$'; then
  echo "git $(git --version | cut -d' ' -f3) didn't write a sparse index, skipping that part"
  exit 0
fi
gitstatus_query "$repo"
gitstatus_expect 1 1 is_repo
gitstatus_expect 4 master branch
gitstatus_expect 29 1 index_disabled
