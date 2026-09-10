// Copyright 2019 Roman Perepelitsa.
//
// This file is part of GitStatus.
//
// GitStatus is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// GitStatus is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with GitStatus. If not, see <https://www.gnu.org/licenses/>.

#include "git.h"

#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <utility>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "arena.h"
#include "check.h"
#include "print.h"
#include "scope_guard.h"

namespace gitstatus {

const char* GitError() {
  const git_error* err = git_error_last();
  return err && err->message ? err->message : "unknown error";
}

std::string RepoState(git_repository* repo) {
  Arena arena;
  StringView gitdir(git_repository_path(repo));

  // These names mostly match gitaction in vcs_info:
  // https://github.com/zsh-users/zsh/blob/master/Functions/VCS_Info/Backends/VCS_INFO_get_data_git.
  auto State = [&]() {
    switch (git_repository_state(repo)) {
      case GIT_REPOSITORY_STATE_NONE:
        return "";
      case GIT_REPOSITORY_STATE_MERGE:
        return "merge";
      case GIT_REPOSITORY_STATE_REVERT:
        return "revert";
      case GIT_REPOSITORY_STATE_REVERT_SEQUENCE:
        return "revert-seq";
      case GIT_REPOSITORY_STATE_CHERRYPICK:
        return "cherry";
      case GIT_REPOSITORY_STATE_CHERRYPICK_SEQUENCE:
        return "cherry-seq";
      case GIT_REPOSITORY_STATE_BISECT:
        return "bisect";
      case GIT_REPOSITORY_STATE_REBASE:
        return "rebase";
      case GIT_REPOSITORY_STATE_REBASE_INTERACTIVE:
        return "rebase-i";
      case GIT_REPOSITORY_STATE_REBASE_MERGE:
        return "rebase-m";
      case GIT_REPOSITORY_STATE_APPLY_MAILBOX:
        return "am";
      case GIT_REPOSITORY_STATE_APPLY_MAILBOX_OR_REBASE:
        return "am/rebase";
    }
    return "action";
  };

  auto DirExists = [&](StringView name) {
    int fd = open(arena.StrCat(gitdir, "/", name), O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return false;
    CHECK(!close(fd)) << Errno();
    return true;
  };

  auto ReadFile = [&](StringView name) {
    std::ifstream strm(arena.StrCat(gitdir, "/", name));
    std::string res;
    strm >> res;
    return res;
  };

  std::string next;
  std::string last;

  if (DirExists("rebase-merge")) {
    next = ReadFile("rebase-merge/msgnum");
    last = ReadFile("rebase-merge/end");
  } else if (DirExists("rebase-apply")) {
    next = ReadFile("rebase-apply/next");
    last = ReadFile("rebase-apply/last");
  }

  std::ostringstream res;
  res << State();
  if (!next.empty() && !last.empty()) res << ' ' << next << '/' << last;
  return res.str();
}

size_t CountRange(git_repository* repo, const std::string& range) {
  git_revwalk* walk = nullptr;
  VERIFY(!git_revwalk_new(&walk, repo)) << GitError();
  ON_SCOPE_EXIT(=) { git_revwalk_free(walk); };
  VERIFY(!git_revwalk_push_range(walk, range.c_str())) << GitError();
  size_t res = 0;
  while (true) {
    git_oid oid;
    switch (git_revwalk_next(&oid, walk)) {
      case 0:
        ++res;
        break;
      case GIT_ITEROVER:
        return res;
      default:
        LOG(ERROR) << "git_revwalk_next: " << range << ": " << GitError();
        throw Exception();
    }
  }
}

size_t NumStashes(git_repository* repo) {
  size_t res = 0;
  auto* cb = +[](size_t, const char*, const git_oid*, void* payload) {
    ++*static_cast<size_t*>(payload);
    return 0;
  };
  if (!git_stash_foreach(repo, cb, &res)) return res;
  // Example error: failed to parse signature - malformed e-mail.
  // See https://github.com/romkatv/powerlevel10k/issues/216.
  LOG(WARN) << "git_stash_foreach: " << GitError();
  return 0;
}

git_reference* Head(git_repository* repo) {
  git_reference* symbolic = nullptr;
  switch (git_reference_lookup(&symbolic, repo, "HEAD")) {
    case 0:
      break;
    case GIT_ENOTFOUND:
      return nullptr;
    default:
      LOG(ERROR) << "git_reference_lookup: " << GitError();
      throw Exception();
  }

  git_reference* direct = nullptr;
  if (git_reference_resolve(&direct, symbolic)) {
    LOG(INFO) << "Empty git repo (no HEAD)";
    return symbolic;
  }
  git_reference_free(symbolic);
  return direct;
}

const char* LocalBranchName(const git_reference* ref) {
  CHECK(ref);
  git_reference_t type = git_reference_type(ref);
  switch (type) {
    case GIT_REFERENCE_DIRECT: {
      return git_reference_is_branch(ref) ? git_reference_shorthand(ref) : "";
    }
    case GIT_REFERENCE_SYMBOLIC: {
      static constexpr char kHeadPrefix[] = "refs/heads/";
      const char* target = git_reference_symbolic_target(ref);
      if (!target) return "";
      size_t len = std::strlen(target);
      if (len < sizeof(kHeadPrefix)) return "";
      if (std::memcmp(target, kHeadPrefix, sizeof(kHeadPrefix) - 1)) return "";
      return target + (sizeof(kHeadPrefix) - 1);
    }
    case GIT_REFERENCE_INVALID:
    case GIT_REFERENCE_ALL:
      break;
  }
  LOG(ERROR) << "Invalid reference type: " << type;
  throw Exception();
}

namespace {

// Looks up the remote called `name`, or leaves the result null when the name is
// "." (the local repository). Returns false if the remote doesn't exist.
bool LookupRemote(git_remote** out, git_repository* repo, const std::string& name) {
  *out = nullptr;
  return name == "." || !git_remote_lookup(out, repo, name.c_str());
}

// Maps a branch name through the remote's fetch refspecs to the name of its
// remote-tracking ref, the same way git_branch_upstream_name does for upstreams.
bool TrackingRefName(std::string& out, const git_remote* remote, const char* refname) {
  for (size_t i = 0, n = git_remote_refspec_count(remote); i != n; ++i) {
    const git_refspec* spec = git_remote_get_refspec(remote, i);
    if (git_refspec_direction(spec) != GIT_DIRECTION_FETCH) continue;
    if (!git_refspec_src_matches(spec, refname)) continue;
    git_buf buf = {};
    ON_SCOPE_EXIT(&) { git_buf_dispose(&buf); };
    if (git_refspec_transform(&buf, spec, refname)) return false;
    out.assign(buf.ptr, buf.size);
    return true;
  }
  return false;
}

}  // namespace

RemotePtr GetRemote(git_repository* repo, const git_reference* local) {
  const char* refname = git_reference_name(local);

  git_buf symref = {};
  ON_SCOPE_EXIT(&) { git_buf_dispose(&symref); };
  if (git_branch_upstream_name(&symref, repo, refname)) return nullptr;

  git_buf remote_name = {};
  ON_SCOPE_EXIT(&) { git_buf_dispose(&remote_name); };
  if (git_branch_upstream_remote(&remote_name, repo, refname)) return nullptr;
  std::string name(remote_name.ptr, remote_name.size);

  git_remote* remote;
  if (!LookupRemote(&remote, repo, name)) return nullptr;
  ON_SCOPE_EXIT(&) {
    if (remote) git_remote_free(remote);
  };

  git_reference* ref;
  if (git_reference_lookup(&ref, repo, symref.ptr)) return nullptr;
  ON_SCOPE_EXIT(&) {
    if (ref) git_reference_free(ref);
  };

  const char* branch = nullptr;
  if (git_branch_name(&branch, ref)) {
    branch = "";
  } else if (remote) {
    VERIFY(std::strstr(branch, name.c_str()) == branch);
    VERIFY(branch[name.size()] == '/');
    branch += name.size() + 1;
  }

  auto res = std::make_unique<Remote>();
  res->name = std::move(name);
  res->branch = branch;
  res->url = remote ? (git_remote_url(remote) ?: "") : "";
  res->ref = std::exchange(ref, nullptr);
  return RemotePtr(res.release());
}

PushRemotePtr GetPushRemote(git_repository* repo, git_config* cfg, const git_reference* local) {
  // Same resolution as `git push` minus the fallback to the upstream remote:
  // branch.<name>.pushRemote, then remote.pushDefault. If neither is set there
  // is no push remote as far as we're concerned.
  if (!git_reference_is_branch(local)) return nullptr;
  const char* refname = git_reference_name(local);
  const char* val = nullptr;
  std::string key = std::string("branch.") + git_reference_shorthand(local) + ".pushremote";
  if (git_config_get_string(&val, cfg, key.c_str()) &&
      git_config_get_string(&val, cfg, "remote.pushdefault")) {
    return nullptr;
  }
  std::string name = val ?: "";
  if (name.empty()) return nullptr;

  git_remote* remote;
  if (!LookupRemote(&remote, repo, name)) return nullptr;
  ON_SCOPE_EXIT(&) {
    if (remote) git_remote_free(remote);
  };

  std::string symref = refname;
  if (remote && !TrackingRefName(symref, remote, refname)) return nullptr;

  git_reference* ref;
  if (git_reference_lookup(&ref, repo, symref.c_str())) return nullptr;
  ON_SCOPE_EXIT(&) {
    if (ref) git_reference_free(ref);
  };

  auto res = std::make_unique<PushRemote>();
  res->name = std::move(name);
  res->url = remote ? (git_remote_url(remote) ?: "") : "";
  res->ref = std::exchange(ref, nullptr);
  return PushRemotePtr(res.release());
}

CommitMessage GetCommitMessage(git_repository* repo, const git_oid& id) {
  git_commit* commit;
  VERIFY(!git_commit_lookup(&commit, repo, &id)) << GitError();
  ON_SCOPE_EXIT(=) { git_commit_free(commit); };
  return {.encoding = git_commit_message_encoding(commit) ?: "",
          .summary = git_commit_summary(commit) ?: ""};
}

}  // namespace gitstatus
