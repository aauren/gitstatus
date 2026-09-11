#!/bin/sh
#
# With extensions.worktreeConfig and core.repositoryformatversion=1 (which is
# how git writes it, sparse-checkout for instance turns it on), the libgit2
# fork gitstatusd used to ship refused to open the repo with "unsupported
# extension name", so the prompt showed no repo at all. Beyond opening, the
# per-worktree config file has to be read, and only for its own worktree.
# See https://github.com/romkatv/gitstatus/issues/489

set -ue
. "$(dirname -- "$0")/../lib.sh"

gitstatus_test_setup
trap gitstatus_test_cleanup EXIT

# A submodule pinned one commit behind, so diff.ignoreSubmodules is a config
# knob with a visible effect on num_unstaged
sub="$work/sub"
mkdir -- "$sub"
cd -- "$sub"
git init -q
echo 1 >f
git add f
git commit -qm one
old="$(git rev-parse HEAD)"
echo 2 >f
git commit -qam two

cd -- "$repo"
git init -q
echo a >a
git add a
git commit -qm init
git -c protocol.file.allow=always submodule add -q "$sub" sub
git commit -qm 'add sub'
git -C sub checkout -q "$old"

gitstatus_query "$repo"
gitstatus_expect 1 1 is_repo
gitstatus_expect 11 1 num_unstaged

# The issue: the repo has to open at all
git config extensions.worktreeConfig true
git config core.repositoryformatversion 1
gitstatus_query "$repo"
gitstatus_expect 1 1 is_repo
gitstatus_expect 4 master branch
gitstatus_expect 11 1 num_unstaged

# config.worktree is read
git config --worktree diff.ignoreSubmodules all
gitstatus_query "$repo"
gitstatus_expect 11 0 num_unstaged

# A linked worktree has its own config.worktree. Newer git copies the main
# one's file into it at creation, older git doesn't, so set it both ways
# rather than depending on the initial state
git worktree add -q "$work/wt" -b feature
cd -- "$work/wt"
git -c protocol.file.allow=always submodule update -q --init
git -C sub checkout -q "$old"
git config --worktree diff.ignoreSubmodules none
gitstatus_query "$work/wt"
gitstatus_expect 1 1 is_repo
gitstatus_expect 4 feature branch
gitstatus_expect 11 1 num_unstaged
git config --worktree diff.ignoreSubmodules all
gitstatus_query "$work/wt"
gitstatus_expect 11 0 num_unstaged

# And neither side leaks into the other
gitstatus_query "$repo"
gitstatus_expect 11 0 num_unstaged
git -C "$repo" config --worktree diff.ignoreSubmodules none
gitstatus_query "$repo"
gitstatus_expect 11 1 num_unstaged
gitstatus_query "$work/wt"
gitstatus_expect 11 0 num_unstaged
