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

#ifndef ROMKATV_GITSTATUS_DIR_H_
#define ROMKATV_GITSTATUS_DIR_H_

#include <cstddef>
#include <vector>

#include "arena.h"

namespace gitstatus {

struct DirEntry {
  // Null-terminated, points into the arena.
  char* name;
  // d_type as reported by the OS. Can be DT_UNKNOWN on filesystems that don't fill it in.
  unsigned char type;
};

// On error, leaves entries unchanged and returns false. Does not throw.
//
// On success, appends entries for the specified directory (minus "." and "..") and returns
// true. They are sorted by name, either by strcmp or strcasecmp depending on case_sensitive.
//
// Does not close dir_fd.
//
// There are two distinct implementations of ListDir -- one for Linux and another for everything
// else. The linux-specific implementation is 20% faster.
//
// The reason sorting is bundled with directory listing is performance on Linux. The API of
// getdents64 allows for much faster sorting than what can be done with a plain vector<char*>.
// For the POSIX implementation there is no need to bundle sorting in this way. In fact, it's
// done at the end with a generic StrSort() call.
//
// For best results, reuse the arena and vector for multiple calls to avoid heap allocations.
bool ListDir(int dir_fd, Arena& arena, std::vector<DirEntry>& entries, bool precompose_unicode,
             bool case_sensitive);

}  // namespace gitstatus

#endif  // ROMKATV_GITSTATUS_DIR_H_
