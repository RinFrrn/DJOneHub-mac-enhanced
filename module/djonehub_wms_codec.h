#ifndef DJONEHUB_WMS_CODEC_H
#define DJONEHUB_WMS_CODEC_H

#include <stddef.h>
#include <stdint.h>

#define DJONEHUB_WMS_MAX_MESSAGES 128U
#define DJONEHUB_WMS_MAX_PDU_BYTES 512U
#define DJONEHUB_WMS_FORMAT_GW_PP 0x06U

struct djonehub_wms_message_ref {
    uint32_t index;
    uint8_t tag;
};

struct djonehub_wms_raw_message {
    uint8_t tag;
    uint8_t has_tag;
    uint8_t format;
    size_t pdu_length;
    uint8_t pdu[DJONEHUB_WMS_MAX_PDU_BYTES];
};

size_t djonehub_wms_build_list_request(uint8_t storage, uint8_t tag,
                                       uint8_t tag_tlv, int include_mode,
                                       uint8_t *output, size_t capacity);
size_t djonehub_wms_build_read_request(uint8_t storage, uint32_t index,
                                       uint8_t *output, size_t capacity);
size_t djonehub_wms_build_delete_request(uint8_t storage, uint32_t index,
                                         int legacy_layout, uint8_t *output,
                                         size_t capacity);
size_t djonehub_wms_build_send_request(uint8_t format, const uint8_t *pdu,
                                       size_t pdu_length, uint8_t *output,
                                       size_t capacity);

int djonehub_wms_parse_result(const uint8_t *response, size_t length,
                              unsigned int *service_error);
int djonehub_wms_parse_list_response(
    const uint8_t *response, size_t length,
    struct djonehub_wms_message_ref *messages, size_t capacity,
    size_t *message_count, unsigned int *service_error);
int djonehub_wms_parse_read_response(
    const uint8_t *response, size_t length,
    struct djonehub_wms_raw_message *message, unsigned int *service_error);
int djonehub_wms_parse_send_response(const uint8_t *response, size_t length,
                                     uint16_t *message_id,
                                     unsigned int *service_error);
int djonehub_wms_parse_u8_response(const uint8_t *response, size_t length,
                                   uint8_t *value,
                                   unsigned int *service_error);

#endif
