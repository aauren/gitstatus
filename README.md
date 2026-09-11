# gitstatus

**gitstatus** is a 10x faster alternative to `git status` and `git describe`. Its primary use
case is to enable fast git prompt in interactive shells.

Heavy lifting is done by **gitstatusd** -- a custom binary written in C++. It comes with Zsh and
Bash bindings for integration with shell.

## Current State

This is a fork of [romkatv/gitstatus](https://github.com/romkatv/gitstatus). Upstream has been on
life support for a while (its README says so, most bugs go unfixed and no new features are in the
works), and the libgit2 it builds against is a 2019-era fork with a use-after-free that crashes the
daemon on any current musl. I started this fork because I wanted my own prompt to stop dying, and
it grew from there into moving gitstatusd onto a current libgit2 with a real build and test story.

I'm primarily doing this for myself. I'm happy if other people find it useful, but I'm not sure I
will ever cut release builds, and bug fixing is at my discretion. If you use it, be prepared to
build it yourself (`./build -w -s -d docker`, see [Compiling](#compiling)) and to read the code
when something goes wrong.

As far as I know this is the only fork that keeps romkatv's libgit2 patches rather than dropping
them. Those patches are where most of the speed comes from (sharded diffs, lazy ignore frames,
`fstatat` instead of `lstat`, and a pile of thread-safety fixes), so instead of porting gitstatusd
to vanilla libgit2, I rebased the patches onto upstream libgit2 `main` one at a time, keeping the
ones that still mattered and dropping the ones upstream had since fixed or rewritten. The result
lives at [aauren/libgit2](https://github.com/aauren/libgit2) on the `modernize` branch, 31 commits
on top of upstream, and gets you SHA256 repositories, reftable, `extensions.worktreeConfig`,
negative refspecs, and every upstream libgit2 fix from the last six years. On top of that this fork
carries the open upstream PRs I wanted (#357, #419, #467, #483), fixes for #59, #107, #254, #365,
#411, #474, #486 and #489, and a C++20 / CMake build with `asan` and `tsan` presets and a fixture
suite under `test/` that checks every one of those against `git status`.

I should be upfront about how the work was done: nearly all of the modernization in this repo was
written by AI under close direction, with every change read, tested, and benchmarked before it
landed. It's still AI. Don't expect a deeply knowledgeable C++ or libgit2 developer behind this
project. I stand on the shoulders of romkatv, of the upstream libgit2 maintainers, and of the
people whose ports and PRs I borrowed from:

* [simnalamburt](https://github.com/simnalamburt/gitstatus) and
  [zzJinux](https://github.com/zzJinux/gitstatus/tree/with-libgit2-v1.9.2-custom), whose ports of
  gitstatusd to vanilla libgit2 mapped out which fork-only APIs had upstream equivalents. I took a
  different route with libgit2 itself, but their commits were the guide for the gitstatusd side.
* [druckdev](https://github.com/romkatv/gitstatus/pull/467) (tags in linked worktrees),
  [puqeko](https://github.com/romkatv/gitstatus/pull/419) (don't crash on an unreadable index),
  [orn688](https://github.com/romkatv/gitstatus/pull/357) (respect `submodule.<name>.ignore`), and
  [chiphogg](https://github.com/romkatv/gitstatus/pull/483) (`GITSTATUS_USE_FULL_BRANCH_NAME`),
  whose upstream PRs are carried here more or less as written.

The whole point of gitstatus is speed, so I measured rather than assumed. The
[modernization benchmarks](#modernization-benchmarks) below compare the shipped static binary
before and after the libgit2 rebase on a large dirty repository, which is the case where a prompt
is actually slow. The short version is that dirty trees got 16 to 25% faster and clean trees at
high thread counts pay under a millisecond for a libgit2 that is six years newer.

## Table of Contents

1. [Current State](#current-state)
1. [Using from Zsh](#using-from-zsh)
1. [Using from Bash](#using-from-bash)
2. [Using from other shells](#using-from-other-shells)
1. [How it works](#how-it-works)
1. [Benchmarks](#benchmarks)
1. [Why fast](#why-fast)
1. [Requirements](#requirements)
1. [Compiling](#compiling)
1. [License](#license)

## Using from Zsh

The easiest way to take advantage of gitstatus from Zsh is to use a theme that's already integrated
with it. For example, [Powerlevel10k](https://github.com/romkatv/powerlevel10k) is a flexible and
fast theme with first-class gitstatus integration. If you install Powerlevel10k, you don't need to
install gitstatus.

![Powerlevel10k Zsh Theme](
  https://raw.githubusercontent.com/romkatv/powerlevel10k-media/master/prompt-styles-high-contrast.png)

For those who wish to use gitstatus without a theme, there is
[gitstatus.prompt.zsh](gitstatus.prompt.zsh). Install it as follows:

```zsh
git clone --depth=1 https://github.com/aauren/gitstatus.git ~/gitstatus
(cd ~/gitstatus && ./build -w -s -d docker)
echo 'source ~/gitstatus/gitstatus.prompt.zsh' >>! ~/.zshrc
```

There are no prebuilt binaries for this fork and the shell bindings won't download any, so the
`./build` step isn't optional. See [Compiling](#compiling) for what the flags do and what to drop
if one of them doesn't apply to your system.

_Make sure to disable your current theme if you have one._

This will give you a basic yet functional prompt with git status in it. It's
[over 10x faster](#benchmarks) than any alternative that can give you comparable prompt. In order
to customize it, set `PROMPT` and/or `RPROMPT` at the end of `~/.zshrc` after sourcing
`gitstatus.prompt.zsh`. Insert `${GITSTATUS_PROMPT}` where you want git status to go. For example:

```zsh
source ~/gitstatus/gitstatus.prompt.zsh

PROMPT='%~%# '               # left prompt: directory followed by %/# (normal/root)
RPROMPT='$GITSTATUS_PROMPT'  # right prompt: git status
```

The expansion of `${GITSTATUS_PROMPT}` can contain the following bits:

| segment     |  meaning                                              |
|-------------|-------------------------------------------------------|
| `master`    | current branch                                        |
| `#v1`       | HEAD is tagged with `v1`; not shown when on a branch  |
| `@5fc6fca4` | current commit; not shown when on a branch or tag     |
| `⇣1`        | local branch is behind the remote by 1 commit         |
| `⇡2`        | local branch is ahead of the remote by 2 commits      |
| `⇠3`        | local branch is behind the push remote by 3 commits   |
| `⇢4`        | local branch is ahead of the push remote by 4 commits |
| `*5`        | there are 5 stashes                                   |
| `merge`     | merge is in progress (could be some other action)     |
| `~6`        | there are 6 merge conflicts                           |
| `+7`        | there are 7 staged changes                            |
| `!8`        | there are 8 unstaged changes                          |
| `?9`        | there are 9 untracked files                           |

Branch names and tags longer than 32 characters get truncated in the middle. To see the full
name instead, export `GITSTATUS_USE_FULL_BRANCH_NAME=1` in `~/.zshrc` before sourcing
`gitstatus.prompt.zsh`.

`$GITSTATUS_PROMPT_LEN` tells you how long `$GITSTATUS_PROMPT` is when printed to the console.
[gitstatus.prompt.zsh](gitstatus.prompt.zsh) has an example of using it to truncate the current
directory.

If you'd like to change the format of git status, or want to have greater control over the
process of assembling `PROMPT`, you can copy and modify parts of
[gitstatus.prompt.zsh](gitstatus.prompt.zsh) instead of sourcing the script. Your `~/.zshrc`
might look something like this:

```zsh
source ~/gitstatus/gitstatus.plugin.zsh

function my_set_prompt() {
  PROMPT='%~%# '
  RPROMPT=''

  if gitstatus_query MY && [[ $VCS_STATUS_RESULT == ok-sync ]]; then
    RPROMPT=${${VCS_STATUS_LOCAL_BRANCH:-@${VCS_STATUS_COMMIT}}//\%/%%}  # escape %
    (( VCS_STATUS_NUM_STAGED    )) && RPROMPT+='+'
    (( VCS_STATUS_NUM_UNSTAGED  )) && RPROMPT+='!'
    (( VCS_STATUS_NUM_UNTRACKED )) && RPROMPT+='?'
  fi

  setopt no_prompt_{bang,subst} prompt_percent  # enable/disable correct prompt expansions
}

gitstatus_stop 'MY' && gitstatus_start -s -1 -u -1 -c -1 -d -1 'MY'
autoload -Uz add-zsh-hook
add-zsh-hook precmd my_set_prompt
```

This snippet is sourcing `gitstatus.plugin.zsh` rather than `gitstatus.prompt.zsh`. The former
defines low-level bindings that communicate with gitstatusd over pipes. The latter is a simple
script that uses these bindings to assemble git prompt.

Unlike [Powerlevel10k](https://github.com/romkatv/powerlevel10k), code based on
[gitstatus.prompt.zsh](gitstatus.prompt.zsh) is communicating with gitstatusd synchronously. This
can make your prompt slow when working in a large git repository or on a slow machine. To avoid
this problem, call `gitstatus_query` asynchronously as documented in
[gitstatus.plugin.zsh](gitstatus.plugin.zsh). This can be quite challenging.

## Using from Bash

The easiest way to take advantage of gitstatus from Bash is via
[gitstatus.prompt.sh](gitstatus.prompt.sh). Install it as follows:

```bash
git clone --depth=1 https://github.com/aauren/gitstatus.git ~/gitstatus
(cd ~/gitstatus && ./build -w -s -d docker)
echo 'source ~/gitstatus/gitstatus.prompt.sh' >> ~/.bashrc
```

As with Zsh, the `./build` step is required since there are no prebuilt binaries for this fork.
See [Compiling](#compiling).

This will give you a basic yet functional prompt with git status in it. It's
[over 10x faster](#benchmarks) than any alternative that can give you comparable prompt.

![Bash Prompt with GitStatus](
  https://raw.githubusercontent.com/romkatv/gitstatus/1ac366952366d89980b3f3484f270b4fa5ae4293/bash-prompt.png)

In order to customize your prompt, set `PS1` at the end of `~/.bashrc` after sourcing
`gitstatus.prompt.sh`. Insert `${GITSTATUS_PROMPT}` where you want git status to go. For example:

```bash
source ~/gitstatus/gitstatus.prompt.sh

PS1='\w ${GITSTATUS_PROMPT}\n\$ ' # directory followed by git status and $/# (normal/root)
```

The expansion of `${GITSTATUS_PROMPT}` can contain the following bits:

| segment     |  meaning                                              |
|-------------|-------------------------------------------------------|
| `master`    | current branch                                        |
| `#v1`       | HEAD is tagged with `v1`; not shown when on a branch  |
| `@5fc6fca4` | current commit; not shown when on a branch or tag     |
| `⇣1`        | local branch is behind the remote by 1 commit         |
| `⇡2`        | local branch is ahead of the remote by 2 commits      |
| `⇠3`        | local branch is behind the push remote by 3 commits   |
| `⇢4`        | local branch is ahead of the push remote by 4 commits |
| `*5`        | there are 5 stashes                                   |
| `merge`     | merge is in progress (could be some other action)     |
| `~6`        | there are 6 merge conflicts                           |
| `+7`        | there are 7 staged changes                            |
| `!8`        | there are 8 unstaged changes                          |
| `?9`        | there are 9 untracked files                           |

Branch names and tags longer than 32 characters get truncated in the middle. To see the full
name instead, export `GITSTATUS_USE_FULL_BRANCH_NAME=1` in `~/.bashrc` before sourcing
`gitstatus.prompt.sh`.

If you'd like to change the format of git status, or want to have greater control over the
process of assembling `PS1`, you can copy and modify parts of
[gitstatus.prompt.sh](gitstatus.prompt.sh) instead of sourcing the script. Your `~/.bashrc` might
look something like this:

```bash
source ~/gitstatus/gitstatus.plugin.sh

function my_set_prompt() {
  PS1='\w'

  if gitstatus_query && [[ "$VCS_STATUS_RESULT" == ok-sync ]]; then
    if [[ -n "$VCS_STATUS_LOCAL_BRANCH" ]]; then
      PS1+=" ${VCS_STATUS_LOCAL_BRANCH//\\/\\\\}"  # escape backslash
    else
      PS1+=" @${VCS_STATUS_COMMIT//\\/\\\\}"       # escape backslash
    fi
    (( VCS_STATUS_HAS_STAGED"    )) && PS1+='+'
    (( VCS_STATUS_HAS_UNSTAGED"  )) && PS1+='!'
    (( VCS_STATUS_HAS_UNTRACKED" )) && PS1+='?'
  fi

  PS1+='\n\$ '

  shopt -u promptvars  # disable expansion of '$(...)' and the like
}

gitstatus_stop && gitstatus_start
PROMPT_COMMAND=my_set_prompt
```

This snippet is sourcing `gitstatus.plugin.sh` rather than `gitstatus.prompt.sh`. The former
defines low-level bindings that communicate with gitstatusd over pipes. The latter is a simple
script that uses these bindings to assemble git prompt.

Note: Bash bindings, unlike Zsh bindings, don't support asynchronous calls.

## Using from other shells

If there are no gitstatusd bindings for your shell, you'll need to get your hands dirty.
Use the existing bindings for inspiration; run `gitstatusd --help` or read the same thing in
[options.cc](src/options.cc).

## How it works

gitstatusd reads requests from stdin and prints responses to stdout. Requests contain an ID and
a directory. Responses contain the same ID and machine-readable git status for the directory.
gitstatusd keeps some state in memory for the directories it has seen in order to serve future
requests faster.

[Zsh bindings](gitstatus.plugin.zsh) and [Bash bindings](gitstatus.plugin.sh) start gitstatusd in
the background and communicate with it via pipes. Themes such as
[Powerlevel10k](https://github.com/romkatv/powerlevel10k) use these bindings to put git status in
`PROMPT`.

Note that gitstatus cannot be used as a drop-in replacement for `git status` command as it doesn't
produce output in the same format. It does perform the same computation though.

## Benchmarks

The following benchmark results were obtained on Intel i9-7900X running Ubuntu 18.04 in
a clean [chromium](https://github.com/chromium/chromium) repository synced to `9394e49a`. The
repository was checked out to an ext4 filesystem on M.2 SSD.

Three functionally equivalent tools for computing git status were benchmarked:

* `gitstatusd`
* `git` with `core.untrackedcache` enabled and `core.fsmonitor` disabled
* `lg2` -- a demo/example executable from [libgit2](https://github.com/romkatv/libgit2) that
  implements a subset of `git` functionality on top of libgit2 API; for the purposes of this
  benchmark the subset is sufficient to generate the same data as the other tools

Every tool was benchmark in cold and hot conditions. For `git` the first run in a repository was
considered cold, with the following runs considered hot. `lg2` was patched to compute results twice
in a single invocation without freeing the repository in between; the second run was considered hot.
The same patching was not done for `git` because `git` cannot be easily modified to refresh inmemory
index state between invocations; in fact, this limitation is one of the primary reasons developers
use libgit2. `gitstatusd` was benchmarked similarly to `lg2` with two result computations in the
same invocation.

Two commands were benchmarked: `status` and `describe`.

### Status

In this benchmark all tools were computing the equivalent of `git status`. Lower numbers are better.

| Tool          |      Cold  |         Hot |
|---------------|-----------:|------------:|
| **gitstatus** | **291 ms** | **30.9 ms** |
| git           |     876 ms |      295 ms |
| lg2           |    1730 ms |     1310 ms |

gitstatusd is substantially faster than the alternatives, especially on hot runs. Note that hot runs
are of primary importance to the main use case of gitstatus in interactive shells.

The performance of `git status` fluctuated wildly in this benchmarks for reasons unknown to the
author. Moreover, performance is sticky -- once `git status` settles around a number, it stays
there for a long time. Numbers as diverse as 295, 352, 663 and 730 had been observed on hot runs on
the same repository. The number in the table is the lowest (fastest or best) that `git status` had
shown.

### Describe

In this benchmark all tools were computing the equivalent of `git describe --tags --exact-match`
to find tags that resolve to the same commit as `HEAD`. Lower numbers are better.

| Tool          |       Cold  |           Hot |
|---------------|------------:|--------------:|
| **gitstatus** | **4.04 ms** | **0.0345 ms** |
| git           |     18.0 ms |       14.5 ms |
| lg2           |      185 ms |       45.2 ms |

gitstatusd is once again faster than the alternatives, more so on hot runs.

### Modernization benchmarks

The numbers above are romkatv's, from the original libgit2 fork. The rebase onto current libgit2
had to hold that line, so I benchmarked the shipped static binary before and after with
[test/bench.sh](test/bench.sh), which drives the daemon over its own protocol and times the warm
requests (a cached repository and index, an incremental scan). "Before" is `v1.5.6-aauren.1`,
romkatv's code plus the use-after-free fix, built against his libgit2 at `2ecf3394`. "After" is
`v2.0.0-dev` at the end of the libgit2 rebase. Both are `alpine:latest` static-pie builds run on
the same machine, back to back, in both orders.

The important workload is a dirty tree, because on a clean tree the warm time is gitstatusd's own
directory scan and libgit2 barely runs. This one is a `/tmp` copy of
[kubernetes](https://github.com/kubernetes/kubernetes) with about 2000 modified, 500 staged, 5000
mtime-only touched and 3300 untracked files and `* text=auto` in `.gitattributes`. `-t` is the
daemon's thread count; the shell bindings default to twice the CPU count, capped at 32. Warm
microseconds per request,
lower is better:

| Workload                                     |    `-t 1` before |     `-t 1` after |   `-t 32` before |    `-t 32` after |
|----------------------------------------------|-----------------:|-----------------:|-----------------:|-----------------:|
| dirty kubernetes, default config             |          815,000 | 609,000 (-25%)   |          284,000 | 239,000 (-16%)   |
| dirty kubernetes, `core.safecrlf=warn`       |          810,000 | 814,000 (flat)   |          268,000 | 286,000 (+6%)    |
| clean linux                                  |             flat |             flat |           10,700 | 11,400 (+0.7 ms) |
| clean kubernetes                             |             flat |             flat |            7,400 | 8,000 (+0.6 ms)  |
| clean cilium                                 |             flat |             flat |            6,100 | 6,700 (+0.6 ms)  |

Two of those rows needed work to get there. The first rebased build was 1.9x *slower* on the dirty
tree at `-t 32` with identical single-threaded time, which turned out to be upstream libgit2
holding `git_odb.lock` as a mutex across every object read, so 32 shards hashing files serialized
on it. That lock is a rwlock in the fork now, and `crlf_apply_to_odb()` skips the index blob lookup
when the buffer has no CR and `core.safecrlf` is unset, which is where the 25% on the default-config
row comes from. The `safecrlf` row is the same workload with that shortcut disabled, so it shows the
rest of the rebase is a wash on libgit2-heavy work.

The clean-tree cost at high thread counts is malloc and the per-request config snapshot (upstream's
`git_config_snapshot` stats every config file and copies every entry), and it is the "small
regression" I was willing to take. Every later phase (SHA256 and reftable in the tag reader, C++20,
CMake, the fixture suite) was benchmarked the same way against the phase before it and came out
flat, with run order moving the numbers more than the binary did.

## Why fast

Since gitstatusd doesn't have to print all staged/unstaged/untracked files but only report
whether there are any, it can terminate repository scan early. It can also remember which files
were dirty on the previous run and check them first on the next run to avoid the scan entirely if
the files are still dirty. However, the benchmarks above were performed in a clean repository where
these shortcuts do not trigger. All benchmarked tools had to do the same work -- check the status
of every file in the index to see if it has changed, check every directory for newly created files,
etc. And yet, gitstatusd came ahead by a large margin. This section describes what it does that
makes it so fast.

Most of the following comparisons are done against libgit2 rather than git because of the author's
familiarity with the former but not the with latter. libgit2 has clean, well-documented APIs and an
elegant implementation, which makes it so much easier to work with and to analyze performance
bottlenecks.

### Summary for the impatient

Under the benchmark conditions described above, the equivalent of libgit2's
`git_diff_index_to_workdir` (the most expensive part of `status` command) is 46.3 times faster in
gitstatusd. The speedup comes from the following sources.

* gitstatusd uses more efficient data structures and algorithms and employs performance-conscious
coding style throughout the codebase. This reduces CPU time in userspace by 32x compared to libgit2.
* gitstatusd uses less expensive system calls and makes fewer of them. This reduces CPU time spent
in kernel by 1.9x.
* gitstatusd can utilize multiple cores to scan index and workdir in parallel with almost perfect
scaling. This reduces total run time by 12.4x while having virtually no effect on total CPU time.

### Problem statement

The most resource-intensive part of the `status` command is finding the difference between _index_
and _workdir_ (`git_diff_index_to_workdir` in libgit2). Index is a list of all files in the git
repository with their last modification times. This is an obvious simplification but it suffices for
this exposition. On disk, index is stored sorted by file path. Here's an example of git index:

| File        | Last modification time |
|-------------|-----------------------:|
| Makefile    |   2019-04-01T14:12:32Z |
| src/hello.c |   2019-04-01T14:12:00Z |
| src/hello.h |   2019-04-01T14:12:32Z |

This list needs to be compared to the list of files in the working directory. If any of the files
listed in the index are missing from the workdir or have different last modification time, they are
"unstaged" in gitstatusd parlance. If you run `git status`, they'll be shown as "changes not staged
for commit". Thus, any implementation of `status` command has to call `stat()` or one of its
variants on every file in the index.

In addition, all files in the working directory for which there is no entry in the index at all are
"untracked". `git status` will show them as "untracked files". Finding untracked files requires some
form of work directory traversal.

### Single-threaded scan

Let's see how `git_diff_index_to_workdir` from libgit2 accomplishes these tasks. Here's its CPU
profile from 200 hot runs over chromium repository.

![libgit2 CPU profile (hot)](
  https://raw.githubusercontent.com/romkatv/gitstatus/1ac366952366d89980b3f3484f270b4fa5ae4293/cpu-profile-libgit2.png)

(The CPU profile was created with [gperftools](https://github.com/gperftools/gperftools) and
rendered with [pprof](https://github.com/google/pprof)).

We can see `__GI__lxstat` taking a lot of time. This is the `stat()` call for every file in the
index. We can also identify `__opendir`, `__readdir` and `__GI___close_nocancel` -- glibc wrappers
for reading the contents of a directory. This is for finding untracked files. Out of the total 232
seconds, 111 seconds -- or 47.7% -- was spent on these calls. The rest is computation -- comparing
strings, sorting arrays, etc.

Now let's take a look at the CPU profile of gitstatusd on the same task.

![gitstatusd CPU profile (hot)](
  https://raw.githubusercontent.com/romkatv/gitstatus/1ac366952366d89980b3f3484f270b4fa5ae4293/cpu-profile-gitstatusd-hot.png)

The first impression is that this profile looks pruned. This isn't an artifact. The profile was
generated with the same tools and the same flags as the profile of libgit2.

Since both profiles were generated from the same workload, absolute numbers can be compared. We can
see that gitstatusd took 62 seconds in total compared to libgit2's 232 seconds. System calls at the
core of the algorithm are clearly visible. `__GI___fxstatat` is a flavor of `stat()`, and the other
three calls -- `__libc_openat64`, `__libc_close` and `__GI___fxstat` are responsible for opening
directories and finding untracked files. Notice that there is almost nothing else in the profile
apart from these calls. The rest of the code accounts for 3.77 seconds of CPU time -- 32 times less
than in libgit2.

So, one reason gitstatusd is fast is that it has efficient diffing code -- very little time is spent
outside of kernel. However, if we look closely, we can notice that system calls in gitstatusd are
_also_ faster than in libgit2. For example, libgit2 spent 72.07 seconds in `__GI__lxstat` while
gitstatusd spent only 48.82 seconds in `__GI___fxstatat`. There are two reasons for this difference.
First, libgit2 makes more `stat()` calls than is strictly required. It's not necessary to stat
directories because index only has files. There are 25k directories in chromium repository (and 300k
files) -- that's 25k `stat()` calls that could be avoided. The second reason is that libgit2 and
gitstatusd use different flavors of `stat()`. libgit2 uses `lstat()`, which takes a path to the file
as input. Its performance is linear in the number of subdirectories in the path because it needs to
perform a lookup for every one of them and to check permissions. gitstatusd uses `fstatat()`, which
takes a file descriptor to the parent directory and a name of the file. Just a single lookup, less
CPU time.

Similarly to `lstat()` vs `fstatat()`, it's faster to open files and directories with `openat()`
from the parent directory file descriptor than with regular `open()` that accepts full file path.
gitstatusd takes advantage of `openat()` to open directories as fast as possible. It opens about 90%
of the directories (this depends on the actual directory structure of the repository) from the
immediate parent -- the most efficient way -- and the remaining 10% it opens from the repository's
root directory. The reason it's done this way is to keep the maximum number of simultaneously open
file descriptors bounded. libgit2 can have O(repository depth) simultaneously open file descriptors,
which may be OK for a single-threaded application but can balloon to a large number when scans are
done by many threads simultaneously, like in gitstatusd.

There is no equivalent to `__opendir` or `__readdir` in the gitstatusd profile because it uses the
equivalent of [untracked cache](https://git-scm.com/docs/git-update-index#_untracked_cache) from
git. On the first scan of the workdir gitstatusd lists all files just like libgit2. But, unlike
libgit2, it remembers the last modification time of every directory along with the list of
untracked files under it. On the next scan, gitstatusd can skip listing files in directories whose
last modification time hasn't changed.

To summarize, here's what gitstatusd was doing when the CPU profile was captured:

1. `__libc_openat64`: Open every directory for which there are files in the index.
2. `__GI___fxstat`: Check last modification time of the directory. Since it's the same as on the
   last scan, this directory has the same list of untracked files as before, which is empty (the
   repository is clean).
3. `__GI___fxstatat`: Check last modification time for every file in the index that belongs to this
   directory.
4. `__libc_close`: Close the file descriptor to the directory.

Here's how the very first scan of a repository looks like in gitstatusd:

![gitstatusd CPU profile (cold)](
  https://raw.githubusercontent.com/romkatv/gitstatus/1ac366952366d89980b3f3484f270b4fa5ae4293/cpu-profile-gitstatusd-cold.png)

(Some glibc functions are mislabel on this profile. `explicit_bzero` and `__nss_passwd_lookup` are
in reality `strcmp` and `memcmp`.)

This is a superset of the previous -- hot -- profile, with an extra `syscall` and string sorting for
directory listing. gitstatusd uses `getdents64` Linux system call directly, bypassing the glibc
wrapper that libgit2 uses. This is 23% faster. The details of this optimization can be found in a
[separate document](docs/listdir.md).

### Multithreading

The diffing algorithm in gitstatusd was designed from the ground up with the intention of using it
concurrently from multiple threads. With a fast SSD, `status` is CPU bound, so taking advantage of
all available CPU cores is an obvious way to yield results faster.

gitstatusd exhibits almost perfect scaling from multithreading. Engaging all cores allows it to
produce results 12.4 times faster than in single-threaded execution. This is on Intel i9-7900X with
10 cores (20 with hyperthreading) with single-core frequency of 4.3GHz and all-core frequency of
4.0GHz.

Note: `git status` also uses all available cores in some parts of its algorithm while `lg2` does
everything in a single thread.

### Postprocessing

Once the difference between the index and the workdir is found, we have a list of _candidates_ --
files that may be unstaged or untracked. To make the final judgement, these files need to be checked
against `.gitignore` rules and a few other things.

gitstatusd uses [patched libgit2](https://github.com/aauren/libgit2) for this step. romkatv's
original fork added several optimizations that make libgit2 faster. The patched libgit2 performs
more than twice as fast in the benchmark as the original even without changes in the user code
(that is, in the code that uses the libgit2 APIs). The fork also adds several API extensions, most
notable of which is the support for multi-threaded scans. If `lg2 status` is modified to take
advantage of these extensions, it outperforms the original libgit2 by a factor of 18. Lastly, the
fork fixes a score of bugs, most of which become apparent only when using libgit2 from multiple
threads.

The libgit2 this fork of gitstatus builds against is those same patches rebased onto upstream
libgit2 `main`, on the `modernize` branch of `aauren/libgit2`. Each patch is one commit with a note
about what changed in the port, the ones upstream had since fixed or rewritten were dropped, and
libgit2's own clar test suite passes on the result. It still isn't upstream libgit2, and I wouldn't
build anything other than gitstatusd against it.

## Requirements

* To compile: binutils, cmake, gcc, g++, git and GNU make.
* To run: Linux, macOS, FreeBSD, Android, WSL, Cygwin or MSYS2.

## Compiling

There are no prebuilt `gitstatusd` binaries for this fork, and unlike upstream the shell bindings
never download one. When they can't find a binary they print a message telling you to build one.
The bindings look, in order of precedence, at `$GITSTATUS_DAEMON` if it's set, then at
`usrbin/gitstatusd` next to the plugin, then at `usrbin/gitstatusd-<kernel>-<arch>` (lowercase
`uname -s` and `uname -m`) for people who keep binaries for several machines in one checkout.

### Compiling for personal use

```zsh
git clone --depth=1 https://github.com/aauren/gitstatus.git
cd gitstatus
./build -w -s -d docker
```

- If it says that `-d docker` is not supported on your OS, remove this flag.
- If it says that `-s` is not supported on your OS, remove this flag.
- If it tell you to install docker but you cannot or don't want to, remove `-d docker`.
- If it says that some command is missing, install it.

`-d docker` builds inside `alpine:latest` and produces a static-pie binary that runs on any Linux
with the same architecture, which is how I build the binaries I actually use. `-m aarch64` builds
for another architecture under qemu binfmt if your docker has it set up.

If everything goes well, the newly built binary will appear in `./usrbin`. It'll be picked up
by shell bindings automatically.

When you update shell bindings, they may refuse to work with the binary you've built earlier. In
this case you'll need to rebuild.

If you are using gitstatus through [Powerlevel10k](https://github.com/romkatv/powerlevel10k), note
that it bundles its own copy of upstream gitstatus and this fork isn't a drop-in replacement for
that copy. I only use the plain bindings in this repository.

### Compiling for development

`./build` is a wrapper around `CMakeLists.txt`, which builds libgit2 from the tarball pinned in
`build.info` (cached in `deps/`, downloaded if missing) and gitstatusd against it. If you're
hacking on the daemon you'll want the presets in `CMakePresets.json` instead, which give you a
dynamic build with `-Wall -Wextra` and a `ctest` hook for `test/run.sh`:

```zsh
cmake --preset default && cmake --build --preset default && ctest --preset default
```

`make` does the same and copies the result to `./usrbin`. The `asan` and `tsan` presets build both
gitstatusd and libgit2 under clang's sanitizers, and `static` is the `-static-pie` configuration
`./build` ships.

`test/run.sh [path/to/gitstatusd]` runs every fixture in `test/fixtures/` against a binary
(`usrbin/gitstatusd` by default). Each fixture builds a small repository exercising one thing
(linked worktrees, SHA256, reftable, split index, sparse checkout, nested `.gitignore`, negative
refspecs, and so on), asks the daemon about it, and checks the answer against what `git status`
says. `test/bench.sh` is the benchmark driver described [above](#modernization-benchmarks). If
you're changing anything under `src/`, be sure to run the fixtures under the `tsan` preset too,
since the daemon scans with up to 32 threads and the fork's thread safety is the part I trust
least.

### Compiling for distribution

It's currently neither easy nor recommended to package and distribute gitstatus. There are no
instructions you can follow that would allow you to easily update your package when new versions of
gitstatus are released. This may change in the future but not soon.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE). Contributions are covered by the same
license.
