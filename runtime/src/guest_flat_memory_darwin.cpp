// Flat guest memory for macOS and tvOS. One fixed 4 GiB reservation at kFixedFlatGuestBase, with
// MEM1, MEM2 and owned backing stores aliased into it at the Wii's physical, cached and uncached
// views. It uses vm_allocate/vm_remap from <mach/vm_map.h>, which are the mach_vm_* calls under
// another name in a 64-bit task: <mach/mach_vm.h> is "#error unsupported" in the tvOS SDK.
#include "guest_flat_memory.h"

#include <TargetConditionals.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace GuestFlat {
bool g_requiresCheckedAccess = false;
namespace {

struct Store {
    Backing kind = Backing::Owned;
    uint32_t owned = 0;
    uint64_t size = 0;
    uint8_t* host = nullptr;
};

struct Mapping {
    uint32_t base = 0;
    uint64_t size = 0;
    uint8_t* host = nullptr;
};

std::mutex g_mutex;
std::vector<Store> g_stores;
std::vector<Mapping> g_mappings;
std::vector<RegionRequest> g_layout;
uint8_t* g_base = nullptr;
bool g_active = false;
// Set when the static constructor below already holds the 4 GiB slot.
bool g_preReserved = false;

#if TARGET_OS_TV
// A tvOS app's address space ends at 454 GiB, and the only free 4 GiB-aligned slot is the 448 GiB
// guest base (docs/tvos-m0-findings.md). Without the extended-virtual-addressing entitlement, any
// allocation too big for the ~2 GiB free below the shared cache lands in that slot, so claim it
// before UIKit, SDL, Metal or Dawn run: static constructors run before main(). Initialize() adopts
// the reservation. If this fails, Initialize() tries again and reports the error.
__attribute__((constructor)) void ReserveGuestSpaceAtLoad() {
    vm_address_t address = kFixedFlatGuestBase;
    if (vm_allocate(mach_task_self(), &address, kGuestSpaceSize, VM_FLAGS_FIXED) == KERN_SUCCESS) {
        if (address == kFixedFlatGuestBase) {
            g_preReserved = true;
        } else {
            vm_deallocate(mach_task_self(), address, kGuestSpaceSize);
        }
    }
}
#endif

inline uint64_t RoundUp(uint64_t value, uint64_t align) {
    return (value + align - 1) & ~(align - 1);
}

uint64_t Offset(const RegionRequest& r) {
    if (r.backing == Backing::Mem1) return r.base & 0x1fffffffu;
    if (r.backing == Backing::Mem2) return (r.base & 0x1fffffffu) - 0x10000000u;
    return 0;
}

bool Same(const std::vector<RegionRequest>& a, const std::vector<RegionRequest>& b) {
    return a.size() == b.size() && std::equal(a.begin(), a.end(), b.begin(),
        [](const auto& x, const auto& y) { return x.base == y.base && x.size == y.size && x.backing == y.backing; });
}

} // namespace

bool IsActive() { return g_active; }

