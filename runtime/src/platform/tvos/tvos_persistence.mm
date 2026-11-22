// Saves and settings that outlive tvOS cache purges; see include/platform/tvos_persistence.h.
//
// Each kept file is stored as "MKP1" + its size (little-endian u64) + its LZFSE-compressed bytes.
// NSUserDefaults aborts an app past about 1 MB in all (TVPort, measured on tvOS 27.2), so they hold
// at most kDefaultsBudget; a file that would pass it goes to Library/Preferences/WiiCompiled-persist
// instead, which tvOS also keeps (it is where the preferences live) but does not document.
// Measured on 2026-11-08: a fresh NAND with one finished race (rksys.dat 2.7 MB) packs to 20 KB.
#include "platform/tvos_persistence.h"

#include "platform/host_platform.h"

#import <Foundation/Foundation.h>
#include <compression.h>
#include <sys/stat.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <utility>

namespace TvosPersistence {
namespace {

constexpr const char* kApplicationName = "WiiCompiled";     // runtime_config.h kApplicationDirectoryName
NSString* const kKeyPrefix = @"mkw.persist:";
constexpr NSUInteger kDefaultsBudget = 900 * 1024;
constexpr size_t kHeaderSize = 12;
constexpr char kMagic[4] = {'M', 'K', 'P', '1'};
// Host-written settings files; NAND files are kept as the guest closes them.
constexpr const char* kSettingsFiles[] = {"Config.toml", "imgui.ini", "gamecontrollerdb.txt",
                                          "NAND/.mkw_recompiled_managed_nand"};

dispatch_queue_t Queue() {
    static dispatch_queue_t queue = dispatch_queue_create("org.wiicompiled.persistence", DISPATCH_QUEUE_SERIAL);
    return queue;
}

NSString* SpillRoot() {
    NSString* library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    return [library stringByAppendingPathComponent:@"Preferences/WiiCompiled-persist"];
}

// The path relative to the user-data folder, or empty for a file this does not keep.
std::string RelativeName(const std::filesystem::path& path) {
    std::error_code ec;
    const auto data = std::filesystem::weakly_canonical(DataDirectory(), ec);
    const auto file = std::filesystem::weakly_canonical(path, ec);
    const auto relative = file.lexically_relative(data).generic_string();
    if (relative.empty() || relative == "." || relative.rfind("..", 0) == 0) {
        return {};
    }
    for (const char* skipped : {"DATA/", "Cache/", "Logs/"}) {
        if (relative.rfind(skipped, 0) == 0) {
            return {};
        }
    }
    return relative;
}

NSData* Pack(NSData* raw) {
    const size_t room = raw.length + raw.length / 8 + 65536;   // LZFSE can grow what it cannot shrink
    NSMutableData* packed = [NSMutableData dataWithLength:kHeaderSize + room];
    std::memcpy(packed.mutableBytes, kMagic, sizeof kMagic);
    const uint64_t size = raw.length;
    std::memcpy(static_cast<uint8_t*>(packed.mutableBytes) + 4, &size, sizeof size);
    const size_t written = raw.length == 0 ? 0
        : compression_encode_buffer(static_cast<uint8_t*>(packed.mutableBytes) + kHeaderSize, room,
                                    static_cast<const uint8_t*>(raw.bytes), raw.length, nullptr, COMPRESSION_LZFSE);
    if (raw.length != 0 && written == 0) {
        return nil;
    }
    packed.length = kHeaderSize + written;
    return packed;
}

NSData* Unpack(NSData* packed) {
    if (packed.length < kHeaderSize || std::memcmp(packed.bytes, kMagic, sizeof kMagic) != 0) {
        return nil;
    }
    uint64_t size = 0;
    std::memcpy(&size, static_cast<const uint8_t*>(packed.bytes) + 4, sizeof size);
    NSMutableData* raw = [NSMutableData dataWithLength:size];
    if (size != 0 &&
        compression_decode_buffer(static_cast<uint8_t*>(raw.mutableBytes), size,
                                  static_cast<const uint8_t*>(packed.bytes) + kHeaderSize,
                                  packed.length - kHeaderSize, nullptr, COMPRESSION_LZFSE) != size) {
        return nil;
    }
    return raw;
}

NSUInteger DefaultsBytesExcept(NSUserDefaults* defaults, NSString* key) {
    NSUInteger total = 0;
    for (NSString* other in defaults.dictionaryRepresentation) {
        if ([other hasPrefix:kKeyPrefix] && ![other isEqualToString:key]) {
            id value = [defaults objectForKey:other];
            if ([value isKindOfClass:NSData.class]) total += static_cast<NSData*>(value).length;
        }
    }
    return total;
}

void Store(const std::string& relative, NSData* raw) {
    @autoreleasepool {
        NSData* packed = Pack(raw);
        if (!packed) {
            std::fprintf(stderr, "[tvos] persistence: could not pack %s\n", relative.c_str());
            return;
        }
        NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
        NSString* name = [NSString stringWithUTF8String:relative.c_str()];
        NSString* key = [kKeyPrefix stringByAppendingString:name];
        NSString* spill = [SpillRoot() stringByAppendingPathComponent:name];
        NSFileManager* files = NSFileManager.defaultManager;
        if (DefaultsBytesExcept(defaults, key) + packed.length > kDefaultsBudget) {
            [files createDirectoryAtPath:spill.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                              attributes:nil error:nil];
            if (![packed writeToFile:spill atomically:YES]) {
                std::fprintf(stderr, "[tvos] persistence: writing %s failed\n", spill.fileSystemRepresentation);
                return;
            }
            [defaults removeObjectForKey:key];
            [defaults synchronize];
            std::fprintf(stderr, "[tvos] persistence: kept %s (%lu bytes packed to %lu) in Library/Preferences\n",
                         relative.c_str(), static_cast<unsigned long>(raw.length),
                         static_cast<unsigned long>(packed.length));
            return;
        }
        [defaults setObject:packed forKey:key];
        if (![defaults synchronize]) {
            std::fprintf(stderr, "[tvos] persistence: the preferences did not take %s\n", relative.c_str());
            return;
        }
        [files removeItemAtPath:spill error:nil];
        std::fprintf(stderr, "[tvos] persistence: kept %s (%lu bytes packed to %lu)\n", relative.c_str(),
                     static_cast<unsigned long>(raw.length), static_cast<unsigned long>(packed.length));
    }
}

bool Restore(const std::string& relative, NSData* packed) {
    const std::filesystem::path local = DataDirectory() / relative;
    std::error_code ec;
    if (std::filesystem::exists(local, ec)) {
        return false;   // the cache still has it, and it is at least as new as the kept copy
    }
    NSData* raw = Unpack(packed);
    if (!raw) {
        std::fprintf(stderr, "[tvos] persistence: the kept copy of %s is damaged\n", relative.c_str());
        return false;
    }
    std::filesystem::create_directories(local.parent_path(), ec);
    if (![raw writeToFile:[NSString stringWithUTF8String:local.c_str()] atomically:YES]) {
        std::fprintf(stderr, "[tvos] persistence: could not restore %s\n", relative.c_str());
        return false;
    }
    return true;
}

std::mutex g_settingsMutex;
std::map<std::string, std::pair<off_t, int64_t>> g_settingsSeen;   // size and mtime last kept

} // namespace

std::filesystem::path DataDirectory() { return RuntimePlatform::ApplicationDataDirectory(kApplicationName); }

int RestoreMissingFiles() noexcept {
    @autoreleasepool {
        int restored = 0;
        NSDictionary* all = NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
        for (NSString* key in all) {
            if ([key hasPrefix:kKeyPrefix] && [all[key] isKindOfClass:NSData.class]) {
                restored += Restore([key substringFromIndex:kKeyPrefix.length].UTF8String, all[key]);
            }
        }
        NSString* spillRoot = SpillRoot();
        NSDirectoryEnumerator* walk = [NSFileManager.defaultManager enumeratorAtPath:spillRoot];
        for (NSString* name in walk) {
            if (walk.fileAttributes.fileType != NSFileTypeRegular) continue;
            NSData* packed = [NSData dataWithContentsOfFile:[spillRoot stringByAppendingPathComponent:name]];
            if (packed) restored += Restore(name.UTF8String, packed);
        }
        if (restored > 0) {
            std::fprintf(stderr, "[tvos] persistence: restored %d file(s) the cache had lost\n", restored);
        }
        // Keep whatever has no copy yet: saves from before this build, and files the runtime
        // writes outside the NAND hooks (the WC24 bootstrap seeding).
        NSDictionary* kept = NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
        std::error_code ec;
        for (auto it = std::filesystem::recursive_directory_iterator(DataDirectory(), ec);
             !ec && it != std::filesystem::recursive_directory_iterator(); it.increment(ec)) {
            if (!it->is_regular_file(ec)) continue;
            const std::string relative = RelativeName(it->path());
            if (relative.empty()) continue;
            NSString* name = [NSString stringWithUTF8String:relative.c_str()];
            if (kept[[kKeyPrefix stringByAppendingString:name]] == nil &&
                ![NSFileManager.defaultManager fileExistsAtPath:[spillRoot stringByAppendingPathComponent:name]]) {
                KeepFile(it->path());
            }
        }
        return restored;
    }
}

int RestoreMissingFilesOnce() noexcept {
    static const int restored = [] {
        if (const char* purge = std::getenv("MKW_TVOS_SIMULATE_CACHE_PURGE"); purge && *purge == '1') {
            std::error_code ec;
            for (const auto& entry : std::filesystem::directory_iterator(DataDirectory(), ec)) {
                if (entry.path().filename() != "DATA") std::filesystem::remove_all(entry.path(), ec);
            }
            std::fprintf(stderr, "[tvos] persistence: simulated a cache purge of the user data\n");
        }
        return RestoreMissingFiles();
    }();
    return restored;
}

void KeepFile(const std::filesystem::path& path) noexcept {
    const std::string relative = RelativeName(path);
    if (relative.empty()) {
        return;
    }
    @autoreleasepool {
        // Read now: the guest may write the file again before the queue gets to it.
        NSData* raw = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path.c_str()]];
        if (!raw) {
            return;
        }
        dispatch_async(Queue(), ^{ Store(relative, raw); });
    }
}

void KeepChangedSettings() noexcept {
    std::lock_guard<std::mutex> lock(g_settingsMutex);
    for (const char* name : kSettingsFiles) {
        const std::filesystem::path path = DataDirectory() / name;
        struct stat info {};
        if (::stat(path.c_str(), &info) != 0) {
            continue;
        }
        const auto seen = std::make_pair(info.st_size, static_cast<int64_t>(info.st_mtimespec.tv_sec) * 1000000000 +
                                                           info.st_mtimespec.tv_nsec);
        auto& last = g_settingsSeen[name];
        if (last != seen) {
            last = seen;
            KeepFile(path);
        }
    }
}

void Flush() noexcept {
    KeepChangedSettings();
    dispatch_sync(Queue(), ^{});
}

} // namespace TvosPersistence
