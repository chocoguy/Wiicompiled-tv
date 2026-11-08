// Steam Input layout control on tvOS: there is no Steam client on an Apple TV, and the desktop
// implementation (steam_input_layout.cpp) needs libproc and posix_spawn, which tvOS lacks or
// prohibits. runtime/CMakeLists.txt builds this file in its place on tvOS only.
#include "steam_input_layout.h"

namespace SteamInputLayout {

void Initialize(bool enabled, uint32_t appId) {
    static_cast<void>(enabled);
    static_cast<void>(appId);
}

void HandleEvents(const AuroraEvent* events) { static_cast<void>(events); }

void Release() noexcept {}

} // namespace SteamInputLayout
