/*
 * xcesp-ip.c — minimal privileged wrapper around /usr/bin/ip.
 *
 * Purpose:
 *   xcesp-dhclient-script (the callback xcespproc passes to dhclient via -sf)
 *   needs to run `ip addr add` etc. inside the netns dhclient was launched
 *   in.  But on Debian/Fedora, ISC dhclient drops privileges before invoking
 *   the script — the script runs as the xcesp uid with empty pE.  Even with
 *   file caps on `/usr/bin/ip`, the cap propagation chain is fragile:
 *     - `=ep` works but expands ANY user's privileges host-wide;
 *     - `=ei` only works if pI is preserved (Fedora's dhclient drops it).
 *
 *   This wrapper sidesteps both: it carries `cap_net_admin,cap_net_raw=ep`
 *   (applied by xcesp-activate on install), runs anywhere the script needs
 *   to, and re-execs `/usr/bin/ip` with ambient caps raised so ip inherits
 *   net_admin/net_raw through the exec.  /usr/bin/ip stays untouched, so
 *   normal users on the box don't gain any privileges — only the script
 *   path that exec's this wrapper benefits.
 *
 * Build:
 *   gcc -O2 -Wall -o xcesp-ip xcesp-ip.c
 *
 * Install:
 *   /usr/lib/xcesp/xcesp-ip  with cap_net_admin,cap_net_raw+ep
 *   (xcesp-activate applies the caps non-destructively).
 */

#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

/* Avoid pulling in <sys/capability.h> (libcap-dev) — declare what we need. */
#ifndef PR_CAP_AMBIENT
#  define PR_CAP_AMBIENT          47
#  define PR_CAP_AMBIENT_RAISE     2
#endif
#ifndef CAP_NET_ADMIN
#  define CAP_NET_ADMIN          12
#endif
#ifndef CAP_NET_RAW
#  define CAP_NET_RAW            13
#endif

#define _LINUX_CAPABILITY_VERSION_3 0x20080522

struct cap_header { unsigned int version; int pid; };
struct cap_data   { unsigned int effective, permitted, inheritable; };

static const char *IP_PATHS[] = {
    "/usr/bin/ip",
    "/usr/sbin/ip",
    "/sbin/ip",
    "/bin/ip",
    NULL,
};

int main(int argc, char **argv) {
    (void)argc;

    /* Promote pP into pI so the kernel will accept PR_CAP_AMBIENT_RAISE
     * (which requires the cap to be in both pP and pI). */
    struct cap_header hdr = { _LINUX_CAPABILITY_VERSION_3, 0 };
    struct cap_data   dat[2] = {{0,0,0},{0,0,0}};
    if (syscall(SYS_capget, &hdr, dat) == 0) {
        dat[0].inheritable |= dat[0].permitted;
        dat[1].inheritable |= dat[1].permitted;
        (void)syscall(SYS_capset, &hdr, dat);
    }

    /* Raise the two caps `ip addr add/del/flush` need.  /usr/bin/ip has no
     * file caps on most distros, so ambient is how it gets the privilege:
     *   ip.pP = (X & 0) | (pI & 0) | pA = pA
     *   ip.pE = fE ? pP : pA = pA          (fE=0 means pE=pA)
     */
    (void)prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_RAISE, CAP_NET_ADMIN, 0, 0);
    (void)prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_RAISE, CAP_NET_RAW,   0, 0);

    /* Exec /usr/bin/ip with the original args.  Present argv[0] as "ip" so
     * ip's own usage/error messages don't reveal our wrapper path. */
    char *orig0 = argv[0];
    argv[0] = (char *)"ip";
    for (int i = 0; IP_PATHS[i]; i++) {
        execv(IP_PATHS[i], argv);   /* succeeds → never returns */
    }

    argv[0] = orig0;
    fprintf(stderr, "xcesp-ip: cannot exec /usr/bin/ip: %s\n", strerror(errno));
    return 127;
}
