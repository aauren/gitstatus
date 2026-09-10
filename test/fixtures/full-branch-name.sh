#!/bin/sh
#
# The bundled prompts truncate branch names longer than 32 characters down to
# the first and last 12 with an ellipsis in between. GITSTATUS_USE_FULL_BRANCH_NAME=1
# turns that off. This exercises the real gitstatus.prompt.sh and
# gitstatus.prompt.zsh against the daemon under test, and is skipped for any
# shell that isn't installed.
# See https://github.com/romkatv/gitstatus/pull/483

set -ue
. "$(dirname -- "$0")/../lib.sh"

gitstatus_test_setup
trap gitstatus_test_cleanup EXIT

root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
branch=feature/a-branch-name-that-is-long-enough-to-be-truncated
truncated="feature/a-br…be-truncated"

cd -- "$repo"
git init -q
git checkout -qb "$branch"
echo 1 >a
git add a
git commit -qm one

# Prints GITSTATUS_PROMPT as computed by the given shell's prompt script. The
# plugins pick the daemon up from GITSTATUS_DAEMON, which has to be absolute,
# and bail out of non-interactive shells, so we force -i with rc files off.
# Paths go in via the environment because the zsh plugin reads $1 itself
export GITSTATUS_DAEMON="$GITSTATUSD" fixture_repo="$repo" fixture_out="$work/prompt"
fixture_cmd='
  source "$fixture_script" || exit 1
  cd -- "$fixture_repo" || exit 1
  gitstatus_prompt_update || exit 1
  printf "%s" "$GITSTATUS_PROMPT" >"$fixture_out"
  gitstatus_stop
'
export fixture_cmd

prompt_for() {
  rm -f -- "$fixture_out"
  case "$1" in
    bash)
      fixture_script="$root/gitstatus.prompt.sh"
      export fixture_script
      bash --norc -i -c "$fixture_cmd" 2>/dev/null
      ;;
    zsh)
      # gitstatus_start does setopt monitor, which needs a controlling tty, so
      # we run the interactive shell under zpty and just wait for it to exit.
      # zpty evals its arguments, hence the (q) to keep the body in one piece
      fixture_script="$root/gitstatus.prompt.zsh"
      export fixture_script
      zsh -f -c '
        zmodload zsh/zpty || exit 1
        zpty -b p zsh -f -i -c ${(q)fixture_cmd} || exit 1
        i=0
        while zpty -t p; do
          zpty -r p >/dev/null 2>&1
          (( ++i > 300 )) && { zpty -d p; exit 1; }
          sleep 0.1
        done
        zpty -d p
      ' 2>/dev/null
      ;;
  esac
  [ -f "$fixture_out" ] && cat -- "$fixture_out"
}

# $1 shell, $2 the substring the prompt must contain, $3 one it must not
expect_prompt() {
  out="$(prompt_for "$1")" || {
    echo "$1: prompt script failed (${GITSTATUS_USE_FULL_BRANCH_NAME:-unset})"
    exit 1
  }
  case "$out" in
    *"$2"*) ;;
    *)
      echo "$1 (GITSTATUS_USE_FULL_BRANCH_NAME=${GITSTATUS_USE_FULL_BRANCH_NAME:-unset}): expected '$2' in prompt"
      echo "prompt: $out"
      exit 1
      ;;
  esac
  case "$out" in
    *"$3"*)
      echo "$1 (GITSTATUS_USE_FULL_BRANCH_NAME=${GITSTATUS_USE_FULL_BRANCH_NAME:-unset}): did not expect '$3' in prompt"
      echo "prompt: $out"
      exit 1
      ;;
  esac
}

for shell in bash zsh; do
  if ! command -v "$shell" >/dev/null 2>&1; then
    echo "skipping $shell: not installed"
    continue
  fi

  unset GITSTATUS_USE_FULL_BRANCH_NAME
  expect_prompt "$shell" "$truncated" "$branch"

  # Anything other than 1 keeps the default, so a stray 0 doesn't turn it on
  GITSTATUS_USE_FULL_BRANCH_NAME=0
  export GITSTATUS_USE_FULL_BRANCH_NAME
  expect_prompt "$shell" "$truncated" "$branch"

  GITSTATUS_USE_FULL_BRANCH_NAME=1
  expect_prompt "$shell" "$branch" "$truncated"
done
