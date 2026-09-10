#!/bin/sh
#
# In a SHA256 repo object ids are 64 hex digits, and packed-refs is written
# with them. gitstatusd's packed-refs parser assumed 40, so the first packed
# tag tripped a VERIFY and the whole request failed, which the prompt shows as
# "not a git repo". The commit hash field has to come back as 64 digits too.
# See https://github.com/romkatv/gitstatus/issues/411

set -ue
. "$(dirname -- "$0")/../lib.sh"

gitstatus_test_setup
trap gitstatus_test_cleanup EXIT

cd -- "$repo"
git init -q --object-format=sha256
echo 1 >a
git add a
git commit -qm one
head="$(git rev-parse HEAD)"
[ "${#head}" -eq 64 ] || { echo "expected a 64 digit hash, got $head"; exit 1; }

git tag loose-tag
gitstatus_query "$repo"
gitstatus_expect 1 1 is_repo
gitstatus_expect 3 "$head" commit
gitstatus_expect 17 loose-tag tag

git pack-refs --all
gitstatus_query "$repo"
gitstatus_expect 1 1 is_repo
gitstatus_expect 3 "$head" commit
gitstatus_expect 17 loose-tag tag

# Annotated tags get a peeled line in packed-refs, which is a second 64 digit
# id per entry
echo 2 >a
git commit -qam two
git tag -a annotated -m annotated
git pack-refs --all
gitstatus_query "$repo"
gitstatus_expect 1 1 is_repo
gitstatus_expect 3 "$(git rev-parse HEAD)" commit
gitstatus_expect 17 annotated tag

# A loose tag on top of a packed one on the same commit, so both parsers have
# to agree on what the id looks like
git tag zz-loose
gitstatus_query "$repo"
gitstatus_expect 17 zz-loose tag
