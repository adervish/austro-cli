#ifndef AUSTRO_CSOCKETCAN_H
#define AUSTRO_CSOCKETCAN_H

#include <stdint.h>

/* Thin wrapper over Linux SocketCAN (AF_CAN/RAW) so the Swift layer stays portable.
 * All functions are no-ops returning -1 on non-Linux so the package still compiles there. */

/* Open a bound RAW CAN socket on interface `ifname` (e.g. "can0"). Returns fd, or -1. */
int austro_scan_open(const char *ifname);

/* Send one classic CAN data frame (<= 8 bytes). Returns 0 on success, -1 on error. */
int austro_scan_send(int fd, uint32_t id, const uint8_t *data, uint8_t len);

/* Receive one classic CAN data frame, waiting up to `timeout_ms`.
 * Returns 1 if a frame was read (fills id/data/len), 0 on timeout, -1 on error. */
int austro_scan_recv(int fd, uint32_t *id, uint8_t *data, uint8_t *len, int timeout_ms);

void austro_scan_close(int fd);

#endif
