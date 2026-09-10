#!/bin/sh
#
# libgit2 can't parse a split index (the mandatory 'link' extension), and
# gitstatusd used to turn that into "not a repo", so the prompt lost the branch
# name and everything else along with the dirty state. Now it answers as if
# the request had disabled index computations and says so in field 30.
# Covers both the first open of the index and a cached index that becomes
# unreadable later, since the daemon is long-lived and the PR only did the
# former.
# See https://github.com/romkatv/gitstatus/pull/419

set -ue
. "$(dirname -- "$0")/../lib.sh"

gitstatus_test_setup
trap gitstatus_test_cleanup EXIT

cd -- "$repo"
git init -q
echo 1 >a
git add a
git commit -qm one
echo 2 >b
git add b
echo 3 >c

split() { git -c core.splitIndex=true update-index --split-index; }
unsplit() { git update-index --no-split-index; }

split
{
  printf '1\037%s\036' "$repo"
  gitstatus_wait_responses 1
  unsplit
  printf '2\037%s\036' "$repo"
  gitstatus_wait_responses 2
  split
  printf '3\037%s\036' "$repo"
  gitstatus_wait_responses 3
  unsplit
  printf '4\037%s\036' "$repo"
} | gitstatus_daemon

expect_disabled() {
  gitstatus_expect 1 1 is_repo
  gitstatus_expect 4 master local_branch
  gitstatus_expect 9 0 index_size
  gitstatus_expect 10 0 num_staged
  gitstatus_expect 13 0 num_untracked
  gitstatus_expect 29 1 index_disabled
}

expect_enabled() {
  gitstatus_expect 1 1 is_repo
  gitstatus_expect 4 master local_branch
  gitstatus_expect 9 2 index_size
  gitstatus_expect 10 1 num_staged
  gitstatus_expect 13 1 num_untracked
  gitstatus_expect 29 0 index_disabled
}

# Split from the start: git_repository_index() fails on first open
gitstatus_response 1
expect_disabled

gitstatus_response 2
expect_enabled

# Split after the daemon has the index cached: git_index_read_ex() fails
gitstatus_response 3
expect_disabled

# And the daemon recovers once the index is readable again
gitstatus_response 4
expect_enabled
