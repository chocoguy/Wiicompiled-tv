#pragma once

// Saves and settings that outlive tvOS cache purges (src/platform/tvos/tvos_persistence.mm).
//
// A tvOS app cannot write Documents or Application Support, so WiiCompiled's user data lives in
// Library/Caches/WiiCompiled, which tvOS may purge while the app is not running. An app's
// preferences do last. This keeps an LZFSE-packed copy of every save and settings file there
// (NSUserDefaults, or Library/Preferences/WiiCompiled-persist past a budget) and writes it back at
// launch when the cached file is gone. The approach follows TVPort's TVSaves.m (MIT).
#include <filesystem>
#include <string>

namespace TvosPersistence {

// At launch, before anything reads user data: recreate every kept file whose cached copy is missing.
// Returns how many files came back.
int RestoreMissingFiles() noexcept;

// RestoreMissingFiles the first time it is called in the process; later calls return 0. The app
// calls it before its first read of Config.toml, which happens during static initialization
// (runtime_config.h). With MKW_TVOS_SIMULATE_CACHE_PURGE=1 in the environment, it first deletes
// the user data except DATA/, which stands in for tvOS purging Library/Caches while the app was
// closed (devicectl cannot delete files in an app's container).
int RestoreMissingFilesOnce() noexcept;

// After the NAND layer has fully written and closed (or atomically committed) a file. Reads the file
// now and keeps it on a background queue, so a later write cannot tear the copy. Files outside the
// user-data folder, and the regenerable DATA/, Cache/ and Logs/, are ignored.
void KeepFile(const std::filesystem::path& path) noexcept;

// Keeps Config.toml and the other host-written settings files that changed since the last call.
void KeepChangedSettings() noexcept;

// Keeps changed settings and waits until every pending copy is stored. For when the app leaves the
// screen: tvOS may end it without another chance.
void Flush() noexcept;

// For tests: the user-data folder these files are kept relative to.
std::filesystem::path DataDirectory();

} // namespace TvosPersistence
