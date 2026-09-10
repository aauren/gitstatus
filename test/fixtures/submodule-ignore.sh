#!/bin/sh
#
# gitstatusd used to force ignore_submodules=dirty on the workdir diff, which
# overrides submodule.<name>.ignore from .gitmodules and diff.ignoreSubmodules
# from git config. A submodule marked ignore=all with new commits showed up as
# unstaged in the prompt while git status said the tree was clean, and one with
# ignore unset (none) and untracked content was hidden while git status showed
# it as modified. Expectations below match git status for the same tree.
# See https://github.com/romkatv/gitstatus/pull/357

set -ue
. "$(dirname -- "$0")/../lib.sh"

gitstatus_test_setup
trap gitstatus_test_cleanup EXIT

# Upstream for the submodule, two commits so the superproject can pin the
# second and we can move the submodule back to the first
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
echo top >top
git add top
git commit -qm init
git -c protocol.file.allow=always submodule add -q "$sub" sub
git commit -qm 'add sub'

# Changing .gitmodules dirties the superproject, so commit each change
set_ignore() {
  git config -f .gitmodules submodule.sub.ignore "$1"
  git commit -qam "ignore=$1"
}

# Control: clean superproject and submodule
gitstatus_query "$repo"
gitstatus_expect 1 1 is_repo
gitstatus_expect 11 0 num_unstaged
gitstatus_expect 13 0 num_untracked

# ignore unset: new commits in the submodule are unstaged, as before
git -C sub checkout -q "$old"
gitstatus_query "$repo"
gitstatus_expect 11 1 num_unstaged

# ignore unset: untracked content in the submodule counts too, like git status
git -C sub checkout -q master
echo u >sub/untracked
gitstatus_query "$repo"
gitstatus_expect 11 1 num_unstaged
gitstatus_expect 13 0 num_untracked

# ignore=untracked: untracked content is hidden, modified content is not
set_ignore untracked
gitstatus_query "$repo"
gitstatus_expect 11 0 num_unstaged
echo 3 >sub/f
gitstatus_query "$repo"
gitstatus_expect 11 1 num_unstaged

# ignore=dirty: only new commits count
set_ignore dirty
gitstatus_query "$repo"
gitstatus_expect 11 0 num_unstaged
git -C sub checkout -q -- f
git -C sub checkout -q "$old"
gitstatus_query "$repo"
gitstatus_expect 11 1 num_unstaged

# ignore=all: nothing in the submodule counts, not even new commits. This is
# the case from the issue, the old binary reported 1 here
set_ignore all
gitstatus_query "$repo"
gitstatus_expect 11 0 num_unstaged
gitstatus_expect 13 0 num_untracked

# diff.ignoreSubmodules in git config is the other knob git status honours.
# Only checked with the per-submodule setting unset, because git lets
# submodule.<name>.ignore win over it and libgit2 does the opposite
git config -f .gitmodules --unset submodule.sub.ignore
git commit -qam 'ignore unset'
gitstatus_query "$repo"
gitstatus_expect 11 1 num_unstaged
git config diff.ignoreSubmodules all
gitstatus_query "$repo"
gitstatus_expect 11 0 num_unstaged
