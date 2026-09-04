#include "djonehub_wms_codec.h"

#include <stdio.h>
#include <string.h>

#define CHECK(value)                                                         \
    do {                                                                     \
        if (!(value)) {                                                      \
            fprintf(stderr, "check failed at line %d: %s\n", __LINE__,      \
                    #value);                                                 \
            return 1;                                                        \
        }                                                                    \
    } while (0)

int main(void)
{
    uint8_t buffer[1024];
    uint8_t response[128];
    const uint8_t pdu[] = {0x00U, 0x11U, 0x22U};
    struct djonehub_wms_message_ref messages[2];
    struct djonehub_wms_raw_message message;
    unsigned int service_error;
    uint16_t message_id;
    uint8_t value;
    size_t length;
    size_t count;

    length = djonehub_wms_build_list_request(1U, 1U, 0x11U, 1, buffer,
                                              sizeof(buffer));
    CHECK(length == 12U);
    CHECK(memcmp(buffer, "\x01\x01\x00\x01\x11\x01\x00\x01"
                         "\x12\x01\x00\x01", 12U) == 0);

    length = djonehub_wms_build_list_all_request(0U, 0, buffer,
                                                  sizeof(buffer));
    CHECK(length == 4U);
    CHECK(memcmp(buffer, "\x01\x01\x00\x00", 4U) == 0);
    length = djonehub_wms_build_list_all_request(1U, 1, buffer,
                                                  sizeof(buffer));
    CHECK(length == 8U);
    CHECK(memcmp(buffer, "\x01\x01\x00\x01\x12\x01\x00\x01",
                 8U) == 0);

    length = djonehub_wms_build_read_request(0U, 0x78563412U, buffer,
                                              sizeof(buffer));
    CHECK(length == 12U);
    CHECK(buffer[3] == 0U && buffer[4] == 0x12U && buffer[7] == 0x78U);

    length = djonehub_wms_build_delete_request(1U, 9U, 0, buffer,
                                                sizeof(buffer));
    CHECK(length == 15U && buffer[4] == 0x10U && buffer[11] == 0x12U);
    length = djonehub_wms_build_delete_request(1U, 9U, 1, buffer,
                                                sizeof(buffer));
    CHECK(length == 15U && buffer[4] == 0x02U && buffer[11] == 0x04U);

    length = djonehub_wms_build_send_request(0x06U, pdu, sizeof(pdu), buffer,
                                              sizeof(buffer));
    CHECK(length == 9U);
    CHECK(memcmp(buffer, "\x01\x06\x00\x06\x03\x00\x00\x11\x22",
                 9U) == 0);

    /* result=success plus message list containing two entries */
    memcpy(response, "\x02\x04\x00\x00\x00\x00\x00"
                     "\x01\x0e\x00\x02\x00\x00\x00"
                     "\x07\x00\x00\x00\x01"
                     "\x09\x00\x00\x00\x00", 24U);
    CHECK(djonehub_wms_parse_list_response(
              response, 24U, messages, 2U, &count, &service_error) == 0);
    CHECK(count == 2U && messages[0].index == 7U && messages[0].tag == 1U);
    CHECK(messages[1].index == 9U && messages[1].tag == 0U);

    memcpy(response, "\x02\x04\x00\x00\x00\x00\x00"
                     "\x01\x07\x00\x01\x06\x03\x00\x00\x11\x22",
           17U);
    CHECK(djonehub_wms_parse_read_response(response, 17U, &message,
                                            &service_error) == 0);
    CHECK(message.has_tag == 1U && message.tag == 1U &&
          message.format == 0x06U && message.pdu_length == 3U &&
          memcmp(message.pdu, pdu, sizeof(pdu)) == 0);

    memcpy(response, "\x02\x04\x00\x00\x00\x00\x00"
                     "\x01\x02\x00\x34\x12", 12U);
    CHECK(djonehub_wms_parse_send_response(response, 12U, &message_id,
                                            &service_error) == 0);
    CHECK(message_id == 0x1234U);

    memcpy(response, "\x02\x04\x00\x00\x00\x00\x00"
                     "\x01\x01\x00\x04", 11U);
    CHECK(djonehub_wms_parse_u8_response(response, 11U, &value,
                                         &service_error) == 0);
    CHECK(value == 4U);

    memcpy(response, "\x02\x04\x00\x01\x00\x2a\x00", 7U);
    CHECK(djonehub_wms_parse_result(response, 7U, &service_error) == 1);
    CHECK(service_error == 42U);

    puts("djonehub_wms_codec_test: ok");
    return 0;
}
