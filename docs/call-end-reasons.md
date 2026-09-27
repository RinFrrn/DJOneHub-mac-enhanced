# Call end reasons

Implementation adds a read-only QMI all-call-status callback and a bounded
16-event cache to the existing voice daemon. The callback has its own mutex;
it never takes the synchronous QMI mutex. Queries skip cache updates when an
indication arrived during the query, avoiding stale query data overwriting it.

Raw QMI fields are count-prefixed `(call ID: uint8, reason: uint16 LE)` arrays:
Get All Call Info response TLV `0x18`, All Call Status indication TLV `0x14`.
Definitions: [Qualcomm Gobi structures preserved by libqmi](https://github.com/linux-mobile-broadband/libqmi/blob/main/gobi-api/GobiAPI_2013-07-31-1347/GobiConnectionMgmt/GobiConnectionMgmtAPIStructs.h).
VOICE reason values follow [libqmi VOICE enums](https://github.com/linux-mobile-broadband/libqmi/blob/main/src/libqmi-glib/qmi-enums-voice.h), not WDS or GSM cause numbers.

Authenticated STATUS extension `4` uses big-endian integers:

- session: uint64, nonzero process-lifetime identifier
- count: uint8, at most 16
- records: sequence uint64, call ID uint8, raw reason uint16 (11 bytes)

Sequences are strictly increasing. A late explicit reason updates the same
sequence. Repeated reports do not create another event. `0xffff` means no
explicit reason. An ID observed active again starts a new lifetime. Existing
extensions remain unchanged and clients can skip unknown extensions.

iOS associates events with a tracked call and pre-call sequence baseline.
History keeps an optional raw reason, so older JSON remains readable. Late
updates target the original history UUID. Manually canceled and completed
calls retain their existing presentation. Unconnected outgoing calls briefly
show the end reason and a redial action. Unknown reasons use “呼叫已结束”.

## Verification status (2026-09-27)

Host codec/cache/control-protocol tests, Swift protocol tests, and iOS builds
pass. ARM production artifacts build with the existing ABI audit.

**Deployed to the module and installed on the paired iPhone.** Authenticated
STATUS and the nonzero-session end-event extension passed on the production
port after replacement. Existing pairing identity and configuration were
preserved. No real calls were initiated during implementation.

The earlier probe failure was localized to vendor `Diag_LSM_Init`: its read
thread creation failed, then cleanup attempted `pthread_join(0)`. Setting the
new process's stack limit to 256 KB before exec made the probe and staged
daemon pass. The voice launcher now uses this limit too. A subsequent ADB
shell refusal required an idle module reboot before deployment; the sync
file channel and original authenticated STATUS still worked at that time.

The staged test is status-only on port 45755. Cleanup checks both `/tmp` and
its canonical `/var/volatile/tmp` path before stopping the owned process.

Reproduce with build target `voice-idle-probe`, then:

```sh
DJONEHUB_VOICE_IDLE_PROBE="$PWD/outputs/module/djonehub-voice-idle-preflight.armv7" \
  go test ./cmd/djonehub-macos -run '^TestLiveVoiceIdlePreflight$' -count=1 -v
```

User-assisted carrier tests still required: actual busy,
call waiting enabled, rejection, no answer, local cancel and normal hangup.
Carrier announcements without an explicit busy cause must not become “对方忙”.
