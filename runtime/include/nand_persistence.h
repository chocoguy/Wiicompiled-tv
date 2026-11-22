#pragma once

// Platform hook for NAND files the guest has finished writing. Only tvOS acts on it: there the
// user-data folder is a cache tvOS may purge, so each saved file is also kept elsewhere
// (platform/tvos_persistence.h). Everywhere else this compiles to nothing.
#include <filesystem>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(__APPLE__) && TARGET_OS_TV
#include "platform/tvos_persistence.h"
#endif

namespace NandPersistence {

// Call once `path` is flushed, closed and (for a safe-opened file) committed under its final name.
inline void FileWritten(const std::filesystem::path& path) noexcept {
#if defined(__APPLE__) && TARGET_OS_TV
    TvosPersistence::KeepFile(path);
#else
    static_cast<void>(path);
#endif
}

} // namespace NandPersistence
