// Address-space probes for the tvOS port (M0). Mirrors what runtime/src/guest_flat_memory_macos.cpp
// does at startup: one fixed 4 GiB reservation, then MEM1/MEM2/owned backing stores aliased into it
// at the Wii's physical, cached and uncached views. It uses vm_allocate/vm_remap from
// <mach/vm_map.h> because <mach/mach_vm.h> is "#error unsupported" in the tvOS SDK, and it also
// tries a POSIX alternative: one unlinked file mapped MAP_SHARED|MAP_FIXED at every alias (TVPort's
// guest_block idea, dm/host/hle_svc.c).
#include "probe.h"

#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <mach/vm_map.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define KIB (1ull << 10)
#define MIB (1ull << 20)
#define GIB (1ull << 30)

static const uint64_t kGuestSpace = 4 * GIB;

// runtime/src/memory.cpp Memory::Config::WiiDefaults and ClassifyBacking.
enum { STORE_MEM1, STORE_MEM2, STORE_KAMEK, STORE_LOCKED, STORE_COUNT };
typedef struct {
    const char* name;
    uint32_t base;
    uint64_t size;
    int store;
} GuestRegion;
static const GuestRegion kRegions[] = {
    {"MEM1_PHYS", 0x00000000u, 24 * MIB, STORE_MEM1},
    {"MEM1", 0x80000000u, 24 * MIB, STORE_MEM1},
    {"MEM1_UNCACHED", 0xC0000000u, 24 * MIB, STORE_MEM1},
    {"MEM2_PHYS", 0x10000000u, 128 * MIB, STORE_MEM2},
    {"MEM2", 0x90000000u, 128 * MIB, STORE_MEM2},
    {"MEM2_UNCACHED", 0xD0000000u, 128 * MIB, STORE_MEM2},
    {"MEM1_KAMEK_OVERLAY", 0x81800000u, 2 * MIB, STORE_KAMEK},
    {"LOCKED_CACHE", 0xE0000000u, 16 * KIB, STORE_LOCKED},
};
#define REGION_COUNT (sizeof kRegions / sizeof kRegions[0])
static const uint64_t kStoreSize[STORE_COUNT] = {24 * MIB, 128 * MIB, 2 * MIB, 16 * KIB};

// Preference order. 512 GiB first because it is the current Apple Silicon base
// (runtime/include/guest_abi/flat_memory.h): if it works nothing in the translated ABI changes.
// Then 4 GiB-aligned bases below the 64 GiB GPU carveout the tvOS SDK declares
// (MACH_VM_MIN_GPU_CARVEOUT_ADDRESS_RAW), higher ones first to stay clear of the shared cache and
// the early heap. Every base is a multiple of 4 GiB, so translated code loads it with one movz.
static const uint64_t kPreferred[] = {
    0x0000008000000000ull, // 512 GiB
    // 448 GiB: the first run on an A15 (tvOS 27.2) found max_address at 454 GiB and 64-448 GiB
    // reserved, which leaves this as the only 4 GiB-aligned slot (MACH_VM_NANO_BASE_ADDRESS).
    0x0000007000000000ull, // 448 GiB
    0x0000000C00000000ull, // 48 GiB
    0x0000000800000000ull, // 32 GiB
    0x0000000400000000ull, // 16 GiB
    0x0000000200000000ull, // 8 GiB
};
#define PREFERRED_COUNT (sizeof kPreferred / sizeof kPreferred[0])

static uint64_t round_up(uint64_t v, uint64_t a) { return (v + a - 1) & ~(a - 1); }
static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static double gib(uint64_t v) { return (double)v / (double)GIB; }
static uint64_t host_page(void) { return (uint64_t)getpagesize(); }

static int try_fixed(uint64_t base, uint64_t size, kern_return_t* out) {
    vm_address_t a = (vm_address_t)base;
    kern_return_t kr = vm_allocate(mach_task_self(), &a, (vm_size_t)size, VM_FLAGS_FIXED);
    if (out) *out = kr;
    if (kr != KERN_SUCCESS) return 0;
    if ((uint64_t)a != base) {
        vm_deallocate(mach_task_self(), a, (vm_size_t)size);
        if (out) *out = KERN_NO_SPACE;
        return 0;
    }
    return 1;
}

