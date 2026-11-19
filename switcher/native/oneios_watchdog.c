// SM8850 experimental watchdog owner. The switch supplies a qualified plan.
// This process owns exactly one file description and never forks or execs.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/watchdog.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>

enum { ACQUIRE_S = 3, HEARTBEAT_MS = 2000, STALE_MS = 5000, MARGIN_S = 15 };
static int control;
static const char *generation;
static pid_t pid;

static int64_t boot_ms(void) {
    struct timespec time;
    if (clock_gettime(CLOCK_BOOTTIME, &time))
        return -1;
    return time.tv_sec * (int64_t)1000 + time.tv_nsec / 1000000;
}

static bool read_generation(void) {
    char buffer[128];
    int fd = openat(control, "watchdog.generation", O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0)
        return false;
    ssize_t size = read(fd, buffer, sizeof buffer);
    close(fd);
    size_t length = strlen(generation);
    return size == (ssize_t)(length + 1) && !memcmp(buffer, generation, length) && buffer[length] == '\n';
}

static bool exists(const char *name) {
    return faccessat(control, name, F_OK, 0) == 0;
}

static bool record(const char *name, const char *format, ...) {
    if (!read_generation())
        return false;
    char temporary[128], data[256];
    snprintf(temporary, sizeof temporary, ".watchdog.%ld.%s", (long)pid, name);
    va_list args;
    va_start(args, format);
    int length = vsnprintf(data, sizeof data, format, args);
    va_end(args);
    if (length < 0 || (size_t)length >= sizeof data)
        return false;
    int fd = openat(control, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0)
        return false;
    bool written = write(fd, data, (size_t)length) == length;
    bool closed = close(fd) == 0;
    bool published = written && closed && read_generation() && renameat(control, temporary, control, name) == 0;
    if (!published)
        unlinkat(control, temporary, 0);
    return published;
}

static bool phase(const char *state) {
    if (!record("watchdog.phase", "%s %s\n", generation, state))
        return false;
    fprintf(stderr, "native watchdog: %s uptime_ms=%" PRId64 "\n", state, boot_ms());
    return true;
}

