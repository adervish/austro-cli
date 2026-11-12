/* Implementation of pcbusb_shim.h — see that header. macOS only. */
#include "pcbusb_shim.h"
#include "PCBUSB.h"
#include <string.h>
#include <stdio.h>

uint32_t austro_pcan_open(uint16_t channel, uint16_t baud, int listen_only) {
    TPCANStatus st = CAN_Initialize((TPCANHandle)channel, (TPCANBaudrate)baud, 0, 0, 0);
    if (st != PCAN_ERROR_OK) return (uint32_t)st;
    if (listen_only) {
        DWORD on = PCAN_PARAMETER_ON;
        TPCANStatus ls = CAN_SetValue((TPCANHandle)channel, PCAN_LISTEN_ONLY, &on, sizeof on);
        if (ls != PCAN_ERROR_OK) {
            /* Must not silently stay in normal mode — caller believes it's passive. */
            CAN_Uninitialize((TPCANHandle)channel);
            return (uint32_t)ls;
        }
    }
    return (uint32_t)PCAN_ERROR_OK;
}

uint32_t austro_pcan_close(uint16_t channel) {
    return (uint32_t)CAN_Uninitialize((TPCANHandle)channel);
}

uint32_t austro_pcan_condition(uint16_t channel, uint32_t *cond_out) {
    DWORD c = 0;
    TPCANStatus st = CAN_GetValue((TPCANHandle)channel, PCAN_CHANNEL_CONDITION, &c, sizeof c);
    if (cond_out) *cond_out = (uint32_t)c;
    return (uint32_t)st;
}

uint32_t austro_pcan_read(uint16_t channel,
                          uint32_t *id_out, uint8_t *type_out, uint8_t *len_out,
                          uint8_t *data_out, uint32_t *millis_out, uint16_t *micros_out) {
    TPCANMsg m;
    TPCANTimestamp ts;
    memset(&m, 0, sizeof m);
    memset(&ts, 0, sizeof ts);
    TPCANStatus st = CAN_Read((TPCANHandle)channel, &m, &ts);
    if (st == PCAN_ERROR_OK) {
        if (id_out) *id_out = (uint32_t)m.ID;
        if (type_out) *type_out = (uint8_t)m.MSGTYPE;
        if (len_out) *len_out = (uint8_t)m.LEN;
        if (data_out) memcpy(data_out, m.DATA, 8);
        if (millis_out) *millis_out = (uint32_t)ts.millis;
        if (micros_out) *micros_out = (uint16_t)ts.micros;
    }
    return (uint32_t)st;
}

uint32_t austro_pcan_get_string(uint16_t channel, uint8_t param, char *buf, uint32_t buflen) {
    if (buf && buflen) buf[0] = '\0';
    return (uint32_t)CAN_GetValue((TPCANHandle)channel, (TPCANParameter)param, buf, buflen);
}

uint32_t austro_pcan_get_u32(uint16_t channel, uint8_t param, uint32_t *out) {
    DWORD v = 0;
    TPCANStatus st = CAN_GetValue((TPCANHandle)channel, (TPCANParameter)param, &v, sizeof v);
    if (out) *out = (uint32_t)v;
    return (uint32_t)st;
}

uint32_t austro_pcan_write(uint16_t channel, uint32_t id, uint8_t len, const uint8_t *data) {
    TPCANMsg m;
    memset(&m, 0, sizeof m);
    m.ID = (DWORD)id;
    m.MSGTYPE = PCAN_MESSAGE_STANDARD;
    m.LEN = len > 8 ? 8 : len;
    if (data) for (int i = 0; i < m.LEN; i++) m.DATA[i] = data[i];
    return (uint32_t)CAN_Write((TPCANHandle)channel, &m);
}

void austro_pcan_errtext(uint32_t status, char *buf, uint32_t buflen) {
    if (!buf || !buflen) return;
    buf[0] = '\0';
    char tmp[256];
    tmp[0] = '\0';
    if (CAN_GetErrorText((TPCANStatus)status, 0x09 /* English */, tmp) != PCAN_ERROR_OK || tmp[0] == '\0')
        snprintf(buf, buflen, "status 0x%X", (unsigned)status);
    else
        snprintf(buf, buflen, "%s (0x%X)", tmp, (unsigned)status);
}