// ---- Layout ----

typedef struct {
    uint64_t start, end;
    unsigned tag;
    int prot;
    int submap;
} Span;
static Span g_spans[8192];

void probe_vm_layout(const char* phase) {
    probe_log("[layout:%s] vm_page_size=%lu vm_kernel_page_size=%lu getpagesize=%d", phase,
              (unsigned long)vm_page_size, (unsigned long)vm_kernel_page_size, getpagesize());

    task_vm_info_data_t info;
    memset(&info, 0, sizeof info);
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    uint64_t maxAddress = 0;
    if (kr == KERN_SUCCESS) {
        maxAddress = info.max_address;
        probe_log("[layout:%s] task min_address=0x%llx max_address=0x%llx (%.2f GiB) virtual_size=%.2f GiB "
                  "phys_footprint=%.1f MiB limit_bytes_remaining=%.1f MiB (task_vm_info count %u)",
                  phase, (unsigned long long)info.min_address, (unsigned long long)info.max_address,
                  gib(info.max_address), gib(info.virtual_size), (double)info.phys_footprint / MIB,
                  (double)info.limit_bytes_remaining / MIB, count);
    } else {
        probe_log("[layout:%s] task_info(TASK_VM_INFO) failed: %s", phase, mach_error_string(kr));
    }

    size_t n = 0;
    vm_address_t addr = 0;
    for (;;) {
        vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_info_data_64_t si;
        mach_msg_type_number_t sc = VM_REGION_SUBMAP_INFO_COUNT_64;
        kr = vm_region_recurse_64(mach_task_self(), &addr, &size, &depth, (vm_region_recurse_info_t)&si, &sc);
        if (kr != KERN_SUCCESS) break;
        if (n < sizeof g_spans / sizeof g_spans[0]) {
            g_spans[n++] = (Span){addr, (uint64_t)addr + size, si.user_tag, si.protection, si.is_submap};
        }
        addr += size;
    }
    if (!n) {
        probe_log("[layout:%s] no regions listed", phase);
        return;
    }
    probe_log("[layout:%s] %zu top-level regions, lowest 0x%llx, highest end 0x%llx (%.2f GiB)", phase, n,
              (unsigned long long)g_spans[0].start, (unsigned long long)g_spans[n - 1].end, gib(g_spans[n - 1].end));

    // Regions above 4 GiB, coalesced when they touch and share a tag, so a heap of small malloc
    // regions prints as one line.
    int printed = 0;
    for (size_t i = 0; i < n && printed < 60; ++i) {
        if (g_spans[i].end <= 4 * GIB) continue;
        uint64_t s = g_spans[i].start, e = g_spans[i].end;
        unsigned tag = g_spans[i].tag;
        int submap = g_spans[i].submap;
        size_t pieces = 1;
        while (i + 1 < n && g_spans[i + 1].start - e < 64 * MIB && g_spans[i + 1].tag == tag &&
               g_spans[i + 1].submap == submap) {
            e = g_spans[++i].end;
            ++pieces;
        }
        probe_log("[layout:%s]   0x%011llx-0x%011llx %9.1f MiB tag=%u%s (%zu regions)", phase, (unsigned long long)s,
                  (unsigned long long)e, (double)(e - s) / MIB, tag, submap ? " submap" : "", pieces);
        ++printed;
    }

    // One character per 4 GiB slot from 0 to 1 TiB: '.' free, 's' shared-cache/submap, '#' other
    // mappings, ' ' above the task's max_address. A guest space needs one whole '.' slot.
    char map[257];
    for (int slot = 0; slot < 256; ++slot) {
        const uint64_t s = (uint64_t)slot * 4 * GIB, e = s + 4 * GIB;
        char c = (maxAddress && s >= maxAddress) ? ' ' : '.';
        for (size_t i = 0; i < n && c != '#'; ++i) {
            if (g_spans[i].start < e && g_spans[i].end > s) c = g_spans[i].submap ? 's' : '#';
        }
        map[slot] = c;
    }
    map[256] = 0;
    probe_log("[layout:%s] 4 GiB slots   0-255 GiB: %.64s", phase, map);
    probe_log("[layout:%s] 4 GiB slots 256-511 GiB: %.64s", phase, map + 64);
    probe_log("[layout:%s] 4 GiB slots 512-767 GiB: %.64s", phase, map + 128);
    probe_log("[layout:%s] 4 GiB slots 768-1023 GiB: %.64s", phase, map + 192);

    // Free gaps of at least 4 GiB (where a 4 GiB-aligned guest space fits).
    uint64_t top = maxAddress ? maxAddress : g_spans[n - 1].end;
    for (size_t i = 0; i <= n; ++i) {
        uint64_t gapStart = i == 0 ? 0 : g_spans[i - 1].end;
        uint64_t gapEnd = i == n ? top : g_spans[i].start;
        if (gapEnd <= gapStart) continue;
        uint64_t aligned = round_up(gapStart, 4 * GIB);
        if (aligned + 4 * GIB <= gapEnd) {
            probe_log("[layout:%s]   free gap 0x%011llx-0x%011llx (%.1f GiB), 4 GiB-aligned slots from 0x%llx", phase,
                      (unsigned long long)gapStart, (unsigned long long)gapEnd, gib(gapEnd - gapStart),
                      (unsigned long long)aligned);
        }
    }
}

