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
  # Set here rather than in gitstatus_daemon, which runs in a pipeline subshell
  daemon_out="$work/daemon.out"
  : >"$daemon_out"
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

# For fixtures that need one daemon to see several requests (anything that
# depends on the repo cache). Pipe a producer into gitstatus_daemon, and have it
# call gitstatus_wait_responses N before mutating the repo again, since that's
# the only way to know the daemon has finished the previous request:
#
#   { printf 'a\037%s\036' "$repo"; gitstatus_wait_responses 1; ...; } | gitstatus_daemon
#   gitstatus_response 1
#   gitstatus_expect ...
gitstatus_daemon() {
  "$GITSTATUSD" $GITSTATUSD_ARGS >"$daemon_out" || {
    echo "gitstatusd exited with status $?"
    exit 1
  }
}

gitstatus_wait_responses() {
  i=0
  while [ "$(tr -cd '\036' <"$daemon_out" | wc -c)" -lt "$1" ]; do
    i=$((i + 1))
    if [ "$i" -gt 100 ]; then
      echo "timed out waiting for response $1"
      exit 1
    fi
    sleep 0.1
  done
}

# Loads the 1-based $1th response written by gitstatus_daemon into $resp
gitstatus_response() {
  resp="$(tr '\036' '\n' <"$daemon_out" | sed -n "$1{p;q;}" | tr -d '\n'; printf '\036')"
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
