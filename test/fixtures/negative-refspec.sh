#!/bin/sh
#
# A negative fetch refspec (^refs/heads/*-deploy) in remote.origin.fetch made
# the libgit2 fork gitstatusd shipped fail to parse the remote, so the
# upstream and push remote fields all came back empty while git status still
# showed master...origin/master. Expectations below match git status -sb and
# <branch>@{push} for the same config.
# See https://github.com/romkatv/gitstatus/issues/438

set -ue
. "$(dirname -- "$0")/../lib.sh"

gitstatus_test_setup
trap gitstatus_test_cleanup EXIT

git init -q --bare "$work/origin.git"
git clone -q "$work/origin.git" "$repo" 2>/dev/null
cd -- "$repo"
echo 1 >a
git add a
git commit -qm one
git push -q origin master
git push -q origin master:master-deploy
echo 2 >a
git commit -qam two
git push -q origin master
git reset -q --hard HEAD~1

expect_upstream() {
  gitstatus_expect 5 "$1" remote_branch
  gitstatus_expect 6 "$2" remote_name
  gitstatus_expect 14 "$3" ahead
  gitstatus_expect 15 "$4" behind
}

expect_push() {
  gitstatus_expect 21 "$1" push_remote_name
  gitstatus_expect 23 "$2" push_ahead
  gitstatus_expect 24 "$3" push_behind
}

# Control, before the negative refspecs
gitstatus_query "$repo"
gitstatus_expect 1 1 is_repo
expect_upstream master origin 0 1

# The config from the issue
git config --add remote.origin.fetch '^refs/heads/*-deploy'
git config --add remote.origin.fetch '^refs/tags/*-deploy'
git config remote.origin.tagOpt --tags
git fetch -q -p origin
gitstatus_query "$repo"
expect_upstream master origin 0 1
expect_push "" 0 0

# The push remote maps through the same refspec list
git config remote.pushDefault origin
gitstatus_query "$repo"
expect_upstream master origin 0 1
expect_push origin 0 1

# A branch the negative refspec excludes gets no upstream from checkout, but
# git still resolves its @{push} through the positive refspec
git checkout -q -b master-deploy origin/master-deploy 2>/dev/null
gitstatus_query "$repo"
gitstatus_expect 4 master-deploy branch
expect_upstream "" "" 0 0
expect_push origin 0 0

# Order in the config shouldn't matter
git checkout -q master
git config --unset-all remote.origin.fetch
git config --add remote.origin.fetch '^refs/heads/*-deploy'
git config --add remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
gitstatus_query "$repo"
expect_upstream master origin 0 1
expect_push origin 0 1