void probe_vm_reserve_capacity(void) {
    static const uint64_t sizes[] = {4, 8, 12, 16, 24, 32, 48, 64, 128, 256, 1024};
    for (size_t i = 0; i < sizeof sizes / sizeof sizes[0]; ++i) {
        vm_address_t a = 0;
        kern_return_t kr = vm_allocate(mach_task_self(), &a, (vm_size_t)(sizes[i] * GIB), VM_FLAGS_ANYWHERE);
        if (kr == KERN_SUCCESS) {
            probe_log("[capacity] reserve %4llu GiB anywhere: ok at 0x%llx", (unsigned long long)sizes[i],
                      (unsigned long long)a);
            vm_deallocate(mach_task_self(), a, (vm_size_t)(sizes[i] * GIB));
        } else {
            probe_log("[capacity] reserve %4llu GiB anywhere: FAILED (%s)", (unsigned long long)sizes[i],
                      mach_error_string(kr));
        }
    }
}

// ---- Alias test ----

typedef enum { ALIAS_VM_REMAP, ALIAS_FILE } AliasKind;

static int check_mirrors(uint8_t* base, const char** why) {
    // Writes through the cached view, reads through the other two views.
    static const uint32_t probesMem1[] = {0x0, 0x1000, 0x7fff0, 0x17ffff0};
    static const uint32_t probesMem2[] = {0x0, 0x4000, 0x3fffff0, 0x7fffff0};
    for (size_t i = 0; i < 4; ++i) {
        uint32_t off = probesMem1[i];
        volatile uint64_t* w = (volatile uint64_t*)(base + 0x80000000u + off);
        *w = 0xA5A5000000000000ull | off;
        if (*(volatile uint64_t*)(base + 0x00000000u + off) != *w ||
            *(volatile uint64_t*)(base + 0xC0000000u + off) != *w) {
            *why = "MEM1 views disagree";
            return 0;
        }
    }
    for (size_t i = 0; i < 4; ++i) {
        uint32_t off = probesMem2[i];
        volatile uint64_t* w = (volatile uint64_t*)(base + 0xD0000000u + off);
        *w = 0x5A5A000000000000ull | off;
        if (*(volatile uint64_t*)(base + 0x10000000u + off) != *w ||
            *(volatile uint64_t*)(base + 0x90000000u + off) != *w) {
            *why = "MEM2 views disagree";
            return 0;
        }
    }
    uint32_t* counter = (uint32_t*)(base + 0x80002000u);
    *counter = 0;
    for (int i = 0; i < 1000; ++i) __atomic_fetch_add(counter, 1, __ATOMIC_SEQ_CST);
    if (__atomic_load_n((uint32_t*)(base + 0xC0002000u), __ATOMIC_SEQ_CST) != 1000) {
        *why = "atomics through one view not seen through another";
        return 0;
    }
    if (*(volatile uint32_t*)(base + 0x81800000u + 0x100) != 0 || *(volatile uint32_t*)(base + 0xE0000000u + 0x10) != 0) {
        *why = "owned regions not zero-filled";
        return 0;
    }
    // The Kamek overlay sits right after MEM1's cached view (0x81800000) and is its own store: a write
    // there must not show up past the end of MEM1's physical view, which is plain reservation.
    *(volatile uint32_t*)(base + 0x81800000u) = 0x1234;
    if (*(volatile uint32_t*)(base + 0x01800000u) == 0x1234 || *(volatile uint32_t*)(base + 0xC1800000u) == 0x1234) {
        *why = "the Kamek overlay aliases memory past MEM1";
        return 0;
    }
    return 1;
}

