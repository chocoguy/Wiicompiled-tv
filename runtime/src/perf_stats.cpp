#include "perf_stats.h"

#include "runtime_log.h"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstring>

namespace PerfStats {
namespace {

using Clock = std::chrono::steady_clock;

constexpr size_t kWindow = 240;

thread_local Clock::duration t_wait{};
thread_local Clock::duration t_pacing{};

struct FrameWindow {
    Clock::time_point last{};
    Clock::time_point windowStart{};
    std::array<double, kWindow> busyMs{};
    std::array<double, kWindow> frameMs{};
    double stallMs = 0;
    double pacingMs = 0;
    size_t count = 0;
};

FrameWindow g_window;
// Static initialization runs as the executable loads, so "t=" is seconds since launch, which lines up
// with an Instruments trace started by xctrace --launch.
const Clock::time_point g_processStart = Clock::now();

} // namespace

bool Enabled() noexcept {
    static const bool enabled = [] {
        const char* value = std::getenv("MKW_PERF_STATS");
        return value != nullptr && std::strcmp(value, "0") != 0;
    }();
    return enabled;
}

void AddWait(Clock::duration wait, WaitKind kind) noexcept {
    t_wait += wait;
    if (kind == WaitKind::Pacing) t_pacing += wait;
}

void OnFramePresented() noexcept {
    if (!Enabled()) {
        return;
    }
    using Ms = std::chrono::duration<double, std::milli>;
    const auto now = Clock::now();
    const Clock::duration wait = t_wait;
    const Clock::duration pacing = t_pacing;
    t_wait = {};
    t_pacing = {};
    if (g_window.last == Clock::time_point{}) {
        g_window.last = now;
        g_window.windowStart = now;
        return;
    }
    const auto frame = now - g_window.last;
    g_window.last = now;
    g_window.frameMs[g_window.count] = Ms(frame).count();
    g_window.busyMs[g_window.count++] = Ms(frame - wait).count();
    g_window.pacingMs += Ms(pacing).count();
    g_window.stallMs += Ms(wait - pacing).count();
    if (g_window.count < kWindow) {
        return;
    }
    const double seconds = std::chrono::duration<double>(now - g_window.windowStart).count();
    std::array<double, kWindow> sorted = g_window.busyMs;
    std::sort(sorted.begin(), sorted.end());
    std::array<double, kWindow> frames = g_window.frameMs;
    std::sort(frames.begin(), frames.end());
    double sum = 0;
    for (const double ms : sorted) {
        sum += ms;
    }
    RT_LOGF("perf", "t=%.1fs %.1f fps over %zu frames (frame p95 %.2f max %.2f ms) | busy ms/frame: avg %.3f median %.3f p95 %.3f max %.3f | per frame: stalled %.2f ms, pacing sleep %.2f ms\n",
            std::chrono::duration<double>(now - g_processStart).count(), kWindow / seconds, kWindow,
            frames[kWindow * 95 / 100], frames[kWindow - 1], sum / kWindow,
            sorted[kWindow / 2], sorted[kWindow * 95 / 100], sorted[kWindow - 1], g_window.stallMs / kWindow,
            g_window.pacingMs / kWindow);
    g_window.count = 0;
    g_window.stallMs = 0;
    g_window.pacingMs = 0;
    g_window.windowStart = now;
}

} // namespace PerfStats
