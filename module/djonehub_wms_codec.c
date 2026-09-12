#include "djonehub_wms_codec.h"

#include <string.h>

static void store_le16(uint8_t *output, uint16_t value)
{
    output[0] = (uint8_t)value;
    output[1] = (uint8_t)(value >> 8U);
}

static uint16_t load_le16(const uint8_t *input)
{
    return (uint16_t)((uint16_t)input[0] | ((uint16_t)input[1] << 8U));
}

static void store_le32(uint8_t *output, uint32_t value)
{
    output[0] = (uint8_t)value;
    output[1] = (uint8_t)(value >> 8U);
    output[2] = (uint8_t)(value >> 16U);
    output[3] = (uint8_t)(value >> 24U);
}

static uint32_t load_le32(const uint8_t *input)
{
    return (uint32_t)input[0] | ((uint32_t)input[1] << 8U) |
           ((uint32_t)input[2] << 16U) | ((uint32_t)input[3] << 24U);
}

static size_t append_tlv(uint8_t type, const uint8_t *value,
                         size_t value_length, uint8_t *output,
                         size_t capacity, size_t offset)
{
    if (value_length > UINT16_MAX || offset > capacity ||
        capacity - offset < 3U + value_length) {
        return SIZE_MAX;
    }
    output[offset] = type;
    store_le16(output + offset + 1U, (uint16_t)value_length);
    if (value_length != 0U) {
        memcpy(output + offset + 3U, value, value_length);
    }
    return offset + 3U + value_length;
}

static int find_tlv(const uint8_t *data, size_t length, uint8_t wanted,
                    const uint8_t **value, size_t *value_length)
{
    size_t offset = 0U;

    while (offset < length) {
        size_t current_length;

        if (length - offset < 3U) {
            return -1;
        }
        current_length = load_le16(data + offset + 1U);
        if (current_length > length - offset - 3U) {
            return -1;
        }
        if (data[offset] == wanted) {
            *value = data + offset + 3U;
            *value_length = current_length;
            return 1;
        }
        offset += 3U + current_length;
    }
    return 0;
}

size_t djonehub_wms_build_list_request(uint8_t storage, uint8_t tag,
                                       uint8_t tag_tlv, int include_mode,
                                       uint8_t *output, size_t capacity)
{
    const uint8_t mode = 1U;
    size_t offset;

    if (output == NULL || storage > 1U || tag > 3U ||
        (tag_tlv != 0x11U && tag_tlv != 0x02U)) {
        return 0U;
    }
    offset = append_tlv(0x01U, &storage, 1U, output, capacity, 0U);
    if (offset == SIZE_MAX) {
        return 0U;
    }
    offset = append_tlv(tag_tlv, &tag, 1U, output, capacity, offset);
    if (offset == SIZE_MAX) {
        return 0U;
    }
    if (include_mode != 0) {
        offset = append_tlv(0x12U, &mode, 1U, output, capacity, offset);
    }
    return offset == SIZE_MAX ? 0U : offset;
}

size_t djonehub_wms_build_list_all_request(uint8_t storage, int include_mode,
                                           uint8_t *output, size_t capacity)
{
    const uint8_t mode = 1U;
    size_t offset;

    if (output == NULL || storage > 1U) {
        return 0U;
    }
    offset = append_tlv(0x01U, &storage, 1U, output, capacity, 0U);
    if (offset == SIZE_MAX) {
        return 0U;
    }
    if (include_mode != 0) {
        offset = append_tlv(0x12U, &mode, 1U, output, capacity, offset);
    }
    return offset == SIZE_MAX ? 0U : offset;
}

size_t djonehub_wms_build_read_request(uint8_t storage, uint32_t index,
                                       uint8_t *output, size_t capacity)
{
    uint8_t info[5];
    const uint8_t mode = 1U;
    size_t offset;

    if (output == NULL || storage > 1U) {
        return 0U;
    }
    info[0] = storage;
    store_le32(info + 1U, index);
    offset = append_tlv(0x01U, info, sizeof(info), output, capacity, 0U);
    if (offset == SIZE_MAX) {
        return 0U;
    }
    offset = append_tlv(0x10U, &mode, 1U, output, capacity, offset);
    return offset == SIZE_MAX ? 0U : offset;
}

size_t djonehub_wms_build_delete_request(uint8_t storage, uint32_t index,
                                         int legacy_layout, uint8_t *output,
                                         size_t capacity)
{
    uint8_t encoded_index[4];
    const uint8_t mode = 1U;
    uint8_t index_type = legacy_layout != 0 ? 0x02U : 0x10U;
    uint8_t mode_type = legacy_layout != 0 ? 0x04U : 0x12U;
    size_t offset;

    if (output == NULL || storage > 1U) {
        return 0U;
    }
    store_le32(encoded_index, index);
    offset = append_tlv(0x01U, &storage, 1U, output, capacity, 0U);
    if (offset != SIZE_MAX) {
        offset = append_tlv(index_type, encoded_index, sizeof(encoded_index),
                            output, capacity, offset);
    }
    if (offset != SIZE_MAX) {
        offset = append_tlv(mode_type, &mode, 1U, output, capacity, offset);
    }
    return offset == SIZE_MAX ? 0U : offset;
}