static int alias_test(uint64_t base, AliasKind kind, const char* cacheDir) {
    const char* label = kind == ALIAS_VM_REMAP ? "vm_remap" : "file MAP_SHARED";
    const uint64_t pg = host_page();
    kern_return_t kr;
    if (!try_fixed(base, kGuestSpace, &kr)) {
        probe_log("[alias:%s] base 0x%llx: reservation FAILED (%s)", label, (unsigned long long)base, mach_error_string(kr));
        return 0;
    }
    uint8_t* stores[STORE_COUNT] = {0};
    uint64_t storeOffset[STORE_COUNT] = {0};
    int fd = -1;
    int ok = 1;
    const char* why = "";
    uint64_t t0 = now_ns();

    if (kind == ALIAS_VM_REMAP) {
        for (int s = 0; s < STORE_COUNT && ok; ++s) {
            void* p = mmap(NULL, round_up(kStoreSize[s], pg), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
            if (p == MAP_FAILED) {
                ok = 0;
                why = "anonymous backing store mmap failed";
            } else {
                stores[s] = p;
            }
        }
    } else {
        char path[1024];
        snprintf(path, sizeof path, "%s/probe-guest.bin", cacheDir ? cacheDir : "/tmp");
        unlink(path);
        fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0600);
        uint64_t total = 0;
        for (int s = 0; s < STORE_COUNT; ++s) {
            storeOffset[s] = total;
            total += round_up(kStoreSize[s], pg);
        }
        if (fd < 0) {
            ok = 0;
            why = "backing file open failed";
        } else {
            unlink(path);
            if (ftruncate(fd, (off_t)total) != 0) {
                ok = 0;
                why = "ftruncate failed";
            }
        }
    }

    for (size_t i = 0; i < REGION_COUNT && ok; ++i) {
        const GuestRegion* r = &kRegions[i];
        const uint64_t size = round_up(r->size, pg);
        if (kind == ALIAS_VM_REMAP) {
            vm_address_t target = (vm_address_t)(base + r->base);
            vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
            kr = vm_remap(mach_task_self(), &target, (vm_size_t)size, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                          mach_task_self(), (vm_address_t)stores[r->store], FALSE, &cur, &max, VM_INHERIT_NONE);
            if (kr != KERN_SUCCESS || (uint64_t)target != base + r->base) {
                ok = 0;
                why = r->name;
                probe_log("[alias:%s] base 0x%llx: vm_remap %s failed: %s", label, (unsigned long long)base, r->name,
                          mach_error_string(kr));
            } else if (!(cur & VM_PROT_WRITE)) {
                ok = 0;
                why = "remapped view not writable";
            }
        } else {
            void* m = mmap((void*)(uintptr_t)(base + r->base), size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd,
                           (off_t)storeOffset[r->store]);
            if (m == MAP_FAILED || (uint64_t)(uintptr_t)m != base + r->base) {
                ok = 0;
                why = r->name;
                probe_log("[alias:%s] base 0x%llx: mmap %s failed: errno %d (%s)", label, (unsigned long long)base,
                          r->name, errno, strerror(errno));
            }
        }
    }
    uint64_t tMap = now_ns() - t0;

    double fillGBs = 0, copyGBs = 0;
    if (ok) {
        uint8_t* g = (uint8_t*)(uintptr_t)base;
        ok = check_mirrors(g, &why);
        if (ok && kind == ALIAS_VM_REMAP) {
            // The backing store itself sees writes made through the guest views.
            if (*(volatile uint64_t*)(stores[STORE_MEM1] + 0x1000) != (0xA5A5000000000000ull | 0x1000)) {
                ok = 0;
                why = "MEM1 backing store does not see guest writes";
            }
        }
        if (ok) {
            uint64_t t = now_ns();
            memset(g + 0x90000000u, 0x3C, 128 * MIB);
            fillGBs = (double)(128 * MIB) / (double)(now_ns() - t);
            t = now_ns();
            memcpy(g + 0x80000000u, g + 0x90000000u, 24 * MIB);
            copyGBs = (double)(24 * MIB) / (double)(now_ns() - t);
            if (*(volatile uint8_t*)(g + 0x00000000u + 12345) != 0x3C) {
                ok = 0;
                why = "memcpy through MEM1 not seen at MEM1_PHYS";
            }
        }
    }

    vm_deallocate(mach_task_self(), (vm_address_t)base, (vm_size_t)kGuestSpace);
    for (int s = 0; s < STORE_COUNT; ++s) {
        if (stores[s]) munmap(stores[s], round_up(kStoreSize[s], pg));
    }
    if (fd >= 0) close(fd);

    if (ok) {
        probe_log("[alias:%s] base 0x%llx (%.0f GiB): OK - 8 views mapped in %.2f ms, mirrors/atomics/zero-fill pass, "
                  "fill %.1f GB/s, copy %.1f GB/s",
                  label, (unsigned long long)base, gib(base), (double)tMap / 1e6, fillGBs, copyGBs);
    } else {
        probe_log("[alias:%s] base 0x%llx (%.0f GiB): FAILED (%s)", label, (unsigned long long)base, gib(base), why);
    }
    return ok;
}

