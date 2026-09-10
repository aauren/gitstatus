# Helpers for fixtures under test/fixtures/. Sourced by each fixture, POSIX sh
# only because the gate builds run on busybox (alpine) and darwin.

# Each fixture gets a scratch dir with a hermetic git config so host settings
# (signing, hooks, default branch) can't leak into the repo it builds
gitstatus_test_setup() {
  work="$(mktemp -d "${TMPDIR:-/tmp}/gitstatus-test.XXXXXXXXXX")"
  export HOME="$work"
  export GIT_CONFIG_NOSYSTEM=1
  printf '[init]\n  defaultBranch = master\n[user]\n  name = Test\n  email = test@example.com\n[commit]\n  gpgsign = false\n' >"$work/.gitconfig"
  repo="$work/repo"
  mkdir -- "$repo"
}

gitstatus_test_cleanup() {
  # Step out of the scratch dir before removing it
  cd -- "${work%/*}"
  rm -rf -- "$work"
}

# Sends one request for $1 and stores the raw response in $resp. Exits the
# fixture with a failure if the daemon dies, which is the bug class we care about
gitstatus_query() {
  status=0
  resp="$(printf 'req\037%s\036' "$1" | "$GITSTATUSD" $GITSTATUSD_ARGS)" || status=$?
  if [ "$status" -ne 0 ]; then
    echo "gitstatusd exited with status $status"
    exit 1
  fi
}

# Prints 0-based field $1 of $resp, using the same numbering as the shell bindings
gitstatus_field() {
  printf '%s' "${resp%?}" | tr '\037' '\n' | sed -n "$(($1 + 1))p"
}

gitstatus_expect() {
  actual="$(gitstatus_field "$1")"
  if [ "$actual" != "$2" ]; then
    echo "field $1 ($3): expected '$2', got '$actual'"
    echo "response: $(printf '%s' "$resp" | tr '\036\037' '\n|')"
    exit 1
  fi
}
