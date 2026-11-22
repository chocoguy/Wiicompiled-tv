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

#include "platform/tvos_persistence.h"
#include "platform/tvos_platform.h"

#include <mach/mach.h>
#include <mach/task_info.h>
#include <mach/vm_map.h>
#include <os/proc.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <map>
#include <utility>
#include <vector>
#include <cstdio>
#include <thread>

int RuntimeMain(int argc, char** argv);

namespace {
// tvOS ends an app at about 2,097 MB of footprint, often without filing a report, and lowers its
// clocks at thermal state serious (the Apple TV has no fan). This logs the footprint, its peak, the
// headroom and the thermal state every 15 s into the runtime transcript (console.log), so a
// run that tvOS killed shows whether memory was the reason. It also logs the free address space:
// without the extended-virtual-addressing entitlement a tvOS app's address space ends at 454 GiB,
// and the 4 GiB guest space takes 448-452 GiB of it (docs/tvos-porting-plan.md, M6).
struct FreeAddressSpace {
    uint64_t total = 0;
    uint64_t largest = 0;
};

FreeAddressSpace MeasureFreeAddressSpace(uint64_t minAddress, uint64_t maxAddress) {
    FreeAddressSpace free;
    vm_address_t address = static_cast<vm_address_t>(minAddress);
    uint64_t cursor = minAddress;
    for (;;) {
        vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_short_info_data_64_t info{};
        mach_msg_type_number_t count = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &address, &size, &depth,
                                 reinterpret_cast<vm_region_recurse_info_t>(&info), &count) != KERN_SUCCESS) {
            break;
        }
        if (address > cursor) {
            const uint64_t gap = std::min<uint64_t>(address, maxAddress) - cursor;
            free.total += gap;
            free.largest = std::max(free.largest, gap);
        }
        cursor = std::max<uint64_t>(cursor, address + size);
        if (cursor >= maxAddress) break;
        address += size;
    }
    if (maxAddress > cursor) {
        free.total += maxAddress - cursor;
        free.largest = std::max(free.largest, maxAddress - cursor);
    }
    return free;
}

// MKW_TVOS_VM_DUMP=1: also list the largest regions and the space each memory tag holds (tags from
// <mach/vm_statistics.h>, e.g. 1 malloc, 11 malloc large, 30 stack, 74 IOAccelerator).
void DumpAddressSpace(uint64_t minAddress, uint64_t maxAddress) {
    std::map<unsigned, uint64_t> byTag;
    std::vector<std::pair<uint64_t, std::pair<uint64_t, unsigned>>> regions;
    vm_address_t address = static_cast<vm_address_t>(minAddress);
    for (;;) {
        vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_short_info_data_64_t info{};
        mach_msg_type_number_t count = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &address, &size, &depth,
                                 reinterpret_cast<vm_region_recurse_info_t>(&info), &count) != KERN_SUCCESS ||
            address >= maxAddress) {
            break;
        }
        byTag[info.user_tag] += size;
        regions.push_back({size, {address, info.user_tag}});
        address += size;
    }
    std::sort(regions.rbegin(), regions.rend());
    for (size_t i = 0; i < regions.size() && i < 12; ++i) {
        std::fprintf(stderr, "[tvos] vm region 0x%llx %llu MiB tag %u\n",
                     static_cast<unsigned long long>(regions[i].second.first),
                     static_cast<unsigned long long>(regions[i].first >> 20), regions[i].second.second);
    }
    for (const auto& [tag, bytes] : byTag) {
        if (bytes >= (16ull << 20)) {
            std::fprintf(stderr, "[tvos] vm tag %u: %llu MiB\n", tag, static_cast<unsigned long long>(bytes >> 20));
        }
    }
}

void LogMemoryForever() {
    const char* dump = std::getenv("MKW_TVOS_VM_DUMP");
    int ticks = 0;
    for (;;) {
        task_vm_info_data_t info{};
        mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) == KERN_SUCCESS) {
            static const char* const kThermal[] = {"nominal", "fair", "serious", "critical"};
            const int thermal = TvosPlatform::ThermalState();
            const FreeAddressSpace free = MeasureFreeAddressSpace(info.min_address, info.max_address);
            std::fprintf(stderr, "[tvos] memory: footprint %llu MiB, peak %lld MiB, headroom %llu MiB; "
                         "address space free %llu MiB (largest %llu MiB) below %.0f GiB; thermal %s\n",
                         static_cast<unsigned long long>(info.phys_footprint >> 20),
                         static_cast<long long>(info.ledger_phys_footprint_peak >> 20),
                         static_cast<unsigned long long>(os_proc_available_memory() >> 20),
                         static_cast<unsigned long long>(free.total >> 20),
                         static_cast<unsigned long long>(free.largest >> 20),
                         static_cast<double>(info.max_address) / (1ull << 30),
                         thermal >= 0 && thermal <= 3 ? kThermal[thermal] : "?");
        }
        if (dump && *dump == '1' && ++ticks % 4 == 0) {
            DumpAddressSpace(info.min_address, info.max_address);
        }
        std::this_thread::sleep_for(std::chrono::seconds(15));
    }
}
} // namespace

int main(int argc, char** argv) {
    std::thread(LogMemoryForever).detach();
    // Normally already done during static initialization, by the first read of Config.toml.
    TvosPersistence::RestoreMissingFilesOnce();
    return RuntimeMain(argc, argv);
}