// ---- Fixed bases ----

static int in_preferred(uint64_t b) {
    for (size_t i = 0; i < PREFERRED_COUNT; ++i)
        if (kPreferred[i] == b) return 1;
    return 0;
}

int probe_vm_fixed_bases(const char* phase, int full, const char* cacheDir) {
    uint64_t list[96];
    size_t n = 0;
    for (size_t i = 0; i < PREFERRED_COUNT; ++i) list[n++] = kPreferred[i];
    for (uint64_t g = 4; g <= 60; g += 4) {
        if (!in_preferred(g * GIB)) list[n++] = g * GIB;
    }
    static const uint64_t high[] = {64, 128, 256, 448, 1024, 2048, 4096, 8184};
    for (size_t i = 0; i < sizeof high / sizeof high[0]; ++i) {
        if (!in_preferred(high[i] * GIB)) list[n++] = high[i] * GIB;
    }

    int successes = 0;
    char okList[1024] = "", failList[1024] = "";
    for (size_t i = 0; i < n; ++i) {
        kern_return_t kr;
        int ok = try_fixed(list[i], kGuestSpace, &kr);
        if (ok) {
            vm_deallocate(mach_task_self(), (vm_address_t)list[i], (vm_size_t)kGuestSpace);
            ++successes;
        }
        char item[64];
        snprintf(item, sizeof item, "%s%llu", ok ? (okList[0] ? "," : "") : (failList[0] ? "," : ""),
                 (unsigned long long)(list[i] / GIB));
        strlcat(ok ? okList : failList, item, ok ? sizeof okList : sizeof failList);
        if (!ok && in_preferred(list[i])) {
            probe_log("[fixed:%s] base 0x%llx (%.0f GiB): FAILED (%s)", phase, (unsigned long long)list[i], gib(list[i]),
                      mach_error_string(kr));
        }
        if (ok && full && in_preferred(list[i])) alias_test(list[i], ALIAS_VM_REMAP, cacheDir);
    }
    probe_log("[fixed:%s] 4 GiB FIXED reservation ok at GiB: %s", phase, okList[0] ? okList : "(none)");
    probe_log("[fixed:%s] 4 GiB FIXED reservation failed at GiB: %s", phase, failList[0] ? failList : "(none)");

    if (full) {
        uint64_t preferred = probe_vm_preferred_base();
        if (preferred) {
            probe_log("[fixed:%s] preferred base: 0x%llx (%.0f GiB)", phase, (unsigned long long)preferred, gib(preferred));
            alias_test(preferred, ALIAS_FILE, cacheDir);
        } else {
            probe_log("[fixed:%s] no preferred base could be reserved", phase);
        }
    }
    return successes;
}

