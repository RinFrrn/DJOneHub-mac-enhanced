package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
)

const (
	voiceDaemonExpectedSHA256 = "d9fc370f2b3b62cef7c8bdcaa10c4cca71672f5d9aedc330f9c12082caf377ec"
	voiceDaemonRemotePath     = "/tmp/djonehub-voice-daemon.armv7"
	voiceDaemonRemoteKeyPath  = "/tmp/djonehub-control.key"
	voiceDaemonRemotePIDPath  = "/tmp/djonehub-voice-daemon.pid"
	voiceDaemonRemoteLogPath  = "/tmp/djonehub-voice-daemon.log"
	voiceDaemonAddress        = "192.168.225.1:45750"

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
