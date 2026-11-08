// M0 feasibility probe shared declarations. probe_vm.c is plain C so it also builds and runs
// on a Mac (see run-probe.sh --host), which checks the probe's own logic before a device run.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Report sink: one line per call, also mirrored to stderr. Defined by the app (main.m) or the
// host test driver (host_main.c).
void probe_log(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

// Address-space layout: page sizes, the task's VM bounds and footprint, mapped regions above
// 4 GiB and the largest free gaps.
void probe_vm_layout(const char* phase);

// How much address space can be reserved anywhere (VM_FLAGS_ANYWHERE) in one block.
void probe_vm_reserve_capacity(void);

// Tries a fixed 4 GiB reservation at every candidate base. Returns the number of candidates that
// succeeded; when full is nonzero each success also runs the vm_remap alias test, and the
// preferred success runs the file-backed alias test as well (cache_dir holds its backing file).
int probe_vm_fixed_bases(const char* phase, int full, const char* cache_dir);

// The first candidate in preference order that a fixed 4 GiB reservation succeeds at, or 0.
uint64_t probe_vm_preferred_base(void);

// Reserves 4 GiB at base and leaves it reserved (for the Metal-under-reservation check).
// Returns 1 on success.
int probe_vm_hold(uint64_t base);
void probe_vm_release(uint64_t base);

// SIGSEGV/SIGBUS delivery and recovery on a PROT_NONE page (the runtime's fault handler path).
void probe_signals(void);

#ifdef __cplusplus
}
#endif
