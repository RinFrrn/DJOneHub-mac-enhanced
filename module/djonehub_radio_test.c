/* Host test: include the engine to exercise its private NAS TLV parser. */
#include "djonehub_qmi_voice_engine.c"
#include "djonehub_control_protocol.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    uint8_t tlv[] = {2,4,0,0,0,0,0,1,2,0,200,8};
    struct djonehub_radio_status radio;
    uint8_t key[32] = {0}, nonce[32] = {0}, frame[DJONEHUB_CONTROL_MAX_FRAME_BYTES];
    struct djonehub_control_result input = {0}, output;
    enum djonehub_control_status status;
    uint64_t request_id;
    size_t length, i;
    assert(radio_parse(tlv, sizeof(tlv), &radio) == 0);
    assert(radio.valid && radio.dbm == -56 && radio.technology == 8);
    for(i=0;i<sizeof(tlv);i++) assert(radio_parse(tlv,i,&radio) != 0);
    tlv[3]=1; assert(radio_parse(tlv,sizeof(tlv),&radio) != 0); tlv[3]=0;
    tlv[10]=0; assert(radio_parse(tlv,sizeof(tlv),&radio) != 0); tlv[10]=200;
    tlv[11]=0; assert(radio_parse(tlv,sizeof(tlv),&radio) != 0); tlv[11]=8;
    assert(radio_parse(tlv,sizeof(tlv),&radio) == 0);
    input.operation=DJONEHUB_VOICE_STATUS;
    input.snapshot.radio=radio;
    input.snapshot.internet_state=1;
    length=djonehub_control_encode_response(key,nonce,DJONEHUB_CONTROL_OK,1,&input,frame,sizeof(frame));
    assert(length>0);
    assert(djonehub_control_decode_response(key,nonce,frame,length,&status,&request_id,&output)==0);
    assert(output.snapshot.radio.valid && output.snapshot.radio.dbm == -56 && output.snapshot.radio.technology == 8);
    assert(output.snapshot.internet_state == 1);
    puts("Radio TLV parsing and authenticated round trip: PASS");
    return 0;
}
