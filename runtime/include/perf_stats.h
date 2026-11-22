#pragma once

#include <chrono>

// MKW_PERF_STATS=1: logs, per window of presented frames, the frame rate actually presented and the
// game thread's busy time per frame, i.e. wall time minus the time it spends blocked. Blocked time is
// split into VI pacing (sleeping until the next 60 Hz retrace, which is idle headroom) and stalls on
// the GX worker, the GPU or the audio mixer (time lost to something else being slow).
namespace PerfStats {

enum class WaitKind { Stall, Pacing };

bool Enabled() noexcept;
void AddWait(std::chrono::steady_clock::duration wait, WaitKind kind = WaitKind::Stall) noexcept;
void OnFramePresented() noexcept;

class WaitScope {
public:
    explicit WaitScope(WaitKind kind = WaitKind::Stall) noexcept
        : m_start(Enabled() ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{}), m_kind(kind) {}
    ~WaitScope() {
        if (m_start != std::chrono::steady_clock::time_point{}) {
            AddWait(std::chrono::steady_clock::now() - m_start, m_kind);
        }
    }
    WaitScope(const WaitScope&) = delete;
    WaitScope& operator=(const WaitScope&) = delete;

private:
    std::chrono::steady_clock::time_point m_start;
    WaitKind m_kind;
};

} // namespace PerfStats