uint64_t probe_vm_preferred_base(void) {
    for (size_t i = 0; i < PREFERRED_COUNT; ++i) {
        if (try_fixed(kPreferred[i], kGuestSpace, NULL)) {
            vm_deallocate(mach_task_self(), (vm_address_t)kPreferred[i], (vm_size_t)kGuestSpace);
            return kPreferred[i];
        }
    }
    return 0;
}

int probe_vm_hold(uint64_t base) {
    kern_return_t kr;
    if (!try_fixed(base, kGuestSpace, &kr)) {
        probe_log("[hold] base 0x%llx: FAILED (%s)", (unsigned long long)base, mach_error_string(kr));
        return 0;
    }
    // Touch a page so the reservation is real memory, as the guest's would be.
    *(volatile uint32_t*)(uintptr_t)(base + 0x80000000u) = 0xC0FFEE;
    return 1;
}

void probe_vm_release(uint64_t base) { vm_deallocate(mach_task_self(), (vm_address_t)base, (vm_size_t)kGuestSpace); }

// ---- Signals ----

static sigjmp_buf g_jump;
static volatile sig_atomic_t g_signal;
static void* volatile g_faultAddress;

static void on_fault(int sig, siginfo_t* info, void* uc) {
    (void)uc;
    g_signal = sig;
    g_faultAddress = info ? info->si_addr : NULL;
    siglongjmp(g_jump, 1);
}

void probe_signals(void) {
    struct sigaction sa, oldSegv, oldBus;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_fault;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, &oldSegv) != 0 || sigaction(SIGBUS, &sa, &oldBus) != 0) {
        probe_log("[signals] sigaction FAILED: errno %d", errno);
        return;
    }
    const size_t pg = (size_t)host_page();
    uint8_t* page = mmap(NULL, pg, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    for (int write = 0; write <= 1; ++write) {
        g_signal = 0;
        g_faultAddress = NULL;
        if (sigsetjmp(g_jump, 1) == 0) {
            if (write) {
                *(volatile uint32_t*)(page + 64) = 1;
            } else {
                volatile uint32_t v = *(volatile uint32_t*)(page + 64);
                (void)v;
            }
            probe_log("[signals] %s of a PROT_NONE page did not fault", write ? "write" : "read");
        } else {
            probe_log("[signals] %s of a PROT_NONE page: signal %d (%s) at %p, expected %p: %s", write ? "write" : "read",
                      (int)g_signal, g_signal == SIGSEGV ? "SIGSEGV" : g_signal == SIGBUS ? "SIGBUS" : "?",
                      g_faultAddress, (void*)(page + 64), g_faultAddress == page + 64 ? "recovered OK" : "address mismatch");
        }
    }
    munmap(page, pg);
    sigaction(SIGSEGV, &oldSegv, NULL);
    sigaction(SIGBUS, &oldBus, NULL);
}