void Initialize(const std::vector<RegionRequest>& regions) {
    std::lock_guard lock(g_mutex);
    const uint64_t pageSize = static_cast<uint64_t>(getpagesize());
    g_requiresCheckedAccess = pageSize > kGuestPageSize;
    if (g_active) {
        if (!Same(g_layout, regions))
            throw std::runtime_error("flat guest layout cannot be remapped");
        return;
    }

    for (size_t i = 0; i < regions.size(); ++i) {
        const auto& r = regions[i];
        if (r.size == 0) continue;
        if (r.size > kGuestSpaceSize - r.base ||
            r.base % pageSize != 0 || Offset(r) % pageSize != 0) {
            throw std::runtime_error("invalid flat guest memory region");
        }
        const uint64_t end = static_cast<uint64_t>(r.base) + RoundUp(r.size, pageSize);
        for (size_t j = 0; j < i; ++j) {
            const auto& prior = regions[j];
            if (prior.size == 0) continue;
            const uint64_t priorEnd = static_cast<uint64_t>(prior.base) + RoundUp(prior.size, pageSize);
            if (r.base < priorEnd && prior.base < end) {
                throw std::runtime_error("overlapping flat guest memory regions");
            }
        }
    }

    vm_address_t address = kFixedFlatGuestBase;
    const kern_return_t reserved = g_preReserved
        ? KERN_SUCCESS
        : vm_allocate(mach_task_self(), &address, kGuestSpaceSize, VM_FLAGS_FIXED);
    g_preReserved = false;   // from here on the reservation is owned (and released on failure) below
    if (reserved != KERN_SUCCESS || address != kFixedFlatGuestBase) {
        if (reserved == KERN_SUCCESS) {
            vm_deallocate(mach_task_self(), address, kGuestSpaceSize);
        }
        char message[160];
        std::snprintf(message, sizeof message, "unable to reserve the fixed 4 GiB guest address space at 0x%llx: %s",
                      static_cast<unsigned long long>(kFixedFlatGuestBase),
                      reserved == KERN_SUCCESS ? "placed elsewhere" : mach_error_string(reserved));
        throw std::runtime_error(message);
    }
    g_base = reinterpret_cast<uint8_t*>(address);

    std::vector<Store> stores;
    try {
        for (const auto& r : regions) {
            if (!r.size) continue;
            const uint32_t owned = r.backing == Backing::Owned ? r.base : 0;
            auto it = std::find_if(stores.begin(), stores.end(), [&](const Store& s) {
                return s.kind == r.backing && s.owned == owned;
            });
            const uint64_t need = RoundUp(Offset(r) + r.size, pageSize);
            if (it == stores.end()) {
                stores.push_back({r.backing, owned, need, nullptr});
            } else {
                it->size = std::max(it->size, need);
            }
        }

        for (auto& s : stores) {
            void* host = mmap(nullptr, static_cast<size_t>(s.size), PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANON, -1, 0);
            if (host == MAP_FAILED) {
                throw std::runtime_error("unable to allocate an anonymous guest backing store");
            }
            s.host = static_cast<uint8_t*>(host);
        }

        for (const auto& r : regions) {
            if (!r.size) continue;
            const uint32_t owned = r.backing == Backing::Owned ? r.base : 0;
            const auto& s = *std::find_if(stores.begin(), stores.end(), [&](const Store& x) {
                return x.kind == r.backing && x.owned == owned;
            });
            vm_address_t target = reinterpret_cast<vm_address_t>(g_base + r.base);
            vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
            const kern_return_t kr = vm_remap(
                mach_task_self(),
                &target,
                static_cast<vm_size_t>(RoundUp(r.size, pageSize)),
                0,
                VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                mach_task_self(),
                reinterpret_cast<vm_address_t>(s.host + Offset(r)),
                FALSE,
                &cur,
                &max,
                VM_INHERIT_NONE
            );
            if (kr != KERN_SUCCESS) {
                throw std::runtime_error(std::string("vm_remap guest alias failed: ") + mach_error_string(kr));
            }
            g_mappings.push_back({r.base, r.size, s.host + Offset(r)});
        }

        g_layout = regions;
        g_stores = std::move(stores);
        g_active = true;
    } catch (...) {
        for (auto& s : stores) {
            if (s.host != nullptr) {
                munmap(s.host, static_cast<size_t>(s.size));
            }
        }
        vm_deallocate(mach_task_self(), address, kGuestSpaceSize);
        g_mappings.clear();
        g_stores.clear();
        g_layout.clear();
        g_base = nullptr;
        throw;
    }
}

uint8_t* HostPointer(uint32_t a) {
    for (const auto& m : g_mappings) {
        if (a >= m.base && uint64_t(a - m.base) < m.size) {
            return m.host + (a - m.base);
        }
    }
    return nullptr;
}

void ProtectDeferredRange(uint32_t, size_t) {}
void UnprotectDeferredRange(uint32_t, size_t) {}
void RegisterExecutableRange(uint32_t, uint32_t) {}
FaultCounters Counters() { return {}; }
void LogFaultSummary() noexcept {}
bool HandleAccessViolation(void*, bool) noexcept { return false; }

} // namespace GuestFlat
