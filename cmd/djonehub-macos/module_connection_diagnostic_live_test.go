//go:build darwin && cgo

package main

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"testing"
	"time"
)

func TestLiveModuleConnectionDiagnostic(t *testing.T) {
	if os.Getenv("DJONEHUB_CONNECTION_DIAGNOSTIC") != "1" {
		t.Skip("read-only module diagnostic")
	}
	adb, err := openDJIUSBADB()
	if err != nil {
		t.Fatal(err)
	}
	defer adb.Close()
	adb.nextLocalID = uint32(time.Now().UnixNano()) | 0x10000
	command := `date -u; uptime; ip addr show bridge0; ip route; netstat -lnt; for file in /proc/[0-9]*/comm; do read name < "$file"; case "$name" in djonehub*|mavo*|*qmi*) printf '%s %s\n' "$file" "$name";; esac; done; sha256sum /usrdata/djonehub/voice-test/djonehub-voice-daemon.armv7; ls -ln /run/djonehub/voice-sessions.v1 2>/dev/null; dmesg | tail -n 35`
	if os.Getenv("DJONEHUB_SYNC_ONLY") != "1" {
		output, status, err := adb.shellChecked(command, 15*time.Second)
		t.Log(sentinelCleanShellOutput(output))
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("diagnostic shell status=%d", status)
	} else {
		for _, path := range []string{"/proc/meminfo", "/proc/self/limits"} {
			content, err := adb.pull(path, 16384, 8*time.Second)
			if err != nil {
				t.Fatal("file diagnostic", err)
			}
			t.Log(string(content))
		}
	}
	key, err := adb.pull(voiceTestRemoteKey, 32, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer clear(key)
	address := voiceDaemonAddress
	if artifact := os.Getenv("DJONEHUB_STAGED_VOICE"); artifact != "" {
		data, err := os.ReadFile(artifact)
		if err != nil {
			t.Fatal(err)
		}
		const remote = "/tmp/djonehub-staged-voice.armv7"
		if err := adb.push(data, remote, 0100700, 30*time.Second); err != nil {
			t.Fatal(err)
		}
		adb.connected = false
		defer func() {
			if t.Failed() {
				output, _, _ := adb.shellChecked("tail -n 30 /tmp/djonehub-staged-voice.log", 8*time.Second)
				t.Log(sentinelCleanShellOutput(output))
			}
			_, _, _ = adb.shellChecked(`if test -s /tmp/djonehub-staged-voice.pid; then read pid < /tmp/djonehub-staged-voice.pid; case "$pid" in ''|*[!0-9]*) exit 1;; esac; case "$(readlink /proc/$pid/exe)" in /tmp/djonehub-staged-voice.armv7|/var/volatile/tmp/djonehub-staged-voice.armv7) kill -TERM "$pid"; attempt=0; while kill -0 "$pid" 2>/dev/null && test "$attempt" -lt 30; do sleep 0.1; attempt=$((attempt+1)); done; kill -0 "$pid" 2>/dev/null && exit 1;; esac; fi; rm -f /tmp/djonehub-staged-voice.armv7 /tmp/djonehub-staged-voice.pid /tmp/djonehub-staged-voice.log`, 8*time.Second)
		}()
		digest := sha256.Sum256(data)
		command := fmt.Sprintf(`test "$(sha256sum '%s' | cut -d ' ' -f 1)" = '%x' && (ulimit -c 0; ulimit -s 256 || exit 1; trap '' HUP; LD_LIBRARY_PATH=/usr/lib '%s' --status-only --key-file '%s' >/tmp/djonehub-staged-voice.log 2>&1 </dev/null & echo $! >/tmp/djonehub-staged-voice.pid)`, remote, digest, remote, voiceTestRemoteKey)
		if _, code, err := adb.shellChecked(command, 8*time.Second); err != nil || code != 0 {
			t.Fatal("stage launch failed", err)
		}
		address = "192.168.225.1:45755"
		time.Sleep(3 * time.Second)
	}
	connection, err := net.DialTimeout("tcp4", address, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(10 * time.Second))
	hello, err := readVoiceControlFrame(connection, voiceControlFrameHello)
	if err != nil {
		t.Fatal("handshake", err)
	}
	nonce, err := decodeVoiceDaemonHello(hello)
	if err != nil {
		t.Fatal(err)
	}
	request, err := encodeVoiceDaemonStatusRequest(key, nonce, 1)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = connection.Write(request); err != nil {
		t.Fatal(err)
	}
	frame, err := readVoiceControlFrame(connection, voiceControlFrameReply)
	if err != nil {
		t.Fatal("STATUS response", err)
	}
	reply, err := decodeVoiceDaemonReply(key, nonce, frame, 1)
	if err != nil {
		t.Fatal("authenticated STATUS", err)
	}
	t.Logf("authenticated STATUS: %+v", reply.Status)
	if reply.Status != 0 {
		t.Fatal("STATUS failed")
	}
	if os.Getenv("DJONEHUB_EXPECT_END_EVENTS") == "1" {
		payload := frame[voiceControlHeaderBytes : len(frame)-voiceControlTagBytes]
		found := false
		for offset := 4 + int(payload[3])*7; offset < len(payload); {
			if len(payload)-offset < 3 {
				t.Fatal("truncated extension")
			}
			typeCode := payload[offset]
			length := int(binary.BigEndian.Uint16(payload[offset+1 : offset+3]))
			offset += 3
			if length > len(payload)-offset {
				t.Fatal("truncated extension payload")
			}
			if typeCode == 4 {
				if length < 9 || binary.BigEndian.Uint64(payload[offset:offset+8]) == 0 || length != 9+int(payload[offset+8])*11 {
					t.Fatal("invalid end-event extension")
				}
				found = true
			}
			offset += length
		}
		if !found {
			t.Fatal("new end-event extension missing")
		}
		t.Log("authenticated end-event extension: PASS")
	}
	for _, call := range reply.Calls {
		if call.State != 9 {
			t.Fatal("module has an active call; do not deploy")
		}
	}
}
