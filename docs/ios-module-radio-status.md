# iOS module radio status

The voice daemon queries QMI NAS `Get Signal Strength` (0x0020) on a separate
client/worker every 10 seconds. It reads the signed RSSI and radio interface
from TLV 0x01 only after a successful QMI result TLV. Invalid replies clear the
cache; cached data expires after 30 seconds using the monotonic clock. Optional
NAS queries do not block authenticated voice operations.

Authenticated voice response extension type 2 has a three-byte value:

| Byte | Meaning |
| --- | --- |
| 0 | Schema version: 1 |
| 1 | Signed int8 RSSI in dBm (-125 through -1) |
| 2 | QMI NAS radio interface; 8 means LTE |

The TLV header uses the existing format: one-byte type and two-byte big-endian
length. No extension means unavailable. Existing remote-number extension type
1 is unchanged. Clients reject duplicate/malformed radio extensions and still
accept old responses without radio data. Maximum frame sizes include six more
bytes in the C, Swift and macOS Go clients.

The iOS module pill shows SF Symbols `cellularbars`, network type and RSSI.
Bars are an RSSI presentation heuristic: 4 at >= -75 dBm, 3 at >= -85, 2 at
>= -95, otherwise 1. They do not measure throughput or RSRP. Unavailable or
expired telemetry displays an unknown state. Pairing changes clear telemetry.

## Build and checks

Use the existing cross-build environment:

```sh
DJONEHUB_QMI_BUILD_TARGET=voice sh scripts/build_sms_daemon_armel.sh --local
cc -std=c11 -Wall -Wextra -Werror module/djonehub_radio_test.c module/djonehub_voice_codec.c module/djonehub_voice_policy.c module/djonehub_control_protocol.c module/djonehub_crypto.c -lpthread -o /tmp/djonehub-radio-test
/tmp/djonehub-radio-test
swiftc ios/DJOneHubUACProbe/DJOneHubUACProbe/Control/VoiceControlProtocol.swift ios/DJOneHubUACProbe/Tests/VoiceControlProtocolOfflineTest.swift -o /tmp/djonehub-protocol-test
/tmp/djonehub-protocol-test
```

ARM uses the original fcntl symbol ABI for F_GETFD/F_SETFD, since the target
runs glibc 2.22. The build audits imported symbol versions. Device validation
returned LTE (NAS 8), -56 dBm through both the NAS probe and the authenticated
control port. No calls were placed as part of testing.

## Deployment note

The connected module's voice daemon was updated in
`/usrdata/djonehub/voice-test/djonehub-voice-daemon.armv7`; the previous executable
is retained alongside it as `.before-radio`. Pairing keys were preserved.
When starting the existing service script through USB ADB, use a separate
session (`setsid`) and redirected standard streams: an ordinary background
job can die when the ADB shell session closes. Confirm the listener survives
closing that session, then verify an authenticated STATUS response.

The desktop installer still pins its existing release artifact; this change
does not silently replace that release pin or deploy to other modules.
