package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"os"
	"os/exec"
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

func TestPinnedVoiceIncallCardArtifact(t *testing.T) {
	data, err := os.ReadFile("../../outputs/module/qdc507_incall_card.new.ko")
	if err != nil {
		t.Fatal(err)
	}
	if err := validateVoiceIncallCardArtifact(data); err != nil {
		t.Fatalf("pinned in-call card rejected: %v", err)
	}
	mutated := append([]byte(nil), data...)
	mutated[len(mutated)-1] ^= 1
	if err := validateVoiceIncallCardArtifact(mutated); err == nil ||
		!strings.Contains(err.Error(), "SHA-256 不匹配") {
		t.Fatalf("mutated in-call card rejection = %v", err)
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
	data, identifier, err := encodeDevelopmentPairingBundle(key, voiceTestStatusPurpose, now)
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
		bundle.ExpiresAt != now.Add(voiceTestPairingValidity).Format(time.RFC3339) {
		t.Fatalf("unexpected validity: %#v", bundle)
	}
}

func TestDevelopmentPairingBundleRejectsWrongKeyLength(t *testing.T) {
	if _, _, err := encodeDevelopmentPairingBundle(make([]byte, 31), voiceTestStatusPurpose, time.Now()); err == nil {
		t.Fatal("short pairing key accepted")
	}
}

func TestDevelopmentControlSessionBundleMatchesIOSContract(t *testing.T) {
	key := make([]byte, voiceControlTagBytes)
	now := time.Unix(2_000_000_000, 0).UTC()
	data, _, err := encodeDevelopmentPairingBundle(key, voiceTestSessionPurpose, now)
	if err != nil {
		t.Fatal(err)
	}
	var bundle developmentPairingBundle
	if err := json.Unmarshal(data, &bundle); err != nil {
		t.Fatal(err)
	}
	if bundle.Purpose != "development-control-session" {
		t.Fatalf("unexpected purpose: %q", bundle.Purpose)
	}
}

func TestDevelopmentPairingBundleRejectsUnknownPurpose(t *testing.T) {
	if _, _, err := encodeDevelopmentPairingBundle(make([]byte, voiceControlTagBytes), "production", time.Now()); err == nil {
		t.Fatal("unknown pairing purpose accepted")
	}
}

func TestVoiceTestStartScriptSeparatesReadOnlyAndControlModes(t *testing.T) {
	for _, required := range []string{
		"run-status-once",
		"run-control-session",
		"daemon_args=\"--once --status-only\"",
		"mode=control-session",
		"start_uplink=0",
		"start_uplink=1",
		"--uplink-listener",
		"--audio-port 45751",
		"qdc507_aprv3.ko",
		"qdc507_voice.ko",
		"qdc507_incall_card.ko",
		"prepare-incall-card.sh",
		"qdc507-incall-card",
		"Voice Downlink Capture",
		"Voice Farend Playback",
		"/dev/snd/controlC0",
		"/dev/snd/pcmC0D5p",
		"/usr/bin/alsaucm_test",
		"ACDB -> Sent VocProc Cal!",
		"--prepare-only",
		"voice runtime ready: ALSA devices and VoLTE ACDB calibrated",
		"retain_session=0",
		"retain_session=1",
		"printf 'session-persistent:%s\\n' \"$mode\"",
		"remove_ephemeral_key",
		"previous-start.state",
		"previous-start.log",
	} {
		if !strings.Contains(voiceTestStartScript, required) {
			t.Fatalf("start script missing %q", required)
		}
	}
	if strings.Contains(voiceTestStartScript, "--network-session") {
		t.Fatal("start script must use the authenticated listener session owner")
	}
	if !strings.Contains(voiceTestStartScript, `if test "$retain_session" = 0; then`) {
		t.Fatal("ephemeral key removal is not guarded from persistent control sessions")
	}
}

func TestVoiceTestStartScriptHasValidShellSyntax(t *testing.T) {
	for name, script := range map[string]string{
		"start":        voiceTestStartScript,
		"prepare-card": voiceTestPrepareIncallCardScript,
	} {
		command := exec.Command("/bin/sh", "-n")
		command.Stdin = strings.NewReader(script)
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("%s script shell syntax: %v: %s", name, err, output)
		}
	}
}

func TestPrepareIncallCardScriptHasFailSafeRollback(t *testing.T) {
	for _, required := range []string{
		"driver_override",
		"qdc507-voice-card",
		"qdc507-incall-card",
		"restore_stock_card",
		"--restore-stock",
		"rmmod qdc507_incall_card",
		"Voice Downlink Capture",
		"Voice Farend Playback",
	} {
		if !strings.Contains(voiceTestPrepareIncallCardScript, required) {
			t.Fatalf("prepare-card script missing %q", required)
		}
	}
}
