package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

const (
	voiceDaemonExpectedSHA256 = "e07dbc1a1ee915272de4cd472aa51af05c38acc799b13898b5589151fb6b4301"
	voiceDaemonRemotePath     = "/tmp/djonehub-voice-daemon.armv7"
	voiceDaemonRemoteKeyPath  = "/tmp/djonehub-control.key"
	voiceDaemonRemotePIDPath  = "/tmp/djonehub-voice-daemon.pid"
	voiceDaemonRemoteLogPath  = "/tmp/djonehub-voice-daemon.log"
	voiceDaemonAddress        = "192.168.225.1:45750"
	voiceTestRemoteDir        = "/usrdata/djonehub/voice-test"
	voiceTestRemoteBinary     = voiceTestRemoteDir + "/djonehub-voice-daemon.armv7"
	voiceTestRemoteKey        = voiceTestRemoteDir + "/pairing.key"
	voiceTestRemoteScript     = voiceTestRemoteDir + "/start-once.sh"
	voiceTestRemoteMarker     = voiceTestRemoteDir + "/run-once"
	voiceTestRemoteState      = voiceTestRemoteDir + "/last-start.state"
	voiceTestRemoteLog        = voiceTestRemoteDir + "/last-start.log"
	voiceTestInitLink         = "/etc/rc5.d/S99djonehub-voice-test"
	voiceTestPIDFile          = "/run/djonehub-voice-test.pid"
	voiceTestPairingPurpose   = "development-status-only"
	voiceTestPairingValidity  = time.Hour

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

func encodeDevelopmentPairingBundle(key []byte, now time.Time) ([]byte, string, error) {
	identifier, err := developmentPairingModuleIdentifier(key)
	if err != nil {
		return nil, "", err
	}
	bundle := developmentPairingBundle{
		Version:          1,
		Purpose:          voiceTestPairingPurpose,
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

const voiceTestStartOnceScript = `#!/bin/sh
base=/usrdata/djonehub/voice-test
binary="$base/djonehub-voice-daemon.armv7"
key="$base/pairing.key"
marker="$base/run-once"
state="$base/last-start.state"
log="$base/last-start.log"
pidfile=/run/djonehub-voice-test.pid

test -f "$marker" || exit 0
rm -f "$marker"
printf 'marker-consumed\n' >"$state"
: >"$log"
sync

(
    attempt=0
    while test "$attempt" -lt 60; do
        if ip addr show 2>/dev/null | grep -q 'inet 192\.168\.225\.1/'; then
            printf 'daemon-starting\n' >"$state"
            chmod 600 "$key" || exit 1
            LD_LIBRARY_PATH=/usr/lib "$binary" --once --key-file "$key" >>"$log" 2>&1 &
            daemon_pid=$!
            printf '%s\n' "$daemon_pid" >"$pidfile"
            ready=0
            check=0
            while test "$check" -lt 50; do
                if grep -F 'authenticated control listening on 192.168.225.1:45750' "$log" >/dev/null 2>&1; then
                    ready=1
                    break
                fi
                kill -0 "$daemon_pid" 2>/dev/null || break
                check=$((check + 1))
                sleep 0.1
            done
            rm -f "$key"
            sync
            if test "$ready" = 1; then
                printf 'listener-ready\n' >"$state"
                wait "$daemon_pid"
                result=$?
                printf 'daemon-exit:%s\n' "$result" >"$state"
                rm -f "$pidfile"
                exit "$result"
            fi
            printf 'daemon-start-failed\n' >"$state"
            kill -TERM "$daemon_pid" 2>/dev/null || true
            rm -f "$pidfile"
            exit 1
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    rm -f "$key"
    printf 'address-timeout\n' >"$state"
    ip addr show 2>/dev/null || true
    exit 1
) >>"$log" 2>&1 &
exit 0
`
