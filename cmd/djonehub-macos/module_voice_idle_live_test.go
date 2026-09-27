//go:build darwin && cgo

package main

import (
	"crypto/sha256"
	"fmt"
	"os"
	"testing"
	"time"
)

func TestLiveVoiceIdlePreflight(t *testing.T) {
	artifact := os.Getenv("DJONEHUB_VOICE_IDLE_PROBE")
	if artifact == "" {
		t.Skip("opt-in read-only idle check")
	}
	data, err := os.ReadFile(artifact)
	if err != nil {
		t.Fatal(err)
	}
	adb, err := openDJIUSBADB()
	if err != nil {
		t.Fatal(err)
	}
	defer adb.Close()
	const remote = "/tmp/djonehub-voice-idle-preflight.armv7"
	if err := adb.push(data, remote, 0100700, 30*time.Second); err != nil {
		t.Fatal(err)
	}
	adb.connected = false
	defer func() { _, _, _ = adb.shellChecked("rm -f '"+remote+"'", 8*time.Second) }()
	digest := sha256.Sum256(data)
	command := fmt.Sprintf("ulimit -c 0; ulimit -s 256; test \"$(sha256sum '%s' | cut -d ' ' -f 1)\" = '%x' && LD_LIBRARY_PATH=/usr/lib '%s' 2>&1", remote, digest, remote)
	output, status, err := adb.shellChecked(command, 20*time.Second)
	if err != nil || status != 0 {
		t.Log(sentinelCleanShellOutput(output))
		diagnostic, _, _ := adb.shellChecked(`command -v gdb; command -v strace; for file in /proc/[0-9]*/comm; do read name < "$file"; case "$name" in *qmi*|*voice*|*notify*|*modem*) printf '%s %s\n' "$file" "$name";; esac; done`, 8*time.Second)
		t.Log(sentinelCleanShellOutput(diagnostic))
		t.Fatalf("module is not confirmed idle: status=%d err=%v", status, err)
	}
}