static int fail(int fd, const char *reason) {
    fprintf(stderr, "native watchdog: %s\n", reason);
    if (read_generation()) {
        // Preserve an earlier failure written by OneOS.
        int error = openat(control, "feeder.failed", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (error >= 0) {
            dprintf(error, "%s\n", reason);
            close(error);
        }
    }
    if (fd >= 0)
        close(fd);
    return 4;
}

static bool decimal(const char *text, long min, long max, long *value) {
    if (!*text || strspn(text, "0123456789") != strlen(text))
        return false;
    errno = 0;
    *value = strtol(text, NULL, 10);
    return !errno && *value >= min && *value <= max;
}

static void pause_poll(void) {
    struct timespec delay = {.tv_nsec = 100000000};
    nanosleep(&delay, NULL);
}

static bool same_target(const struct stat *st, dev_t expected) {
    return S_ISCHR(st->st_mode) && st->st_rdev == expected;
}

static int timeleft(int fd) {
    int remaining;
    return ioctl(fd, WDIOC_GETTIMELEFT, &remaining) == 0 && remaining >= 0 ? remaining : -1;
}

int main(int argc, char **argv) {
    if (argc != 10)
        return 2;
    const char *node = argv[2], *birth = argv[5];
    const char prefix[] = "/dev/watchdog";
    size_t length = sizeof prefix - 1;
    unsigned major_num, minor_num;
    char extra;
    long ignored, arm, nowayout, timeout, reacquire;
    generation = argv[4];
    if (strncmp(node, prefix, length) || !decimal(node + length, 0, 4095, &ignored) ||
        sscanf(argv[3], "%x:%x%c", &major_num, &minor_num, &extra) != 2 ||
        major_num > 4095 || minor_num > 1048575 || !*generation || strlen(generation) > 80 ||
        strspn(generation, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-") != strlen(generation) ||
        !*birth || strspn(birth, "0123456789") != strlen(birth) ||
        !decimal(argv[6], 0, 999999999, &arm) || !decimal(argv[7], 0, 1, &nowayout) ||
        !decimal(argv[8], 100, 65535, &timeout) || !decimal(argv[9], 5, 30, &reacquire))
        return 2;
    pid = getpid();
    control = open(argv[1], O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (control < 0 || !read_generation() || exists("feeder.off") || exists("feeder.failed"))
        return 2;
    dev_t expected = makedev(major_num, minor_num);
    int fd = -1;
    int64_t acquire_by = (arm + (int64_t)ACQUIRE_S) * 1000;
    if (!phase("TRANSFER_PENDING"))
        return fail(fd, "cannot record transfer");
    for (;;) {
        int64_t now = boot_ms();
        if (now < arm * (int64_t)1000 || now >= acquire_by)
            return fail(fd, "EBUSY or acquisition deadline expired");
        if (!read_generation() || exists("feeder.off") || exists("feeder.failed"))
            return fail(fd, "transfer cancelled");
        struct stat before;
        if (lstat(node, &before) || !same_target(&before, expected))
            return fail(fd, "watchdog service unavailable or device identity changed");
        fd = open(node, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
        if (fd >= 0)
            break;
        if (errno != EBUSY)
            return fail(fd, "watchdog open failed");
        pause_poll();
    }
    struct stat opened;
    struct watchdog_info info = {0};
    int actual_timeout, pretimeout;
    if (fstat(fd, &opened) || !same_target(&opened, expected) ||
        ioctl(fd, WDIOC_GETSUPPORT, &info) ||
        strncmp((char *)info.identity, "Software Watchdog", sizeof info.identity) ||
        !(info.options & WDIOF_KEEPALIVEPING) || (!nowayout && !(info.options & WDIOF_MAGICCLOSE)) ||
        ioctl(fd, WDIOC_GETTIMEOUT, &actual_timeout) || actual_timeout != timeout ||
        ioctl(fd, WDIOC_GETPRETIMEOUT, &pretimeout) || pretimeout || timeleft(fd) < 0)
        return fail(fd, "acquired watchdog does not match qualified capabilities or timeout");
    fprintf(stderr, "native watchdog: opened %s, options=0x%x firmware=%u timeout=%d pretimeout=%d qualified-nowayout=%ld\n",
            node, info.options, info.firmware_version, actual_timeout, pretimeout, nowayout);
    int64_t last = -1;
    for (;;) {
        int64_t tick = boot_ms();
        if (!read_generation() || exists("feeder.failed"))
            return fail(fd, "ownership revoked");
        if (tick < 0 || (last < 0 ? tick >= acquire_by : tick - last >= STALE_MS))
            return fail(fd, "heartbeat deadline expired");
        if (exists("feeder.off"))
            break;
        if (last < 0 || tick - last >= HEARTBEAT_MS) {
            if (write(fd, ".", 1) != 1)
                return fail(fd, "heartbeat write failed");
            tick = boot_ms();
            if (tick < 0 || (last < 0 ? tick >= acquire_by : tick - last >= STALE_MS) ||
                exists("feeder.failed") || exists("feeder.off"))
                return fail(fd, "late heartbeat or transfer cancelled");
            if (!record("feeder.heartbeat", "%s %ld %s %" PRId64 "\n", generation, (long)pid, birth, tick / 1000) ||
                (last < 0 && (!phase("SUPERVISOR_OWNS") || !record("feeder.ready", "%ld\n", (long)pid))))
                return fail(fd, "cannot publish heartbeat");
            last = tick;
        }
        pause_poll();
    }
    if (last < 0 || !phase("RETURN_PENDING"))
        return fail(fd, "handback requested before ownership was established");

    // Any final write can hang. The independent return guard already has its
    // deadline, and a failed handback must never become a release receipt.
    if (timeleft(fd) < reacquire + MARGIN_S)
        return fail(fd, "handback lacks audited time remaining");
    if (write(fd, nowayout ? "." : "V", 1) != 1) {
        if (!nowayout)
            (void)write(fd, ".", 1); // Clear a magic-close bit set before a failed ping.
        return fail(fd, "final handback write failed");
    }
    int64_t close_started = boot_ms();
    if (close(fd) || close_started < 0)
        return fail(-1, "watchdog descriptor close failed");
    if (!record("feeder.released", "%s %ld %s %ld %" PRId64 "\n",
                generation, (long)pid, birth, nowayout, close_started / 1000))
        return fail(-1, "could not certify closed watchdog descriptor");
    fprintf(stderr, "native watchdog: close returned uptime_ms=%" PRId64 "\n", boot_ms());
    return 0;
}
