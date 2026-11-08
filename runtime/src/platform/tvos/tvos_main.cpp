// tvOS entry point. A tvOS app must run UIKit's application loop (with the UIScene lifecycle the
// tvOS 27 SDK requires), so SDL owns main(): SDL_main.h turns the main() below into SDL_main and
// supplies the real one, which calls SDL_RunApp -> UIApplicationMain. SDL then runs it on the main
// thread once the app has finished launching; the executable links with an 8 MiB main-thread
// stack because the guest's boot thread runs there (PublicProducts.cmake).
//
// This file is compiled on tvOS only and outside the unity build: SDL_main.h defines main as a
// macro, which must not leak into other runtime sources.
#undef SDL_MAIN_HANDLED
#include <SDL3/SDL_main.h>

#include <mach/mach.h>
#include <mach/task_info.h>
#include <os/proc.h>

#include <chrono>
#include <cstdio>
#include <thread>

int RuntimeMain(int argc, char** argv);

namespace {
// tvOS ends an app at about 2,097 MB of footprint, often without filing a report. This logs the
// footprint, its peak and the headroom every 15 s into the runtime transcript (console.log), so a
// run that tvOS killed shows whether memory was the reason.
void LogMemoryForever() {
    for (;;) {
        task_vm_info_data_t info{};
        mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) == KERN_SUCCESS) {
            std::fprintf(stderr, "[tvos] memory: footprint %llu MiB, peak %lld MiB, headroom %llu MiB\n",
                         static_cast<unsigned long long>(info.phys_footprint >> 20),
                         static_cast<long long>(info.ledger_phys_footprint_peak >> 20),
                         static_cast<unsigned long long>(os_proc_available_memory() >> 20));
        }
        std::this_thread::sleep_for(std::chrono::seconds(15));
    }
}
} // namespace

int main(int argc, char** argv) {
    std::thread(LogMemoryForever).detach();
    return RuntimeMain(argc, argv);
}
