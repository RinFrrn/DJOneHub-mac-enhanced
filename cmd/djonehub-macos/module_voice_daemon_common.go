package main

import (
	"crypto/hmac"
	"crypto/sha256"
	_ "embed"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

const (
	voiceDaemonExpectedSHA256         = "68c672e8d669b61d4e95a61b480cc503763f84b87bb7d50d1c88e4e191cf7c0e"
	voiceUplinkExpectedSHA256         = "052912efc5f9ef21ac891a5d2f9c457b3a3242f8423b17b3cb2f95418e982e48"
	voiceTestAPRv3ExpectedSHA256      = "3d82d3dec4f1e323201bba87156df9d41438e08314097353f2607f9117211d4a"
	voiceTestVoiceExpectedSHA256      = "ed3821682d5309969a01c764192c83feff9669c61ef237c69475cd1619cf296c"
	voiceTestIncallCardExpectedSHA256 = "dfabcecff905b97ed46f755f4667e7c2635799e00524a10a8ed9d546bd1feea7"
	voiceDaemonRemotePath             = "/tmp/djonehub-voice-daemon.armv7"
	voiceDaemonRemoteKeyPath          = "/tmp/djonehub-control.key"
	voiceDaemonRemotePIDPath          = "/tmp/djonehub-voice-daemon.pid"
	voiceDaemonRemoteLogPath          = "/tmp/djonehub-voice-daemon.log"
	voiceDaemonAddress                = "192.168.225.1:45750"
	voiceTestRemoteDir                = "/usrdata/djonehub/voice-test"
	voiceTestRemoteBinary             = voiceTestRemoteDir + "/djonehub-voice-daemon.armv7"
	voiceTestRemoteUplink             = voiceTestRemoteDir + "/mavo-pcm-bridge.armv7"
	voiceTestRemoteAPRv3              = voiceTestRemoteDir + "/qdc507_aprv3.ko"
	voiceTestRemoteVoice              = voiceTestRemoteDir + "/qdc507_voice.ko"
	voiceTestRemoteIncallCard         = voiceTestRemoteDir + "/qdc507_incall_card.ko"
	voiceTestRemotePrepareCard        = voiceTestRemoteDir + "/prepare-incall-card.sh"
	voiceTestRemoteKey                = voiceTestRemoteDir + "/pairing.key"
	voiceTestRemoteScript             = voiceTestRemoteDir + "/start-once.sh"
	voiceTestLegacyOnceMarker         = voiceTestRemoteDir + "/run-once"
	voiceTestRemoteOnceMarker         = voiceTestRemoteDir + "/run-status-once"
	voiceTestRemoteSessionMarker      = voiceTestRemoteDir + "/run-control-session"
	voiceTestRemoteState              = voiceTestRemoteDir + "/last-start.state"
	voiceTestRemoteLog                = voiceTestRemoteDir + "/last-start.log"
	voiceTestInitLink                 = "/etc/rc5.d/S99djonehub-voice-test"
	voiceTestPIDFile                  = "/run/djonehub-voice-test.pid"
	voiceTestUplinkPIDFile            = "/run/djonehub-uplink-test.pid"
	voiceTestStatusPurpose            = "development-status-only"
	voiceTestSessionPurpose           = "development-control-session"
	voiceTestPairingValidity          = 30 * 24 * time.Hour

	voiceControlMagic        = 0x444a4f48
	voiceControlVersion      = 1
	voiceControlFrameHello   = 1
	voiceControlFrameRequest = 2
	voiceControlFrameReply   = 3
	voiceControlOpStatus     = 1
	voiceControlHeaderBytes  = 20
	voiceControlNonceBytes   = 32
	voiceControlTagBytes     = 32
	voiceControlMaxPayload   = 81
)

//go:embed module_prepare_incall_card.sh
var voiceTestPrepareIncallCardScript string

type developmentPairingBundle struct {
	Version          int    `json:"version"`
	Purpose          string `json:"purpose"`
	ModuleIdentifier string `json:"module_identifier"`
	PairingKeyBase64 string `json:"pairing_key_base64"`
	Host             string `json:"host"`
	Port             uint16 `json:"port"`
	CreatedAt        string `json:"created_at"`
	ExpiresAt        string `json:"expires_at"`
}

func developmentPairingModuleIdentifier(key []byte) (string, error) {
	if len(key) != voiceControlTagBytes {
		return "", errors.New("pairing key 必须恰好为 32 字节")
	}
	sum := sha256.Sum256(key)
	return hex.EncodeToString(sum[:16]), nil
}

func encodeDevelopmentPairingBundle(key []byte, purpose string, now time.Time) ([]byte, string, error) {
	identifier, err := developmentPairingModuleIdentifier(key)
	if err != nil {
		return nil, "", err
	}
	if purpose != voiceTestStatusPurpose && purpose != voiceTestSessionPurpose {
		return nil, "", errors.New("测试配对包 purpose 无效")
	}
	bundle := developmentPairingBundle{
		Version:          1,
		Purpose:          purpose,
		ModuleIdentifier: identifier,
		PairingKeyBase64: base64.StdEncoding.EncodeToString(key),
		Host:             "192.168.225.1",
		Port:             45750,
		CreatedAt:        now.UTC().Format(time.RFC3339),
		ExpiresAt:        now.Add(voiceTestPairingValidity).UTC().Format(time.RFC3339),
	}
	data, err := json.MarshalIndent(bundle, "", "  ")
	if err != nil {
		return nil, "", err
	}
	return append(data, '\n'), identifier, nil
}

type voiceDaemonCall struct {
	ID        byte `json:"id"`
	State     byte `json:"state"`
	Type      byte `json:"type"`
	Direction byte `json:"direction"`
	Mode      byte `json:"mode"`
	Multipart byte `json:"multipart"`
	ALS       byte `json:"als"`
}

type voiceDaemonReply struct {
	Status    byte              `json:"status"`
	Operation byte              `json:"operation,omitempty"`
	CallID    byte              `json:"call_id,omitempty"`
	Confirmed bool              `json:"confirmed"`
	Calls     []voiceDaemonCall `json:"calls,omitempty"`
}

func validateVoiceDaemonArtifact(data []byte) error {
	if len(data) == 0 || len(data) > qmiVoiceProbeMaximumSize {
		return fmt.Errorf("QMI Voice daemon 文件大小无效：%d bytes", len(data))
	}
	if err := validateQMIVoiceProbeELF(data); err != nil {
		return err
	}
	sum := sha256.Sum256(data)
	actual := hex.EncodeToString(sum[:])
	if actual != voiceDaemonExpectedSHA256 {
		return fmt.Errorf("QMI Voice daemon SHA-256 不匹配：需要 %s，实际 %s", voiceDaemonExpectedSHA256, actual)
	}
	return nil
}

func validateVoiceIncallCardArtifact(data []byte) error {
	if len(data) < 52 || len(data) > 1024*1024 {
		return fmt.Errorf("QDC507 in-call card 文件大小无效：%d bytes", len(data))
	}
	if string(data[:4]) != "\x7fELF" || data[4] != 1 || data[5] != 1 ||
		binary.LittleEndian.Uint16(data[16:18]) != 1 ||
		binary.LittleEndian.Uint16(data[18:20]) != 40 {
		return errors.New("QDC507 in-call card 必须是 ARM ELF32 little-endian relocatable module")
	}
	sum := sha256.Sum256(data)
	actual := hex.EncodeToString(sum[:])
	if actual != voiceTestIncallCardExpectedSHA256 {
		return fmt.Errorf("QDC507 in-call card SHA-256 不匹配：需要 %s，实际 %s", voiceTestIncallCardExpectedSHA256, actual)
	}
	return nil
}

func voiceControlHeader(frameType, code byte, payloadLength uint16, requestID uint64) []byte {
	header := make([]byte, voiceControlHeaderBytes)
	binary.BigEndian.PutUint32(header[0:4], voiceControlMagic)
	header[4] = voiceControlVersion
	header[5] = frameType
	header[6] = code
	binary.BigEndian.PutUint16(header[8:10], payloadLength)
	binary.BigEndian.PutUint64(header[12:20], requestID)
	return header
}

func validateVoiceControlHeader(frame []byte, expectedType byte) (byte, uint16, uint64, error) {
	if len(frame) < voiceControlHeaderBytes ||
		binary.BigEndian.Uint32(frame[0:4]) != voiceControlMagic ||
		frame[4] != voiceControlVersion || frame[5] != expectedType ||
		frame[7] != 0 || frame[10] != 0 || frame[11] != 0 {
		return 0, 0, 0, errors.New("控制帧头无效")
	}
	return frame[6], binary.BigEndian.Uint16(frame[8:10]),
		binary.BigEndian.Uint64(frame[12:20]), nil
}

func decodeVoiceDaemonHello(frame []byte) ([]byte, error) {
	code, payloadLength, requestID, err := validateVoiceControlHeader(frame, voiceControlFrameHello)
	if err != nil || code != 0 || requestID != 0 || payloadLength != voiceControlNonceBytes ||
		len(frame) != voiceControlHeaderBytes+voiceControlNonceBytes {
		return nil, errors.New("daemon HELLO 无效")
	}
	nonce := make([]byte, voiceControlNonceBytes)
	copy(nonce, frame[voiceControlHeaderBytes:])
	return nonce, nil
}

func voiceControlTag(key, nonce, unsignedFrame []byte) []byte {
	authenticator := hmac.New(sha256.New, key)
	_, _ = authenticator.Write(nonce)
	_, _ = authenticator.Write(unsignedFrame)
	return authenticator.Sum(nil)
}

func encodeVoiceDaemonStatusRequest(key, nonce []byte, requestID uint64) ([]byte, error) {
	if len(key) != voiceControlTagBytes || len(nonce) != voiceControlNonceBytes || requestID == 0 {
		return nil, errors.New("status 请求参数无效")
	}
	frame := voiceControlHeader(voiceControlFrameRequest, voiceControlOpStatus, 0, requestID)
	return append(frame, voiceControlTag(key, nonce, frame)...), nil
}

func decodeVoiceDaemonReply(key, nonce, frame []byte, expectedRequestID uint64) (voiceDaemonReply, error) {
	var reply voiceDaemonReply
	status, payloadLength, requestID, err := validateVoiceControlHeader(frame, voiceControlFrameReply)
	if err != nil || len(key) != voiceControlTagBytes || len(nonce) != voiceControlNonceBytes ||
		requestID == 0 || requestID != expectedRequestID || payloadLength > voiceControlMaxPayload {
		return reply, errors.New("daemon 响应头无效")
	}
	unsignedLength := voiceControlHeaderBytes + int(payloadLength)
	if len(frame) != unsignedLength+voiceControlTagBytes ||
		!hmac.Equal(frame[unsignedLength:], voiceControlTag(key, nonce, frame[:unsignedLength])) {
		return reply, errors.New("daemon 响应认证失败")
	}
	reply.Status = status
	payload := frame[voiceControlHeaderBytes:unsignedLength]
	if status != 0 {
		if len(payload) != 0 {
			return reply, errors.New("daemon 错误响应包含意外 payload")
		}
		return reply, nil
	}
	if len(payload) < 4 || payload[0] != voiceControlOpStatus || payload[1] != 0 || payload[2] != 0 {
		return reply, errors.New("daemon STATUS payload 无效")
	}
	count := int(payload[3])
	if count > 8 || len(payload) != 4+count*7 {
		return reply, errors.New("daemon call snapshot 长度无效")
	}
	reply.Operation = payload[0]
	reply.CallID = payload[1]
	reply.Confirmed = payload[2] != 0
	seen := make(map[byte]bool, count)
	for index := 0; index < count; index++ {
		record := payload[4+index*7 : 4+(index+1)*7]
		if record[0] == 0 || seen[record[0]] {
			return voiceDaemonReply{}, errors.New("daemon call snapshot 包含无效或重复 ID")
		}
		seen[record[0]] = true
		reply.Calls = append(reply.Calls, voiceDaemonCall{
			ID: record[0], State: record[1], Type: record[2],
			Direction: record[3], Mode: record[4], Multipart: record[5], ALS: record[6],
		})
	}
	return reply, nil
}

func voiceDaemonReplyFrameForTest(key, nonce []byte, requestID uint64, payload []byte) []byte {
	header := voiceControlHeader(voiceControlFrameReply, 0, uint16(len(payload)), requestID)
	unsigned := append(header, payload...)
	return append(unsigned, voiceControlTag(key, nonce, unsigned)...)
}

const voiceTestStartScript = `#!/bin/sh
base=/usrdata/djonehub/voice-test
binary="$base/djonehub-voice-daemon.armv7"
uplink="$base/mavo-pcm-bridge.armv7"
aprv3="$base/qdc507_aprv3.ko"
voice="$base/qdc507_voice.ko"
incall_card="$base/qdc507_incall_card.ko"
prepare_card="$base/prepare-incall-card.sh"
key="$base/pairing.key"
once_marker="$base/run-status-once"
session_marker="$base/run-control-session"
state="$base/last-start.state"
log="$base/last-start.log"
previous_state="$base/previous-start.state"
previous_log="$base/previous-start.log"
pidfile=/run/djonehub-voice-test.pid
uplink_pidfile=/run/djonehub-uplink-test.pid
calibration_pidfile=/run/mavo-alsaucm.pid
calibration_log=/run/mavo-alsaucm.log

sound_devices_ready() {
    test -c /dev/snd/controlC0 &&
        test -c /dev/snd/pcmC0D4p &&
        test -c /dev/snd/pcmC0D4c &&
        test -c /dev/snd/pcmC0D5p &&
        test -c /dev/snd/pcmC0D6c &&
        readlink /sys/class/sound/card0/device/driver 2>/dev/null |
        grep -Fq '/qdc507-incall-card' &&
        grep -Fq '(Voice Downlink Capture)' /proc/asound/pcm 2>/dev/null &&
        grep -Fq '(Voice Farend Playback)' /proc/asound/pcm 2>/dev/null
}

prepare_voice_runtime() {
    test -r "$incall_card" && test -x "$prepare_card" || return 1
    "$prepare_card" || return 1
    sound_devices_ready || return 1

    calibration_owned=0
    if test -s "$calibration_pidfile"; then
        read calibration_pid calibration_start < "$calibration_pidfile" || true
        current_start=$(cut -d ' ' -f 22 "/proc/$calibration_pid/stat" 2>/dev/null)
        calibration_argv0=$(tr '\000' '\n' < "/proc/$calibration_pid/cmdline" 2>/dev/null | sed -n '1p')
        test "$current_start" = "$calibration_start" &&
            test "$calibration_argv0" = /usr/bin/alsaucm_test && calibration_owned=1
    fi
    if test "$calibration_owned" -eq 0; then
        rm -f /run/alsaucm_test "$calibration_pidfile" "$calibration_log"
        nohup /usr/bin/alsaucm_test </dev/null >>"$calibration_log" 2>&1 &
        calibration_pid=$!
        calibration_start=$(cut -d ' ' -f 22 "/proc/$calibration_pid/stat" 2>/dev/null)
        printf '%s %s\n' "$calibration_pid" "$calibration_start" >"$calibration_pidfile"
        fifo_attempt=0
        while test "$fifo_attempt" -lt 50 && test ! -p /run/alsaucm_test; do
            kill -0 "$calibration_pid" 2>/dev/null || return 1
            fifo_attempt=$((fifo_attempt + 1))
            sleep 0.1
        done
        test -p /run/alsaucm_test || return 1
    fi
    if ! grep -q 'ACDB -> Sent VocProc Cal!' "$calibration_log" 2>/dev/null; then
        printf 'open snd_soc_msm_9x07_Tomtom_I2S\n' > /run/alsaucm_test
        printf 'set _verb VoLTE\n' > /run/alsaucm_test
        printf 'set _enadev Auxpcm Rx\n' > /run/alsaucm_test
        printf 'set _enadev Auxpcm Tx\n' > /run/alsaucm_test
        acdb_attempt=0
        while test "$acdb_attempt" -lt 100; do
            grep -q 'ACDB -> Sent VocProc Cal!' "$calibration_log" 2>/dev/null && break
            acdb_attempt=$((acdb_attempt + 1))
            sleep 0.1
        done
    fi
    grep -q 'ACDB -> Sent VocProc Cal!' "$calibration_log" 2>/dev/null
}

if test "$1" = --prepare-only; then
    prepare_voice_runtime || exit 1
    printf '%s\n' 'voice runtime ready: ALSA devices and VoLTE ACDB calibrated'
    exit 0
fi

if test -f "$once_marker"; then
    mode=status-once
    daemon_args="--once --status-only"
    start_uplink=0
    retain_session=0
elif test -f "$session_marker"; then
    mode=control-session
    daemon_args=
    start_uplink=1
    retain_session=1
else
    exit 0
fi
test ! -f "$state" || cp -f "$state" "$previous_state"
test ! -s "$log" || mv -f "$log" "$previous_log"
if test "$retain_session" = 1; then
    rm -f "$once_marker"
    printf 'session-persistent:%s\n' "$mode" >"$state"
else
    rm -f "$once_marker" "$session_marker"
    printf 'marker-consumed:%s\n' "$mode" >"$state"
fi
: >"$log"
sync

remove_ephemeral_key() {
    if test "$retain_session" = 0; then
        rm -f "$key"
    fi
}

(
    attempt=0
    while test "$attempt" -lt 60; do
        if ip addr show 2>/dev/null | grep -q 'inet 192\.168\.225\.1/'; then
            printf 'daemon-starting\n' >"$state"
            chmod 600 "$key" || exit 1
            if test "$start_uplink" = 1; then
                if ! prepare_voice_runtime; then
                    printf 'voice-runtime-failed\n' >"$state"
                    printf '%s\n' 'voice runtime preparation failed'
                    test ! -f "$calibration_log" || tail -n 80 "$calibration_log"
                    dmesg | tail -n 80
                    remove_ephemeral_key
                    sync
                    exit 1
                fi
                printf '%s\n' 'voice runtime ready: ALSA devices and VoLTE ACDB calibrated'
            fi
            uplink_pid=
            uplink_owned() {
                test -n "$uplink_pid" && test -d "/proc/$uplink_pid" &&
                    test "$(tr '\000' '\n' < "/proc/$uplink_pid/cmdline" 2>/dev/null | sed -n '1p')" = "$uplink"
            }
            if test "$start_uplink" = 1; then
                LD_LIBRARY_PATH=/usr/lib "$uplink" --uplink-listener \
                    --listen-address 192.168.225.1 --audio-port 45751 \
                    --token-file "$key" --interface bridge0 >>"$log" 2>&1 &
                uplink_pid=$!
                printf '%s\n' "$uplink_pid" >"$uplink_pidfile"
            fi
            LD_LIBRARY_PATH=/usr/lib "$binary" $daemon_args --key-file "$key" >>"$log" 2>&1 &
            daemon_pid=$!
            printf '%s\n' "$daemon_pid" >"$pidfile"
            ready=0
            check=0
            while test "$check" -lt 50; do
                uplink_ready=1
                if test "$start_uplink" = 1; then
                    uplink_ready=0
                    grep -F 'authenticated uplink listener ready on 192.168.225.1:45751' "$log" >/dev/null 2>&1 && uplink_ready=1
                fi
                if test "$uplink_ready" = 1 && grep -F 'authenticated control listening on 192.168.225.1:45750' "$log" >/dev/null 2>&1; then
                    ready=1
                    break
                fi
                kill -0 "$daemon_pid" 2>/dev/null || break
                if test "$start_uplink" = 1; then
                    kill -0 "$uplink_pid" 2>/dev/null || break
                fi
                check=$((check + 1))
                sleep 0.1
            done
            remove_ephemeral_key
            sync
            if test "$ready" = 1; then
                printf 'listener-ready\n' >"$state"
                wait "$daemon_pid"
                result=$?
                if test -n "$uplink_pid"; then
                    if uplink_owned; then
                        kill -TERM "$uplink_pid" 2>/dev/null || true
                    fi
                    wait "$uplink_pid" 2>/dev/null || true
                    rm -f "$uplink_pidfile"
                fi
                printf 'daemon-exit:%s\n' "$result" >"$state"
                rm -f "$pidfile"
                exit "$result"
            fi
            printf 'daemon-start-failed\n' >"$state"
            kill -TERM "$daemon_pid" 2>/dev/null || true
            if uplink_owned; then
                kill -TERM "$uplink_pid" 2>/dev/null || true
            fi
            rm -f "$uplink_pidfile"
            rm -f "$pidfile"
            exit 1
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    remove_ephemeral_key
    printf 'address-timeout\n' >"$state"
    ip addr show 2>/dev/null || true
    exit 1
) >>"$log" 2>&1 &
exit 0
`
