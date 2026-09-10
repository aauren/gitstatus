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

#include "tag_db.h"

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <utility>

#include "check.h"
#include "dir.h"
#include "git.h"
#include "print.h"
#include "scope_guard.h"
#include "stat.h"
#include "string_cmp.h"
#include "thread_pool.h"
#include "timer.h"

namespace gitstatus {

namespace {

using namespace std::string_literals;

static constexpr char kTagPrefix[] = "refs/tags/";

constexpr int8_t kUnhex[256] = {
    0, 0,  0,  0,  0,  0,  0,  0, 0, 0, 0, 0, 0, 0, 0, 0,  // 0
    0, 0,  0,  0,  0,  0,  0,  0, 0, 0, 0, 0, 0, 0, 0, 0,  // 1
    0, 0,  0,  0,  0,  0,  0,  0, 0, 0, 0, 0, 0, 0, 0, 0,  // 2
    0, 1,  2,  3,  4,  5,  6,  7, 8, 9, 0, 0, 0, 0, 0, 0,  // 3
    0, 10, 11, 12, 13, 14, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0,  // 4
    0, 0,  0,  0,  0,  0,  0,  0, 0, 0, 0, 0, 0, 0, 0, 0,  // 5
    0, 10, 11, 12, 13, 14, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0   // 6
};

// git_oid_cmp compares the type first and then as many bytes as the type has,
// so it's right for both SHA1 and SHA256 repos as long as Tag::id carries a type
struct {
  bool operator()(const Tag* x, const git_oid& y) const { return git_oid_cmp(&x->id, &y) < 0; }
  bool operator()(const git_oid& x, const Tag* y) const { return git_oid_cmp(&x, &y->id) < 0; }
  bool operator()(const Tag* x, const Tag* y) const { return git_oid_cmp(&x->id, &y->id) < 0; }
} constexpr ById = {};

struct {
  bool operator()(const Tag* x, const char* y) const {
    return std::strcmp(x->name, y) < 0;
  }
  bool operator()(const char* x, const Tag* y) const {
    return std::strcmp(x, y->name) < 0;
  }
  bool operator()(const Tag* x, const Tag* y) const {
    return std::strcmp(x->name, y->name) < 0;
  }
} constexpr ByName = {};

struct {
  bool operator()(const char* x, const char* y) const { return std::strcmp(x, y) < 0; }
} constexpr ByStr = {};

const char* StripTag(const char* ref) {
  for (size_t i = 0; i != sizeof(kTagPrefix) - 1; ++i) {
    if (*ref++ != kTagPrefix[i]) return nullptr;
  }
  return ref;
}

size_t OidHexSize(git_oid_t type) {
  switch (type) {
    case GIT_OID_SHA1:
      return GIT_OID_SHA1_HEXSIZE;
    case GIT_OID_SHA256:
      return GIT_OID_SHA256_HEXSIZE;
  }
  LOG(ERROR) << "Unknown object id type: " << static_cast<int>(type);
  throw Exception();
}

bool IsReftable(git_repository* repo) {
  git_config* cfg;
  if (git_repository_config_snapshot(&cfg, repo)) {
    LOG(WARN) << "git_repository_config_snapshot: " << GitError();
    return false;
  }
  ON_SCOPE_EXIT(&) { git_config_free(cfg); };
  const char* val;
  if (git_config_get_string(&val, cfg, "extensions.refstorage")) return false;
  return !std::strcmp(val, "reftable");
}

}  // namespace

TagDb::TagDb(git_repository* repo)
    : repo_(repo),
      oid_type_(git_repository_oid_type(repo)),
      oid_hexsz_(OidHexSize(oid_type_)),
      reftable_(IsReftable(repo)),
      pack_(&pack_arena_),
      name2id_(&pack_arena_),
      id2name_(&pack_arena_) {
  CHECK(repo_);
}

void TagDb::ParseOid(git_oid& oid, const char* begin, const char* end) const {
  VERIFY(end >= begin + oid_hexsz_);
  std::memset(&oid, 0, sizeof(oid));
  oid.type = oid_type_;
  unsigned char* out = oid.id;
  for (size_t i = 0; i != oid_hexsz_; i += 2) {
    *out++ = kUnhex[+begin[i]] << 4 | kUnhex[+begin[i + 1]];
  }
}

TagDb::~TagDb() {
  Wait();
}

std::string TagDb::TagForCommit(const git_oid& oid) {
  if (reftable_) return TagForCommitReftable(oid);

  ReadLooseTags();
  UpdatePack();

  std::string res;

  std::string ref = "refs/tags/";
  size_t prefix_len = ref.size();
  for (const char* tag : loose_tags_) {
    ref.resize(prefix_len);
    ref += tag;
    if (res < tag && TagHasTarget(ref.c_str(), &oid)) res = tag;
  }

  // Hold the lock for the whole lookup so that neither branch can overlap with
  // the background sort of id2name_ scheduled by ParsePack()
  std::unique_lock<std::mutex> lock(mutex_);
  if (id2name_dirty_) {
    for (auto it = name2id_.rbegin(); it != name2id_.rend(); ++it) {
      if (git_oid_equal(&(*it)->id, &oid) && !IsLooseTag((*it)->name)) {
        if (res < (*it)->name) res = (*it)->name;
        break;
      }
    }
  } else {
    auto r = std::equal_range(id2name_.begin(), id2name_.end(), oid, ById);
    for (auto it = r.first; it != r.second; ++it) {
      if (!IsLooseTag((*it)->name) && res < (*it)->name) res = (*it)->name;
    }
  }

  return res;
}

// Under reftable there is no refs/tags directory or packed-refs to read, so we
// go through libgit2's ref iterator instead. Every ref that points at a tag
// object is stored with its peeled target (git and libgit2 both peel on write),
// which is why this doesn't need any object lookups. It's still slower than
// the files path since every query walks every tag.
std::string TagDb::TagForCommitReftable(const git_oid& oid) {
  git_reference_iterator* it;
  VERIFY(!git_reference_iterator_glob_new(&it, repo_, "refs/tags/*")) << GitError();
  ON_SCOPE_EXIT(&) { git_reference_iterator_free(it); };

  std::string res;
  while (true) {
    git_reference* ref;
    switch (git_reference_next(&ref, it)) {
      case 0:
        break;
      case GIT_ITEROVER:
        return res;
      default:
        LOG(ERROR) << "git_reference_next: " << GitError();
        throw Exception();
    }
    ON_SCOPE_EXIT(&) { git_reference_free(ref); };
    if (git_reference_type(ref) != GIT_REFERENCE_DIRECT) continue;
    const git_oid* target = git_reference_target_peel(ref) ?: git_reference_target(ref);
    if (!git_oid_equal(target, &oid)) continue;
    const char* name = StripTag(git_reference_name(ref));
    if (name && res < name) res = name;
  }
}

void TagDb::ReadLooseTags() {
  loose_tags_.clear();
  loose_arena_.Reuse();

  // Tags are shared refs, so in a linked worktree they live in the common gitdir
  // rather than the per-worktree one that git_repository_path() returns
  std::string dirname = git_repository_commondir(repo_) + "refs/tags"s;
  int dir_fd = open(dirname.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (dir_fd < 0) return;
  ON_SCOPE_EXIT(&) { CHECK(!close(dir_fd)) << Errno(); };
  // The top level comes out of ListDir sorted, but a tag like foo/bar lands
  // wherever its directory was visited, and IsLooseTag() binary searches
  if (ReadLooseTagsDir(dir_fd, "")) {
    std::sort(loose_tags_.begin(), loose_tags_.end(), ByStr);
  }
}

// Appends the tags under dir_fd to loose_tags_, so that refs/tags/foo/bar is the
// tag foo/bar. Returns true if it descended into a subdirectory.
// See https://github.com/romkatv/gitstatus/issues/254.
bool TagDb::ReadLooseTagsDir(int dir_fd, const char* prefix) {
  std::vector<char*> entries;
  if (!ListDir(dir_fd, loose_arena_, entries, /* precompose_unicode = */ false,
               /* case_sensitive = */ true)) {
    return false;
  }
  bool nested = false;
  for (char* entry : entries) {
    unsigned char type = DirEntryType(entry);
    if (type == DT_DIR || type == DT_UNKNOWN || type == DT_LNK) {
      int fd = openat(dir_fd, entry, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
      if (fd >= 0) {
        ON_SCOPE_EXIT(&) { CHECK(!close(fd)) << Errno(); };
        nested = true;
        ReadLooseTagsDir(fd, loose_arena_.StrCat(prefix, entry, "/"));
        continue;
      }
      if (errno != ENOTDIR) continue;
    }
    loose_tags_.push_back(
        *prefix ? loose_arena_.StrCat(prefix, entry) : entry);
  }
  return nested;
}

void TagDb::UpdatePack() {
  auto Reset = [&] {
    auto Wipe = [](auto& x) {
      x.clear();
      x.shrink_to_fit();
    };
    Wait();
    Wipe(pack_);
    Wipe(name2id_);
    Wipe(id2name_);
    pack_arena_.Reuse();
    std::memset(&pack_stat_, 0, sizeof(pack_stat_));
  };

  std::string pack_path = git_repository_commondir(repo_) + "packed-refs"s;
  struct stat st;
  if (stat(pack_path.c_str(), &st)) {
    Reset();
    return;
  }
  if (StatEq(pack_stat_, st)) return;

  Reset();

  try {
    while (true) {
      LOG(INFO) << "Parsing " << Print(pack_path);
      int fd = open(pack_path.c_str(), O_RDONLY | O_CLOEXEC);
      VERIFY(fd >= 0);
      ON_SCOPE_EXIT(&) { CHECK(!close(fd)) << Errno(); };
      pack_.resize(st.st_size + 1);
      ssize_t n = read(fd, &pack_[0], st.st_size + 1);
      VERIFY(n >= 0) << Errno();
      VERIFY(!fstat(fd, &pack_stat_)) << Errno();
      if (!StatEq(st, pack_stat_)) {
        st = pack_stat_;
        continue;
      }
      VERIFY(n == st.st_size);
      pack_.pop_back();
      break;
    }
    ParsePack();
  } catch (const Exception&) {
    Reset();
    throw;
  }
}

void TagDb::ParsePack() {
  char* p = &pack_[0];
  char* e = p + pack_.size();

  // Usually packed-refs starts with the following line:
  //
  //   # pack-refs with: peeled fully-peeled sorted
  //
  // However, some users can produce pack-refs without this line.
  // See https://github.com/romkatv/powerlevel10k/issues/1428.
  // I don't know how they do it. Without the header line we cannot
  // assume that refs are sorted, which isn't a big deal because we
  // can just sort them. What's worse is that refs cannot be assumed
  // to be fully-peeled. We don't want to peel them, so we just drop
  // all tags.
  if (*p != '#') {
    LOG(WARN) << "packed-refs doesn't have a header. Won't resolve tags.";
    return;
  }

  char* eol = std::strchr(p, '\n');
  if (!eol) return;
  *eol = 0;
  if (!std::strstr(p, " fully-peeled") || !std::strstr(p, " sorted")) {
    LOG(WARN) << "packed-refs has unexpected header. Won't resolve tags.";
  }
  p = eol + 1;

  name2id_.reserve(pack_.size() / 128);
  id2name_.reserve(pack_.size() / 128);

  std::vector<Tag*> idx;
  idx.reserve(pack_.size() / 128);

  while (p != e) {
    Tag* tag = pack_arena_.Allocate<Tag>();
    ParseOid(tag->id, p, e);
    p += oid_hexsz_;
    VERIFY(*p++ == ' ');
    const char* ref = p;
    VERIFY(p = std::strchr(p, '\n'));
    p[p[-1] == '\r' ? -1 : 0] = 0;
    ++p;
    if (*p == '^') {
      ParseOid(tag->id, p + 1, e);
      p += oid_hexsz_ + 1;
      if (p != e) {
        VERIFY((p = std::strchr(p, '\n')));
        ++p;
      }
    }
    tag->name = StripTag(ref);
    if (!tag->name) continue;
    name2id_.push_back(tag);
    id2name_.push_back(tag);
  }

  if (!std::is_sorted(name2id_.begin(), name2id_.end(), ByName)) {
    // "sorted" in the header of packed-refs promises that this won't trigger.
    std::sort(name2id_.begin(), name2id_.end(), ByName);
  }

  id2name_dirty_ = true;
  GlobalThreadPool()->Schedule([this] {
    std::sort(id2name_.begin(), id2name_.end(), ById);
    std::unique_lock<std::mutex> lock(mutex_);
    CHECK(id2name_dirty_);
    id2name_dirty_ = false;
    cv_.notify_one();
  });
}

void TagDb::Wait() {
  std::unique_lock<std::mutex> lock(mutex_);
  while (id2name_dirty_) cv_.wait(lock);
}

bool TagDb::IsLooseTag(const char* name) const {
  return std::binary_search(loose_tags_.begin(), loose_tags_.end(), name, ByStr);
}

bool TagDb::TagHasTarget(const char* name, const git_oid* target) const {
  static constexpr size_t kMaxDerefCount = 10;

  git_reference* ref;
  if (git_reference_lookup(&ref, repo_, name)) return false;
  ON_SCOPE_EXIT(&) { git_reference_free(ref); };

  for (int i = 0; i != kMaxDerefCount && git_reference_type(ref) == GIT_REFERENCE_SYMBOLIC; ++i) {
    git_reference* dst;
    const char* ref_name = git_reference_name(ref);
    if (git_reference_lookup(&dst, repo_, ref_name)) {
      const char* tag_name = StripTag(ref_name);
      auto it = std::lower_bound(name2id_.begin(), name2id_.end(), tag_name, ByName);
      return it != name2id_.end() && !strcmp((*it)->name, tag_name) && !IsLooseTag(tag_name) &&
             git_oid_equal(&(*it)->id, target);
    }
    git_reference_free(ref);
    ref = dst;
  }

  if (git_reference_type(ref) == GIT_REFERENCE_SYMBOLIC) return false;
  const git_oid* oid = git_reference_target_peel(ref) ?: git_reference_target(ref);
  if (git_oid_equal(oid, target)) return true;

  for (int i = 0; i != kMaxDerefCount; ++i) {
    git_tag* tag;
    if (git_tag_lookup(&tag, repo_, oid)) return false;
    ON_SCOPE_EXIT(&) { git_tag_free(tag); };
    if (git_tag_target_type(tag) == GIT_OBJECT_COMMIT) {
      return git_oid_equal(git_tag_target_id(tag), target);
    }
    oid = git_tag_target_id(tag);
  }

  return false;
}

}  // namespace gitstatus
