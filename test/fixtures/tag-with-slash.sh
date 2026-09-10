#!/bin/sh
#
# A tag named foo/bar is stored loose as refs/tags/foo/bar. gitstatusd only
# listed the top level of refs/tags, so it saw a directory called foo and no
# tag, until git pack-refs moved it into packed-refs where it was found.
# See https://github.com/romkatv/gitstatus/issues/254

set -ue
. "$(dirname -- "$0")/../lib.sh"

gitstatus_test_setup
trap gitstatus_test_cleanup EXIT

cd -- "$repo"
git init -q
echo 1 >a
git add a
git commit -qm one

git tag foo/bar
gitstatus_query "$repo"
gitstatus_expect 1 1 is_repo
gitstatus_expect 17 foo/bar tag

# Deeper nesting, and a tag that sorts after the nested one at the top level.
# gitstatusd reports the lexicographically last tag on the commit
git tag a/b/c
git tag foo/baz
gitstatus_query "$repo"
gitstatus_expect 17 foo/baz tag

# Packed and loose nested tags on the same commit, the loose one wins by name
git pack-refs --all
git tag foo/zed
gitstatus_query "$repo"
gitstatus_expect 17 foo/zed tag

# Deleting a nested loose tag falls back to the packed ones. git leaves the
# now empty refs/tags/foo/ directory behind on some versions, which is fine
git tag -d foo/zed >/dev/null
gitstatus_query "$repo"
gitstatus_expect 17 foo/baz tag
