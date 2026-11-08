/* Entry point of the tvOS test executables that ctest runs on an Apple TV through
 * Launcher/tvos/run_on_device.py. devicectl reports "exit code 0" for these plain (non-UIKit)
 * apps whether they return 3 or abort, so each test prints its own result instead: this entry
 * (linked with -e) calls the test's main() and prints MKW-TVOS-TEST-EXIT=<status>, and a fatal
 * signal prints MKW-TVOS-TEST-SIGNAL=<number> before its default action runs. The runner passes
 * a test only when it printed MKW-TVOS-TEST-EXIT=0. */
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char** argv);

static void report_signal(int sig) {
    /* async-signal-safe: no stdio, a fixed buffer and write(2) */
    char line[40] = "MKW-TVOS-TEST-SIGNAL=";
    size_t n = strlen(line);
    char digits[4];
    int count = 0;
    do {
        digits[count++] = (char)('0' + sig % 10);
        sig /= 10;
    } while (sig && count < 3);
    while (count) line[n++] = digits[--count];
    line[n++] = '\n';
    (void)write(STDERR_FILENO, line, n);
}

static void on_fatal_signal(int sig) {
    report_signal(sig);
    signal(sig, SIG_DFL);
    raise(sig);
}

int mkw_tvos_test_entry(int argc, char** argv) {
    static const int fatal[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP};
    for (size_t i = 0; i < sizeof fatal / sizeof fatal[0]; ++i) {
        struct sigaction action;
        memset(&action, 0, sizeof action);
        action.sa_handler = on_fatal_signal;
        sigemptyset(&action.sa_mask);
        sigaction(fatal[i], &action, NULL);
    }
    const int status = main(argc, argv);
    fflush(stdout);
    fprintf(stderr, "MKW-TVOS-TEST-EXIT=%d\n", status);
    fflush(stderr);
    return status;
}
