// Saves and settings survive a purge of Library/Caches (platform/tvos_persistence.h). Runs on the
// Apple TV through ctest (Launcher/tvos/run_on_device.py), in a fresh app container each time.
#include "platform/tvos_persistence.h"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <random>
#include <string>
#include <system_error>
#include <vector>

namespace fs = std::filesystem;

namespace {
int g_failures = 0;

void Check(bool ok, const char* what) {
    std::printf("%s: %s\n", ok ? "ok" : "FAILED", what);
    if (!ok) ++g_failures;
}

void Write(const fs::path& path, const std::vector<char>& bytes) {
    fs::create_directories(path.parent_path());
    std::ofstream(path, std::ios::binary).write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}

std::vector<char> Read(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}
} // namespace

int main() {
    const fs::path data = TvosPersistence::DataDirectory();
    const fs::path save = data / "NAND/title/00010004/524d4350/data/rksys.dat";
    const fs::path config = data / "Config.toml";
    const fs::path big = data / "NAND/title/00010004/524d4350/data/incompressible.bin";
    const fs::path regenerable = data / "DATA/sys/fst.bin";
    std::error_code ec;
    fs::remove_all(data, ec);

    // rksys.dat is 2.7 MB of mostly zeros; the incompressible file must spill past the budget.
    std::vector<char> saveBytes(2867200, 0);
    for (size_t i = 0; i < saveBytes.size(); i += 4096) saveBytes[i] = static_cast<char>(i / 4096);
    std::vector<char> configBytes(std::begin("[video]\nresolution_multiplier = 2.0\n"),
                                  std::end("[video]\nresolution_multiplier = 2.0\n") - 1);
    std::vector<char> bigBytes(1536 * 1024);
    std::mt19937 random(7);
    for (char& byte : bigBytes) byte = static_cast<char>(random());
    Write(save, saveBytes);
    Write(config, configBytes);
    Write(big, bigBytes);
    Write(regenerable, {'x'});
    Write(fs::temp_directory_path() / "outside.bin", {'y'});

    TvosPersistence::KeepFile(save);
    TvosPersistence::KeepFile(big);
    TvosPersistence::KeepFile(regenerable);                              // DATA/ is not kept
    TvosPersistence::KeepFile(fs::temp_directory_path() / "outside.bin");   // nor anything outside
    TvosPersistence::Flush();                                            // also keeps Config.toml

    const char* home = std::getenv("HOME");
    Check(home && fs::is_regular_file(fs::path(home) / "Library/Preferences/WiiCompiled-persist" /
                                      "NAND/title/00010004/524d4350/data/incompressible.bin"),
          "a file past the preferences budget spills to Library/Preferences");

    fs::remove_all(data, ec);   // what a cache purge does
    Check(!fs::exists(save), "the cache purge removed the save");
    const int restored = TvosPersistence::RestoreMissingFiles();
    std::printf("restored %d file(s)\n", restored);
    Check(restored == 3, "exactly the save, the settings and the spilled file come back");
    Check(Read(save) == saveBytes, "the save comes back byte for byte");
    Check(Read(config) == configBytes, "Config.toml comes back byte for byte");
    Check(Read(big) == bigBytes, "the spilled file comes back byte for byte");
    Check(!fs::exists(regenerable), "DATA/ is not brought back");

    // A file still in the cache is never overwritten by an older kept copy.
    Write(save, {'n', 'e', 'w'});
    Check(TvosPersistence::RestoreMissingFiles() == 0, "nothing is restored over files that are present");
    Check(Read(save) == std::vector<char>{'n', 'e', 'w'}, "the newer cached save is left alone");

    fs::remove_all(data, ec);
    return g_failures == 0 ? 0 : 1;
}
