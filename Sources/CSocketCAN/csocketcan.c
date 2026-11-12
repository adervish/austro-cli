#include "csocketcan.h"

#ifdef __linux__

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <poll.h>
#include <linux/can.h>
#include <linux/can/raw.h>

int austro_scan_open(const char *ifname) {
    int s = socket(PF_CAN, SOCK_RAW, CAN_RAW);
    if (s < 0) return -1;

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(s, SIOCGIFINDEX, &ifr) < 0) { close(s); return -1; }

    struct sockaddr_can addr;
    memset(&addr, 0, sizeof(addr));
    addr.can_family = AF_CAN;
    addr.can_ifindex = ifr.ifr_ifindex;
    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(s); return -1; }
    return s;
}

int austro_scan_send(int fd, uint32_t id, const uint8_t *data, uint8_t len) {
    if (len > 8) len = 8;
    struct can_frame frame;
    memset(&frame, 0, sizeof(frame));
    frame.can_id = id;               /* 11-bit standard id */
    frame.can_dlc = len;
    memcpy(frame.data, data, len);
    ssize_t n = write(fd, &frame, sizeof(frame));
    return (n == (ssize_t)sizeof(frame)) ? 0 : -1;
}

int austro_scan_recv(int fd, uint32_t *id, uint8_t *data, uint8_t *len, int timeout_ms) {
    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = POLLIN;
    int pr = poll(&pfd, 1, timeout_ms);
    if (pr == 0) return 0;           /* timeout */
    if (pr < 0) return -1;

    struct can_frame frame;
    ssize_t n = read(fd, &frame, sizeof(frame));
    if (n < (ssize_t)sizeof(frame)) return -1;
    /* Ignore error/RTR frames; report only classic data frames. */
    if (frame.can_id & (CAN_ERR_FLAG | CAN_RTR_FLAG)) return 0;

    *id = frame.can_id & CAN_SFF_MASK;
    uint8_t dlc = frame.can_dlc > 8 ? 8 : frame.can_dlc;
    *len = dlc;
    memcpy(data, frame.data, dlc);
    return 1;
}

void austro_scan_close(int fd) {
    if (fd >= 0) close(fd);
}

#else  /* non-Linux: stubs so the package still builds (never linked into a product there) */

int austro_scan_open(const char *ifname) { (void)ifname; return -1; }
int austro_scan_send(int fd, uint32_t id, const uint8_t *data, uint8_t len) {
    (void)fd; (void)id; (void)data; (void)len; return -1;
}
int austro_scan_recv(int fd, uint32_t *id, uint8_t *data, uint8_t *len, int timeout_ms) {
    (void)fd; (void)id; (void)data; (void)len; (void)timeout_ms; return -1;
}
void austro_scan_close(int fd) { (void)fd; }

#endif
