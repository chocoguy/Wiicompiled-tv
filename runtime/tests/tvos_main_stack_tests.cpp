// The guest's boot thread runs on the host main thread (runtime/src/main.cpp, InvokeIndirectCpu),
// and tvOS gives that thread about 1 MiB where macOS gives 8 MiB. The tvOS executables link with
// -stack_size MKW_EXPECTED_MAIN_STACK; this checks the kernel honors it by really recursing through
// most of that stack, so an ignored option fails here as a stack overflow rather than in the game.
#include <pthread.h>

#include <cstddef>
#include <cstdio>

#ifndef MKW_EXPECTED_MAIN_STACK
#error "MKW_EXPECTED_MAIN_STACK must name the -stack_size the test was linked with"
#endif

namespace {
constexpr std::size_t kFrameBytes = 64 * 1024;

// Each call keeps a 64 KiB frame live across the recursive call and touches every page of it.
__attribute__((noinline)) std::size_t Descend(std::size_t remaining) {
    volatile unsigned char frame[kFrameBytes];
    for (std::size_t i = 0; i < kFrameBytes; i += 4096) {
        frame[i] = static_cast<unsigned char>(remaining);
    }
    std::size_t below = remaining > kFrameBytes ? Descend(remaining - kFrameBytes) : 0;
    return below + kFrameBytes + frame[0] * 0;
}
} // namespace

int main() {
    const std::size_t expected = static_cast<std::size_t>(MKW_EXPECTED_MAIN_STACK);
    const std::size_t reported = pthread_get_stacksize_np(pthread_self());
    std::printf("main thread stack: %zu KiB reported, %zu KiB linked\n", reported >> 10, expected >> 10);
    if (reported < expected) {
        std::fprintf(stderr, "the main thread has less stack than the executable was linked with\n");
        return 1;
    }
    const std::size_t used = Descend(expected / 8 * 7);
    std::printf("recursed through %zu KiB of main-thread stack\n", used >> 10);
    return 0;
}
