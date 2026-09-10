#!/bin/sh
#
# Upstream and push remote resolution. The upstream comes from branch.<name>.remote
# and branch.<name>.merge mapped through the remote's fetch refspecs, and the
# push remote from branch.<name>.pushRemote, then remote.pushDefault, with no
# fallback to the upstream remote. "." means the local repository in both.
# gitstatusd used to lean on romkatv/libgit2's git_branch_remote and
# git_branch_push_remote for this, so this pins the behaviour down for the port
# to upstream libgit2.

set -ue
. "$(dirname -- "$0")/../lib.sh"

gitstatus_test_setup
trap gitstatus_test_cleanup EXIT

# origin ends up with master and feature at three commits. mirror only has the
# first one, fetched into a non-default refs/remotes namespace so the refspec
# mapping actually has to do some work.
git init -q --bare "$work/origin.git"
git init -q --bare "$work/mirror.git"
git clone -q "$work/origin.git" "$repo" 2>/dev/null
cd -- "$repo"
echo 1 >a
git add a
git commit -qm one
git push -q origin master
git push -q "$work/mirror.git" master
echo 2 >a
git commit -qam two
git push -q origin master
git remote add mirror "$work/mirror.git"
git config remote.mirror.fetch '+refs/heads/*:refs/remotes/mirror-refs/*'
git fetch -q mirror

# Leave master one commit ahead of and one behind origin, and two ahead of mirror
echo 3 >a
git commit -qam three
git push -q origin master
git push -q origin master:feature
git reset -q --hard HEAD~1
git commit -q --allow-empty -m four

expect_upstream() {
  gitstatus_expect 5 "$1" remote_branch
  gitstatus_expect 6 "$2" remote_name
  gitstatus_expect 7 "$3" remote_url
  gitstatus_expect 14 "$4" ahead
  gitstatus_expect 15 "$5" behind
}

expect_push() {
  gitstatus_expect 21 "$1" push_remote_name
  gitstatus_expect 22 "$2" push_remote_url
  gitstatus_expect 23 "$3" push_ahead
  gitstatus_expect 24 "$4" push_behind
}

# Upstream only, no push config anywhere
gitstatus_query "$repo"
gitstatus_expect 1 1 is_repo
gitstatus_expect 4 master local_branch
expect_upstream master origin "$work/origin.git" 1 1
expect_push "" "" 0 0

# branch.<name>.pushRemote wins and goes through mirror's custom fetch refspec
git config branch.master.pushremote mirror
gitstatus_query "$repo"
expect_upstream master origin "$work/origin.git" 1 1
expect_push mirror "$work/mirror.git" 2 0

# remote.pushDefault is the fallback
git config --unset branch.master.pushremote
git config remote.pushdefault mirror
gitstatus_query "$repo"
expect_push mirror "$work/mirror.git" 2 0

# pushRemote beats pushDefault when both are set
git config branch.master.pushremote origin
gitstatus_query "$repo"
expect_push origin "$work/origin.git" 1 1
git config --unset branch.master.pushremote
git config --unset remote.pushdefault

# A push remote without a tracking ref for this branch counts as no push remote,
# and a branch without an upstream has no upstream fields
git checkout -qb topic
git config branch.topic.pushremote origin
gitstatus_query "$repo"
gitstatus_expect 4 topic local_branch
expect_upstream "" "" "" 0 0
expect_push "" "" 0 0

# "." is the local repository for both. A "." push remote pushes the branch to
# itself, so its counts are always 0
git checkout -qb local-track --track master 2>/dev/null
gitstatus_query "$repo"
expect_upstream master . "" 0 0
expect_push "" "" 0 0
git config branch.local-track.pushremote .
git commit -q --allow-empty -m five
gitstatus_query "$repo"
expect_upstream master . "" 1 0
expect_push . "" 0 0

# Slashes in the local and upstream branch names
git checkout -qb with/slash --track origin/feature 2>/dev/null
gitstatus_query "$repo"
gitstatus_expect 4 with/slash local_branch
expect_upstream feature origin "$work/origin.git" 0 0