size_t djonehub_wms_build_send_request(uint8_t format, const uint8_t *pdu,
                                       size_t pdu_length, uint8_t *output,
                                       size_t capacity)
{
    uint8_t value[3U + DJONEHUB_WMS_MAX_PDU_BYTES];
    size_t result;

    if (format != DJONEHUB_WMS_FORMAT_GW_PP || pdu == NULL ||
        pdu_length == 0U || pdu_length > DJONEHUB_WMS_MAX_PDU_BYTES ||
        output == NULL) {
        return 0U;
    }
    value[0] = format;
    store_le16(value + 1U, (uint16_t)pdu_length);
    memcpy(value + 3U, pdu, pdu_length);
    result = append_tlv(0x01U, value, 3U + pdu_length, output, capacity, 0U);
    memset(value, 0, sizeof(value));
    return result == SIZE_MAX ? 0U : result;
}

int djonehub_wms_parse_result(const uint8_t *response, size_t length,
                              unsigned int *service_error)
{
    const uint8_t *value = NULL;
    size_t value_length = 0U;
    int found;

    if (response == NULL || service_error == NULL) {
        return -1;
    }
    *service_error = 0U;
    found = find_tlv(response, length, 0x02U, &value, &value_length);
    if (found != 1 || value_length != 4U) {
        return -1;
    }
    *service_error = load_le16(value + 2U);
    return load_le16(value) == 0U ? 0 : 1;
}

int djonehub_wms_parse_list_response(
    const uint8_t *response, size_t length,
    struct djonehub_wms_message_ref *messages, size_t capacity,
    size_t *message_count, unsigned int *service_error)
{
    const uint8_t *value = NULL;
    size_t value_length = 0U;
    uint32_t count;
    size_t index;
    int result;

    if (messages == NULL || message_count == NULL) {
        return -1;
    }
    *message_count = 0U;
    result = djonehub_wms_parse_result(response, length, service_error);
    if (result != 0) {
        return result;
    }
    result = find_tlv(response, length, 0x01U, &value, &value_length);
    if (result == 0) {
        return 0;
    }
    if (result < 0 || value_length < 4U) {
        return -1;
    }
    count = load_le32(value);
    if ((size_t)count > (value_length - 4U) / 5U ||
        (size_t)count > capacity) {
        return -2;
    }
    for (index = 0U; index < (size_t)count; ++index) {
        messages[index].index = load_le32(value + 4U + index * 5U);
        messages[index].tag = value[8U + index * 5U];
        if (messages[index].tag > 3U) {
            return -1;
        }
    }
    *message_count = count;
    return 0;
}

int djonehub_wms_parse_read_response(
    const uint8_t *response, size_t length,
    struct djonehub_wms_raw_message *message, unsigned int *service_error)
{
    const uint8_t *value = NULL;
    size_t value_length = 0U;
    size_t header_length;
    uint16_t pdu_length;
    int result;

    if (message == NULL) {
        return -1;
    }
    memset(message, 0, sizeof(*message));
    result = djonehub_wms_parse_result(response, length, service_error);
    if (result != 0) {
        return result;
    }
    result = find_tlv(response, length, 0x01U, &value, &value_length);
    if (result != 1 || value_length < 3U) {
        return -1;
    }
    pdu_length = load_le16(value + 1U);
    if ((size_t)pdu_length <= value_length - 3U) {
        message->format = value[0];
        header_length = 3U;
    } else if (value_length >= 4U && value[0] <= 3U) {
        pdu_length = load_le16(value + 2U);
        if ((size_t)pdu_length > value_length - 4U) {
            return -1;
        }
        message->tag = value[0];
        message->has_tag = 1U;
        message->format = value[1];
        header_length = 4U;
    } else {
        return -1;
    }
    if (pdu_length == 0U || pdu_length > DJONEHUB_WMS_MAX_PDU_BYTES) {
        return -2;
    }
    message->pdu_length = pdu_length;
    memcpy(message->pdu, value + header_length, pdu_length);
    return 0;
}

int djonehub_wms_parse_send_response(const uint8_t *response, size_t length,
                                     uint16_t *message_id,
                                     unsigned int *service_error)
{
    const uint8_t *value = NULL;
    size_t value_length = 0U;
    int result;

    if (message_id == NULL) {
        return -1;
    }
    *message_id = 0U;
    result = djonehub_wms_parse_result(response, length, service_error);
    if (result != 0) {
        return result;
    }
    result = find_tlv(response, length, 0x01U, &value, &value_length);
    if (result == 1 && value_length >= 2U) {
        *message_id = load_le16(value);
    } else if (result < 0) {
        return -1;
    }
    return 0;
}

int djonehub_wms_parse_u8_response(const uint8_t *response, size_t length,
                                   uint8_t *value,
                                   unsigned int *service_error)
{
    const uint8_t *tlv_value = NULL;
    size_t value_length = 0U;
    int result;

    if (value == NULL) {
        return -1;
    }
    result = djonehub_wms_parse_result(response, length, service_error);
    if (result != 0) {
        return result;
    }
    result = find_tlv(response, length, 0x01U, &tlv_value, &value_length);
    if (result != 1 || value_length < 1U) {
        return -1;
    }
    *value = tlv_value[0];
    return 0;
}
