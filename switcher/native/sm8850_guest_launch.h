/* SPDX-License-Identifier: MIT */
#ifndef ONEIOS_SM8850_GUEST_LAUNCH_H
#define ONEIOS_SM8850_GUEST_LAUNCH_H
#include "sm8850_owned_groups.h"

/* Root session bootstrap only. No Android admission, namespace setup,
 * runtime-ready receipt or authority to launch a legacy full run.
 * Call from a trusted single-threaded parent, before starting HAL/readers.
 * Retain exclusive waitpid ownership; SIGCHLD must have default disposition
 * and no SA_NOCLDWAIT until bootstrap has ended.
 * Children enter both fresh private leaves BEFORE exec. The owner,
 * sampler, recovery and watchdog stay outside. Never adopt existing PIDs.
 * Initialize with {0}; no reuse after any failure or close. */
enum oneios_guest_role { ONEIOS_GUEST_XNUHOST, ONEIOS_GUEST_DISPLAY, ONEIOS_GUEST_ROOTS };
enum oneios_guest_launch_phase {
    ONEIOS_LAUNCH_NEW, ONEIOS_LAUNCH_HELD, ONEIOS_LAUNCH_RELEASED,
    ONEIOS_LAUNCH_FAULT, ONEIOS_LAUNCH_CLOSED
};
#define ONEIOS_LAUNCH_PASS_FDS 8u
struct oneios_guest_child {
    pid_t pid;                 /* retained for the parent's explicit waitpid */
    int pidfd, gate;
    bool released;
};
struct oneios_guest_launch {
    struct oneios_owned_groups *groups;
    pid_t owner_pid;
    struct oneios_guest_child root[ONEIOS_GUEST_ROOTS];
    enum oneios_guest_launch_phase phase;
};
int oneios_guest_launch_init(struct oneios_guest_launch *, struct oneios_owned_groups *);
/* The sole owner supplies already checked absolute executable paths,
 * argv/envp and a whitelist of inherited control FDs. All other FDs >=3
 * are closed in the child before it acknowledges the barrier.
 * Failure can leave a child in a partially joined private group; retain
 * its PID for explicit retirement. Never signal an unrelated PID. */
int oneios_guest_launch_hold(struct oneios_guest_launch *, enum oneios_guest_role,
    const char *path, char *const argv[], char *const envp[],
    const int *pass_fds, unsigned nfds);
/* Both distinct direct children must be alive and exactly the complete
 * contents of BOTH leaves before release. This is a bootstrap release,
 * NOT thermal/full-run admission. The outer owner must enforce startup
 * protection and runtime-ready proof separately. Partial release is fault. */
int oneios_guest_launch_release(struct oneios_guest_launch *);
/* Check pinned roots and exact equality of current CPU/freezer PID sets.
 * In a running guest these sets can change; -1/EAGAIN means inconsistent
 * snapshots, not a proof of escape. This alone cannot prove that no
 * descendant has escaped both groups or that all producers are parked. */
int oneios_guest_launch_check_roots(struct oneios_guest_launch *);
/* Close the private gates and pidfds only. No thaw, migration, signals,
 * implicit waitpid, group deletion, or Android return. PIDs are retained. */
void oneios_guest_launch_close(struct oneios_guest_launch *);
#endif
