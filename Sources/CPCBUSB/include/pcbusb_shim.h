/*
 * pcbusb_shim.h — thin fixed-width C wrapper over the MacCAN/PCBUSB API.
 *
 * Exposes the few PCAN-Basic calls the Austro reader needs using plain
 * stdint types, so Swift can call them without importing PEAK's WORD/DWORD
 * macros and TPCAN* typedefs. All functions return a TPCANStatus code
 * (0 == OK, 0x20 == receive queue empty). macOS only.
 */
#ifndef AUSTRO_PCBUSB_SHIM_H
#define AUSTRO_PCBUSB_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Open channel `channel` at BTR0BTR1 code `baud`; enable listen-only if set. */
uint32_t austro_pcan_open(uint16_t channel, uint16_t baud, int listen_only);

/* Uninitialize the channel. */
uint32_t austro_pcan_close(uint16_t channel);

/* Pre-init availability query: *cond_out bit0 = available, bit1 = occupied. */
uint32_t austro_pcan_condition(uint16_t channel, uint32_t *cond_out);

/* Read one frame. On OK, fills outputs.
 * type_out bits: 0=RTR, 1=EXTENDED, 6=ERRFRAME, 7=STATUS. data_out is 8 bytes. */
uint32_t austro_pcan_read(uint16_t channel,
                          uint32_t *id_out, uint8_t *type_out, uint8_t *len_out,
                          uint8_t *data_out /* [8] */,
                          uint32_t *millis_out, uint16_t *micros_out);

/* Read a string parameter (e.g. hardware name, firmware, part number). */
uint32_t austro_pcan_get_string(uint16_t channel, uint8_t param, char *buf, uint32_t buflen);

/* Read a 32-bit parameter (e.g. controller number). */
uint32_t austro_pcan_get_u32(uint16_t channel, uint8_t param, uint32_t *out);

/* Transmit one standard CAN frame (msgtype 0 = standard data). data is `len` bytes. */
uint32_t austro_pcan_write(uint16_t channel, uint32_t id, uint8_t len, const uint8_t *data);

/* Human-readable English text for a status code (buf should be >= 256 bytes). */
void austro_pcan_errtext(uint32_t status, char *buf, uint32_t buflen);

#ifdef __cplusplus
}
#endif

#endif /* AUSTRO_PCBUSB_SHIM_H */
