#include "platform/host_platform.h"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <system_error>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

int main() {
    if (!RuntimePlatform::ExecutableDirectory()) {
        std::cerr << "unable to resolve the current executable directory\n";
        return 1;
    }

    const auto userData = RuntimePlatform::ApplicationDataDirectory("WiiCompiledPlatformPathsTest");
    if (userData.filename() != "WiiCompiledPlatformPathsTest") {
        std::cerr << "application-data directory lost its application name: " << userData << '\n';
        return 1;
    }
    if (RuntimePlatform::LogDirectory("WiiCompiledPlatformPathsTest") != userData / "Logs") {
        std::cerr << "log directory is not derived from application data\n";
        return 1;
    }
#if defined(__APPLE__) && TARGET_OS_TV
    // tvOS: Library/Caches is the only writable Library folder an app can use for files.
    if (userData.parent_path().filename() != "Caches" ||
        userData.parent_path().parent_path().filename() != "Library") {
        std::cerr << "tvOS application-data directory is not under Library/Caches: " << userData << '\n';
        return 1;
    }
    std::error_code ec;
    std::filesystem::create_directories(userData / "Logs", ec);
    if (ec) {
        std::cerr << "tvOS application-data directory is not writable: " << userData << ": " << ec.message() << '\n';
        return 1;
    }
    {
        std::ofstream probe(userData / "Logs" / "write-test.txt");
        probe << "ok\n";
        if (!probe) {
            std::cerr << "cannot write a file under " << userData << '\n';
            return 1;
        }
    }
    std::filesystem::remove_all(userData, ec);
    const auto executable = RuntimePlatform::ExecutableDirectory();
    if (executable->extension() != ".app") {
        std::cerr << "tvOS executable directory is not the app bundle root: " << *executable << '\n';
        return 1;
    }
#elif defined(__APPLE__)
    if (userData.parent_path().filename() != "Application Support" ||
        userData.parent_path().parent_path().filename() != "Library") {
        std::cerr << "macOS application-data directory is not under ~/Library/Application Support: "
                  << userData << '\n';
        return 1;
    }
#endif

    return 0;
}
