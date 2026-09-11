#!/bin/sh
#
# libgit2's ignore handling was the source of two gitstatus bugs. #486: a
# directory whose contents are all excluded by a nested .gitignore was still
# counted as untracked, so VCS_STATUS_NUM_UNTRACKED overcounted against
# git ls-files --others --exclude-standard. #59: a negation in a nested
# .gitignore that undid a parent's rule was dropped at parse time, so paths
# git shows as untracked were hidden. Expectations below are what git status
# reports for the same tree.
# See https://github.com/romkatv/gitstatus/issues/486
# See https://github.com/romkatv/gitstatus/issues/59

set -ue
. "$(dirname -- "$0")/../lib.sh"

gitstatus_test_setup
trap gitstatus_test_cleanup EXIT

cd -- "$repo"
git init -q

# #486: sub/cache/ is only excluded by sub/.gitignore, and it's the only thing
# under sub/, so git reports nothing untracked
echo '*.log' >.gitignore
mkdir -p sub/cache
echo 'cache/' >sub/.gitignore
touch sub/cache/f1 sub/cache/f2 sub/cache/f3
git add .gitignore sub/.gitignore
git commit -qm init
gitstatus_query "$repo"
gitstatus_expect 1 1 is_repo
gitstatus_expect 11 0 num_unstaged
gitstatus_expect 13 0 num_untracked

# A sibling that isn't excluded still counts, as a single dir entry
mkdir sub/keep
touch sub/keep/x
gitstatus_query "$repo"
gitstatus_expect 13 1 num_untracked

# A nested negation re-includes a name the parent excluded
rm -rf sub/keep
echo 'foo' >.gitignore
mkdir d
echo '!foo' >d/.gitignore
touch foo d/foo
git add .gitignore d/.gitignore
git commit -qm negation
gitstatus_query "$repo"
gitstatus_expect 11 0 num_unstaged
gitstatus_expect 13 1 num_untracked

# #59 case 1: '*' at the root with '!foo', and foo/.gitignore re-includes bar.
# The nested negation used to be dropped because it undid a parent's rule
rm -f foo d/foo
rm -rf d sub
printf '*\n!foo\n' >.gitignore
mkdir foo
touch foo/bar
echo '!bar' >foo/.gitignore
git add -A
git commit -qm case1
git rm -q --cached foo/bar
git commit -qm untrack
gitstatus_query "$repo"
gitstatus_expect 13 1 num_untracked

# #59 case 2: same thing with the re-include in the root file
rm foo/.gitignore
printf '*\n!foo\n!foo/bar\n' >.gitignore
git commit -qam case2
gitstatus_query "$repo"
gitstatus_expect 11 0 num_unstaged
gitstatus_expect 13 1 num_untracked

# Git never re-includes a file under an excluded directory, so a nested
# negation under one is a no-op and the tree is clean
printf 'build/\n' >.gitignore
rm -rf foo
git commit -qam parent
mkdir build
touch build/out
echo '!out' >build/.gitignore
gitstatus_query "$repo"
gitstatus_expect 11 0 num_unstaged
gitstatus_expect 13 0 num_untracked
