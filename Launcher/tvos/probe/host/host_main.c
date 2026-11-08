// Mac driver for probe_vm.c (run-probe.sh --host): checks the probe's own logic on a machine where
// the macOS runtime already works (the 512 GiB base must succeed and every alias test must pass).
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

#include "../Sources/probe.h"

void probe_log(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("PROBE ", stdout);
    vprintf(fmt, ap);
    fputc('\n', stdout);
    va_end(ap);
}

int main(int argc, char** argv) {
    const char* cacheDir = argc > 1 ? argv[1] : getenv("TMPDIR");
    probe_vm_layout("host");
    probe_vm_reserve_capacity();
    probe_vm_fixed_bases("host", 1, cacheDir);
    probe_signals();
    return 0;
}
