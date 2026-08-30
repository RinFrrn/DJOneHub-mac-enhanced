package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func voiceDaemonTestMaterial() ([]byte, []byte) {
	key := make([]byte, voiceControlTagBytes)
	nonce := make([]byte, voiceControlNonceBytes)
	for index := range key {
		key[index] = byte(index + 1)
		nonce[index] = byte(0xa0 + index)
	}
	return key, nonce
}

func TestVoiceDaemonHello(t *testing.T) {
	_, nonce := voiceDaemonTestMaterial()
	hello := append(voiceControlHeader(voiceControlFrameHello, 0, voiceControlNonceBytes, 0), nonce...)
	decoded, err := decodeVoiceDaemonHello(hello)
	if err != nil || !bytes.Equal(decoded, nonce) {
		t.Fatalf("valid hello rejected: %v", err)
	}
	hello[7] = 1
	if _, err := decodeVoiceDaemonHello(hello); err == nil {
		t.Fatal("reserved-bit mutation accepted")
	}
}

func TestVoiceDaemonStatusRequestAuthentication(t *testing.T) {
	key, nonce := voiceDaemonTestMaterial()
	frame, err := encodeVoiceDaemonStatusRequest(key, nonce, 42)
	if err != nil {
		t.Fatal(err)
	}
	if len(frame) != voiceControlHeaderBytes+voiceControlTagBytes {
		t.Fatalf("unexpected request length: %d", len(frame))
	}
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write(nonce)
	_, _ = mac.Write(frame[:voiceControlHeaderBytes])
	if !hmac.Equal(frame[voiceControlHeaderBytes:], mac.Sum(nil)) {
		t.Fatal("request tag mismatch")
	}
	if _, err := encodeVoiceDaemonStatusRequest(key, nonce, 0); err == nil {
		t.Fatal("zero request ID accepted")
	}
}

func TestVoiceDaemonReplyAuthenticationAndReplay(t *testing.T) {
	key, nonce := voiceDaemonTestMaterial()
	payload := []byte{voiceControlOpStatus, 0, 0, 1, 1, 2, 2, 2, 4, 0, 0}
	frame := voiceDaemonReplyFrameForTest(key, nonce, 99, payload)
	reply, err := decodeVoiceDaemonReply(key, nonce, frame, 99)
	if err != nil || len(reply.Calls) != 1 || reply.Calls[0].State != 2 {
		t.Fatalf("valid reply rejected: %#v %v", reply, err)
	}
	otherNonce := append([]byte(nil), nonce...)
	otherNonce[31] ^= 1
	if _, err := decodeVoiceDaemonReply(key, otherNonce, frame, 99); err == nil {
		t.Fatal("reply replayed under another challenge")
	}
	frame[len(frame)-1] ^= 1
	if _, err := decodeVoiceDaemonReply(key, nonce, frame, 99); err == nil {
		t.Fatal("mutated reply accepted")
	}
}

func TestValidateVoiceDaemonArtifactRejectsUnpinnedBinary(t *testing.T) {
	err := validateVoiceDaemonArtifact(qmiVoiceProbeTestELF(2, 40))
	if err == nil || !strings.Contains(err.Error(), "SHA-256 不匹配") {
		t.Fatalf("got %v, want pinned hash rejection", err)
	}
}

func TestVoiceDaemonHeaderUsesNetworkOrder(t *testing.T) {
	header := voiceControlHeader(voiceControlFrameRequest, voiceControlOpStatus, 7, 0x0102030405060708)
	if binary.BigEndian.Uint16(header[8:10]) != 7 || binary.BigEndian.Uint64(header[12:20]) != 0x0102030405060708 {
		t.Fatal("header network byte order mismatch")
	}
}

func TestDevelopmentPairingBundleMatchesIOSContract(t *testing.T) {
	key := make([]byte, voiceControlTagBytes)
	for index := range key {
		key[index] = byte(index)
	}
	now := time.Unix(2_000_000_000, 0).UTC()
	data, identifier, err := encodeDevelopmentPairingBundle(key, now)
	if err != nil {
		t.Fatal(err)
	}
	var bundle developmentPairingBundle
	if err := json.Unmarshal(data, &bundle); err != nil {
		t.Fatal(err)
	}
	if bundle.Version != 1 || bundle.Purpose != "development-status-only" ||
		bundle.ModuleIdentifier != identifier || len(identifier) != 32 ||
		bundle.Host != "192.168.225.1" || bundle.Port != 45750 {
		t.Fatalf("unexpected bundle: %#v", bundle)
	}
	if bundle.CreatedAt != now.Format(time.RFC3339) ||
		bundle.ExpiresAt != now.Add(time.Hour).Format(time.RFC3339) {
		t.Fatalf("unexpected validity: %#v", bundle)
	}
}

func TestDevelopmentPairingBundleRejectsWrongKeyLength(t *testing.T) {
	if _, _, err := encodeDevelopmentPairingBundle(make([]byte, 31), time.Now()); err == nil {
		t.Fatal("short pairing key accepted")
	}
}
