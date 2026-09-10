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

#include "repo_cache.h"

#include <cstring>

#include "check.h"
#include "git.h"
#include "print.h"
#include "scope_guard.h"
#include "string_view.h"

namespace gitstatus {

namespace {

// Gitdir of the repository containing dir, or empty if there isn't one. This
// doesn't open the repository, which keeps cache hits cheap.
std::string DiscoverGitDir(const std::string& dir) {
  git_buf buf = {};
  ON_SCOPE_EXIT(&) { git_buf_dispose(&buf); };
  switch (git_repository_discover(&buf, dir.c_str(), 0, nullptr)) {
    case 0:
      return std::string(buf.ptr, buf.size);
    case GIT_ENOTFOUND:
      return "";
    default:
      LOG(ERROR) << "git_repository_discover: " << Print(dir) << ": " << GitError();
      throw Exception();
  }
}

git_repository* OpenRepo(const std::string& dir, bool from_dotgit) {
  git_repository* repo = nullptr;
  int flags = from_dotgit ? GIT_REPOSITORY_OPEN_NO_SEARCH | GIT_REPOSITORY_OPEN_NO_DOTGIT : 0;
  switch (git_repository_open_ext(&repo, dir.c_str(), flags, nullptr)) {
    case 0:
      return repo;
    case GIT_ENOTFOUND:
      return nullptr;
    default:
      LOG(ERROR) << "git_repository_open_ext: " << Print(dir) << ": " << GitError();
      throw Exception();
  }
}

std::string DirName(std::string path) {
  if (path.empty()) return "";
  while (path.back() == '/') {
    path.pop_back();
    if (path.empty()) return "";
  }
  do {
    path.pop_back();
    if (path.empty()) return "";
  } while (path.back() != '/');
  return path;
}

}  // namespace

Repo* RepoCache::Open(const std::string& dir, bool from_dotgit) {
  if (dir.empty() || dir.front() != '/') return nullptr;

  // git_repository_discover can't express NO_SEARCH | NO_DOTGIT, so requests
  // that come from $GIT_DIR pay for a full open even on a cache hit. They're
  // rare enough that this doesn't matter.
  git_repository* repo = nullptr;
  ON_SCOPE_EXIT(&) {
    if (repo) git_repository_free(repo);
  };
  std::string gitdir;
  if (from_dotgit) {
    repo = OpenRepo(dir, true);
    if (repo) gitdir = git_repository_path(repo);
  } else {
    gitdir = DiscoverGitDir(dir);
  }
  if (gitdir.empty()) {
    // This isn't quite correct because of differences in canonicalization, .git files and GIT_DIR.
    // A proper solution would require tracking the "discovery dir" for every repository and
    // performing path canonicalization.
    if (from_dotgit) {
      Erase(cache_.find(dir.back() == '/' ? dir : dir + '/'));
    } else {
      std::string path = dir;
      if (path.back() != '/') path += '/';
      do {
        Erase(cache_.find(path + ".git/"));
        path = DirName(path);
      } while (!path.empty());
    }
    return nullptr;
  }
  VERIFY(gitdir.front() == '/' && gitdir.back() == '/') << Print(gitdir);

  auto it = cache_.find(gitdir);
  if (it != cache_.end()) {
    lru_.erase(it->second->lru);
    it->second->lru = lru_.insert({Clock::now(), it});
    return it->second.get();
  }

  if (!repo) repo = OpenRepo(dir, false);
  if (!repo) return nullptr;
  if (git_repository_is_bare(repo)) return nullptr;
  std::string workdir = git_repository_workdir(repo) ?: "";
  if (workdir.empty()) return nullptr;
  VERIFY(workdir.front() == '/' && workdir.back() == '/') << Print(workdir);

  auto x = cache_.emplace(gitdir, nullptr);
  std::unique_ptr<Entry>& elem = x.first->second;
  if (elem) {
    lru_.erase(elem->lru);
  } else {
    LOG(INFO) << "Initializing new repository: " << Print(gitdir);

    // Libgit2 initializes odb and refdb lazily with double-locking. To avoid useless work
    // when multiple threads attempt to initialize the same db at the same time, we trigger
    // initialization manually before threads are in play.
    git_odb* odb;
    VERIFY(!git_repository_odb(&odb, repo)) << GitError();
    git_odb_free(odb);

    git_refdb* refdb;
    VERIFY(!git_repository_refdb(&refdb, repo)) << GitError();
    git_refdb_free(refdb);

    elem = std::make_unique<Entry>(std::exchange(repo, nullptr), lim_);
  }
  elem->lru = lru_.insert({Clock::now(), x.first});
  return elem.get();
}

void RepoCache::Free(Time cutoff) {
  while (true) {
    if (lru_.empty()) break;
    auto it = lru_.begin();
    if (it->first > cutoff) break;
    Erase(it->second);
  }
}

void RepoCache::Erase(Cache::iterator it) {
  if (it == cache_.end()) return;
  LOG(INFO) << "Closing repository: " << Print(it->first);
  lru_.erase(it->second->lru);
  cache_.erase(it);
}

}  // namespace gitstatus
